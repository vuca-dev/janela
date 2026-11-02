import AppKit
import CoreMedia
import JanelaCamera
import JanelaCore
import QuartzCore
import SwiftUI

struct Config: Codable {
  var scene = "atelier"
  var enabled = true
  var place: Place?
  var manualWeather: String?   // nil = follow live weather
  var manualPhase: String?     // nil = follow the sun
  var setupDone: Bool?
  var outputDevices: [String]? // camera extensions to publish to, in order
  static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Janela/config.json")
  static func load() -> Config { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Config.self, from: $0) } ?? Config() }
  func save() {
    try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(self).write(to: Self.url)
  }
}

@MainActor final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
  var config = Config.load()
  var pipeline: Pipeline!
  var source: FrameSource!
  lazy var sink = VirtualCameraSink(preferredNames: config.outputDevices ?? ["OBS Virtual Camera"])
  var status: NSStatusItem!
  var previewWindow: NSWindow?
  var armed = false
  var running = false
  var probing = false
  var probeCount = 0
  var lastProbe = Date()
  var watchTimer: Timer?
  var forecast: Forecast?
  var lastAttempt = Date.distantPast
  var setup: SetupWindow?
  var setupModel: SetupModel?
  var requestingAccess = false
  var accessHelpShown = false
  var setupWatch: Timer?
  var closeObserver: Any?
  var launchedOBS: NSRunningApplication?
  var turnOnStarted = Date.distantPast
  var warmer: Process?
  static let forecastURL = Config.url.deletingLastPathComponent().appendingPathComponent("forecast.json")
  var message: String?
  #if JANELA_TEST
  let filePath = UserDefaults.standard.string(forKey: "file")      // -file <path> replays a clip
  let statsPath = UserDefaults.standard.string(forKey: "stats")    // -stats <path> appends one line a second
  let demoQuery = UserDefaults.standard.string(forKey: "setupDemo")
  lazy var alwaysOn = UserDefaults.standard.bool(forKey: "alwaysOn")
  lazy var probeEvery: TimeInterval = { let v = UserDefaults.standard.double(forKey: "probeEvery"); return v > 0 ? v : 60 }()
  #else
  let filePath: String? = nil
  let statsPath: String? = nil
  let demoQuery: String? = nil
  let alwaysOn = false
  let probeEvery: TimeInterval = 60
  #endif

  func applicationDidFinishLaunching(_ n: Notification) {
    status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    status.button?.image = menuBarIcon()
    NSApp.mainMenu = appMainMenu()
    let menu = NSMenu(); menu.delegate = self; status.menu = menu
    pipeline = Pipeline(compiledModel: Bundle.main.matteModel, scenesRoot: Bundle.main.resourceURL!.appendingPathComponent("scenes"))
    pipeline.onLoadFailure = { error in DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in
      self?.message = "Could not load the model: \(error)" } } }
    pipeline.onFrame = { [weak self] pb, pts in
      guard let self else { return }
      sink.send(pb, pts: pts)
      if let w = previewWindow, let s = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() {
        DispatchQueue.main.async { w.contentView?.layer?.contents = s }
      }
    }
    forecast = (try? Data(contentsOf: Self.forecastURL)).flatMap { try? JSONDecoder.iso.decode(Forecast.self, from: $0) }
    updateScene(immediate: true)
    Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick(); self?.warmCaches() } }
    tick()
    if let statsPath { startStats(statsPath) }
    #if JANELA_TEST
    let wakeEvery = UserDefaults.standard.double(forKey: "wakeEvery")   // -wakeEvery <s> posts the real wake notification
    if wakeEvery > 0 { Timer.scheduledTimer(withTimeInterval: wakeEvery, repeats: true) { _ in NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil) } }
    let activateAfter = UserDefaults.standard.double(forKey: "activateAfter")   // -activateAfter <s> starts as a reader would
    if activateAfter > 0 { Timer.scheduledTimer(withTimeInterval: activateAfter, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.activate() } } }
    #endif
    if config.enabled { setRunning(true) }
    if config.setupDone != true || demoQuery != nil { showSetup(firstRun: true) }
  }

  func applicationShouldHandleReopen(_ a: NSApplication, hasVisibleWindows v: Bool) -> Bool {
    showSetup(firstRun: false); return false
  }

  func startStats(_ path: String) {
    FileManager.default.createFile(atPath: path, contents: nil)
    let fh = FileHandle(forWritingAtPath: path)
    FileManager.default.createFile(atPath: path + ".frames", contents: nil)
    let frameLog = FileHandle(forWritingAtPath: path + ".frames")   // matte and total ms, one frame a line
    pipeline.recordTimings()
    var last = 0
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      guard let self else { return }
      let s = pipeline.stats, v = sink.status
      let line = String(format: "run=%d probes=%d fps=%d bg=%d dropped=%d matte=%.1f total=%.1f sinkOK=%d busy=%d full=%d dev=%@\n", running ? 1 : 0, probeCount, s.frames - last, s.backgroundFrames, s.dropped, s.matteMs, s.totalMs, v.enqueued, v.droppedBusy, v.droppedQueueFull, v.deviceName ?? "none")
      last = s.frames; fh?.write(line.data(using: .utf8)!)
      frameLog?.write(pipeline.takeTimings().map { String(format: "%.2f %.2f\n", $0.matte, $0.total) }.joined().data(using: .utf8)!)
    }
  }

  /// Off means fully off. On means armed: the camera and model only run while a meeting app reads the virtual camera.
  func setRunning(_ on: Bool) {
    if on == armed { return }
    armed = on; config.enabled = on; config.save()
    if on {
      watchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.watch() }
      if alwaysOn { activate() }
      warmCaches()
    } else {
      watchTimer?.invalidate(); watchTimer = nil; deactivate()
    }
  }

  /// macOS keeps the prepared model and shaders on disk, per app and model path. So a short-lived
  /// copy of this binary can prepare them for the first call, and its memory leaves with it.
  func warmCaches() {
    if warmer != nil || !armed || running || !pipeline.needsLoad { return }
    let p = Process()
    p.executableURL = Bundle.main.executableURL; p.arguments = [warmFlag]
    p.qualityOfService = .background
    p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    p.terminationHandler = { _ in DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.warmer = nil } } }
    warmer = p
    do { try p.run() } catch { warmer = nil }
  }

  func outputDevice() -> String? {
    sink.preferredNames.first { n in CameraCatalog.device(named: n)?.isAlive == true }
  }

  func watch() {
    guard let name = outputDevice() else {
      if !running { message = "Virtual camera isn't set up yet." }
      return
    }
    // A preferred camera can appear while running. Move to it rather than keep feeding the old one.
    if running, !probing, let current = sink.status.deviceName, current != name { sink.reconnect() }
    if case .some(true) = VirtualCameraSink.runningSomewhere(named: name), !running {
      message = nil; activate()
    } else if running, !alwaysOn, !probing, Date().timeIntervalSince(lastProbe) >= probeEvery {
      probing = true; lastProbe = Date(); probeCount += 1
      sink.checkForOtherReaders { others in DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in
        guard let self else { return }
        probing = false
        if others == false { deactivate() }
      } } }
    }
  }

  func activate() {
    if running || requestingAccess { return }
    // Permission can vanish after an update, so never rely on setup having asked.
    if filePath == nil, CameraSource.access != true {
      if CameraSource.access == nil {
        requestingAccess = true
        CameraSource.request { ok in DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in
          guard let self else { return }
          requestingAccess = false; setupModel?.access = ok
          if ok { activate() } else { showAccessHelp() }
        } } }
      } else { showAccessHelp() }
      return
    }
    warmer?.terminate()   // a call goes first, and the real load does the same work
    pipeline.prepare()
    pipeline.reset()
    if source == nil { source = filePath.map { FileSource(url: URL(fileURLWithPath: $0)) } ?? CameraSource() }
    source.onFrame = { [weak self] pb, pts in self?.pipeline.ingest(pb, pts: pts) }
    try? sink.start()   // stays armed if the extension is late
    do { try source.start(); running = true; lastProbe = Date() } catch { message = "\(error)"; sink.stop() }
  }

  func showAccessHelp() {
    message = "Camera access is off."
    if accessHelpShown { return }
    accessHelpShown = true; showSetup(firstRun: false); startWatchingSetup()
  }

  func deactivate() {
    if !running { return }
    source?.stop(); sink.stop(); running = false
  }

  func key() -> SceneKey {
    let now = Date()
    let names = pipeline.scenes.availableScenes()
    let scene = names.contains(config.scene) ? config.scene : names.first ?? config.scene
    let w = config.manualWeather.flatMap(Weather.init) ?? forecast?.weather(at: now) ?? .clear
    let spot = config.place.map { ($0.latitude, $0.longitude) } ?? ZoneLocation.estimate()
    let sun = Sun.day(on: now, latitude: spot.0, longitude: spot.1)
    let p = config.manualPhase.flatMap(Phase.init) ?? DayClock.phase(at: now, sun: sun)
    return SceneKey(scene: scene, weather: w, phase: p)
  }
  func updateScene(immediate: Bool) {
    if immediate { pipeline.scenes.select(key()) } else { pipeline.scenes.transition(to: key()) }
  }
  func tick() { updateScene(immediate: false); refreshWeather() }

  /// Every 3 hours, retrying after 15 minutes on failure. The cached hours drive scenes meanwhile.
  func refreshWeather(force: Bool = false) {
    guard let place = config.place else { return }
    let now = Date()
    if !force, forecast?.isFresh(at: now, for: place) == true || now.timeIntervalSince(lastAttempt) < 900 { return }
    lastAttempt = now
    Task { @MainActor in
      guard let f = try? await WeatherService.forecast(place), config.place == place else { return }
      forecast = f; updateScene(immediate: false)
      try? JSONEncoder.iso.encode(f).write(to: Self.forecastURL)
    }
  }

  func showSetup(firstRun: Bool) {
    if let setup, setup.window.isVisible { setup.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
    let k = key()
    let scenes = pipeline.scenes.availableScenes().map { (name: $0, image: pipeline.scenes.thumbnail(scene: $0, weather: k.weather, phase: k.phase)) }
    let m = SetupModel(place: config.place, forecast: forecast, scene: k.scene, scenes: scenes, firstRun: firstRun, stage: currentStage(), access: filePath == nil ? CameraSource.access : true)
    let w = SetupWindow(model: m); setup = w; setupModel = m
    m.onCameraStep = { [weak self] in self?.cameraStep() }
    m.onAccess = { [weak self] in self?.askForCameraAccess() }
    closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w.window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.stopWatchingSetup(); NSApp.setActivationPolicy(.accessory) } }
    if case .ready = m.stage {} else { startWatchingSetup() }
    m.onScene = { [weak self] s in self?.setScene(s) }
    m.openAtLogin = firstRun || LoginItem.isOn
    m.onDone = { [weak self, weak w, weak m] p in
      guard let self else { return }
      if let m { LoginItem.set(m.openAtLogin) }
      let changed = p != config.place
      config.place = p; config.setupDone = true; config.save()
      if changed { forecast = nil; try? FileManager.default.removeItem(at: Self.forecastURL); updateScene(immediate: true); refreshWeather(force: true) }
      w?.window.close()
    }
    if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
      Task { @MainActor [weak m] in
        let found = await Updates.available(current: v)
        m?.update = found
      }
    }
    NSApp.setActivationPolicy(.regular)   // findable in the Dock while it's open
    w.show()
    #if JANELA_TEST
    if let d = demoQuery { runDemo(d, m, w) }
    #endif
  }

  func currentStage() -> CameraStage {
    if let n = outputDevice() { return .ready(n) }
    switch OBSSetup.extensionState() {
    case .active: return .ready(sink.preferredNames.first ?? "OBS Virtual Camera")
    case .waitingForUser, .disabled: return .needApproval
    case .absent: return OBSSetup.installedURL() == nil ? .needOBS : .turningOn
    }
  }

  /// The one button in the camera row: whatever comes next.
  func cameraStep() {
    guard let m = setupModel else { return }
    switch m.stage {
    case .needApproval: NSWorkspace.shared.open(OBSSetup.extensionSettings)
    case .needOBS, .failed:
      if OBSSetup.installedURL() != nil { turnOn(m); return }
      m.stage = .downloading(0)
      Task { @MainActor in
        do {
          _ = try await OBSSetup.install { p in Task { @MainActor [weak m] in
            if let m, case .downloading = m.stage { m.stage = p >= 1 ? .installing : .downloading(p) } } }
          turnOn(m)
        } catch { m.stage = .failed("\(error)") }
      }
    default: break
    }
  }

  func turnOn(_ m: SetupModel) {
    m.stage = .turningOn
    Task { @MainActor in
      do { launchedOBS = try await OBSSetup.launchHidden(); turnOnStarted = Date(); startWatchingSetup() }
      catch { m.stage = .failed("Couldn't start OBS.") }
    }
  }

  func startWatchingSetup() {
    if setupWatch != nil { return }
    if setupModel?.stage == .turningOn { turnOnStarted = Date(); Task { @MainActor in launchedOBS = try? await OBSSetup.launchHidden() } }
    setupWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.watchSetup() } }
  }

  func watchSetup() {
    guard let m = setupModel else { return }
    if filePath == nil, m.access != CameraSource.access { m.access = CameraSource.access }
    switch m.stage {
    case .turningOn, .finishInOBS, .needApproval:
      switch OBSSetup.extensionState() {
      case .active:
        m.stage = .ready(outputDevice() ?? sink.preferredNames.first ?? "OBS Virtual Camera"); closeOBS(); stopWatchingSetup()
      case .waitingForUser, .disabled:
        if m.stage != .needApproval { m.stage = .needApproval; NSWorkspace.shared.open(OBSSetup.extensionSettings) }
      case .absent:
        // A first launch can sit on OBS's own permission window, so never close OBS on a timer.
        let waited = Date().timeIntervalSince(turnOnStarted)
        let open = !NSRunningApplication.runningApplications(withBundleIdentifier: OBSSetup.bundleID).isEmpty
        if open, m.stage == .turningOn, waited > 8 { launchedOBS?.unhide(); m.stage = .finishInOBS }
        else if !open, m.stage != .needApproval, waited > 20 { launchedOBS = nil; m.stage = .failed("OBS closed before it finished. Try again.") }
      }
    default: break
    }
  }

  /// Janela only ever closes an OBS it opened itself.
  func closeOBS() { launchedOBS?.terminate(); launchedOBS = nil }
  func stopWatchingSetup() { setupWatch?.invalidate(); setupWatch = nil }

  func askForCameraAccess() {
    if CameraSource.access == false { NSWorkspace.shared.open(OBSSetup.cameraPrivacySettings); startWatchingSetup(); return }
    CameraSource.request { ok in DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.setupModel?.access = ok } } }
  }

  func setScene(_ s: String) { config.scene = s; config.save(); updateScene(immediate: true) }

  #if JANELA_TEST
  /// -setupDemo <query> -setupShots <prefix>: drives the real window for tests, without saving.
  func runDemo(_ q: String, _ m: SetupModel, _ w: SetupWindow) {
    let shots = UserDefaults.standard.string(forKey: "setupShots") ?? "/tmp/janela"
    Task { @MainActor in
      if let st = UserDefaults.standard.string(forKey: "setupStages"), st == "1" {
        let all: [(String, CameraStage, Bool?)] = [("a", .needOBS, nil), ("b", .downloading(0.42), nil), ("c", .turningOn, nil), ("c2", .finishInOBS, nil), ("d", .needApproval, nil), ("e", .failed("The download didn't match its checksum, so it wasn't installed."), false), ("f", .ready("OBS Virtual Camera"), true)]
        for (n, s, a) in all { m.stage = s; m.access = a; try? await Task.sleep(for: .milliseconds(500)); w.snapshot(to: shots + "-stage-\(n).png") }
        exit(0)
      }
      try? await Task.sleep(for: .seconds(1)); w.snapshot(to: shots + "-1-empty.png")
      m.query = q
      try? await Task.sleep(for: .seconds(2)); w.snapshot(to: shots + "-2-suggest.png")
      print("suggestions:", m.suggestions.map(\.label))
      if let f = m.suggestions.first { await m.choose(f) }
      if let o = m.scenes.first(where: { $0.name != m.scene }) { m.scene = o.name }
      try? await Task.sleep(for: .seconds(1)); w.snapshot(to: shots + "-3-chosen.png")
      print("place:", m.place?.name ?? "nil", "scene:", m.scene); exit(0)
    }
  }
  #endif

  func menuNeedsUpdate(_ m: NSMenu) {
    m.removeAllItems()
    func item(_ t: String, _ on: Bool = false, _ a: Selector? = nil, _ r: Any? = nil) -> NSMenuItem {
      let i = NSMenuItem(title: t, action: a, keyEquivalent: ""); i.target = self; i.state = on ? .on : .off; i.representedObject = r; return i }
    func sub(_ t: String, _ items: [NSMenuItem]) -> NSMenuItem { let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); let s = NSMenu(); items.forEach(s.addItem); i.submenu = s; return i }
    m.addItem(item(message ?? (!armed ? "Off" : running ? "Live on \(sink.status.deviceName ?? "virtual camera")" : "Ready: starts when an app uses the camera")))
    m.addItem(item(armed ? "Turn Off" : "Turn On", false, #selector(toggle)))
    m.addItem(item("Show Preview", previewWindow?.isVisible == true, #selector(togglePreview)))
    m.addItem(.separator())
    m.addItem(sub("Scene", pipeline?.scenes.availableScenes().map { item($0.capitalized, $0 == config.scene, #selector(pickScene), $0) } ?? []))
    m.addItem(sub("Weather", [item("Live", config.manualWeather == nil, #selector(pickWeather), nil)] + Weather.allCases.map { item($0.rawValue.capitalized, config.manualWeather == $0.rawValue, #selector(pickWeather), $0.rawValue) }))
    m.addItem(sub("Time of Day", [item("Follow the Sun", config.manualPhase == nil, #selector(pickPhase), nil)] + Phase.allCases.map { item($0.rawValue.capitalized, config.manualPhase == $0.rawValue, #selector(pickPhase), $0.rawValue) }))
    m.addItem(item("Location and Background…", false, #selector(openSettings)))
    m.addItem(item("Open at Login", LoginItem.isOn, #selector(toggleLogin)))
    m.addItem(.separator())
    m.addItem(item("Quit Janela", false, #selector(quit)))
  }

  @objc func toggle() { setRunning(!armed) }
  @objc func toggleLogin() { LoginItem.set(!LoginItem.isOn) }
  @objc func quit() { NSApp.terminate(nil) }
  @objc func pickScene(_ i: NSMenuItem) { setScene(i.representedObject as! String) }
  @objc func openSettings() { showSetup(firstRun: false) }
  @objc func pickWeather(_ i: NSMenuItem) { config.manualWeather = i.representedObject as? String; config.save(); updateScene(immediate: true) }
  @objc func pickPhase(_ i: NSMenuItem) { config.manualPhase = i.representedObject as? String; config.save(); updateScene(immediate: true) }
  @objc func togglePreview() {
    if let w = previewWindow, w.isVisible { w.orderOut(nil); previewWindow = nil; return }
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 450), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    w.title = "Janela"; w.isReleasedWhenClosed = false; w.contentAspectRatio = NSSize(width: 16, height: 9)
    w.contentView?.wantsLayer = true; w.contentView?.layer?.contentsGravity = .resizeAspect
    w.center(); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); previewWindow = w
  }
}

extension Bundle { var matteModel: URL { resourceURL!.appendingPathComponent("rvm.mlmodelc") } }
extension JSONEncoder { static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e } }
extension JSONDecoder { static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }

#if JANELA_TEST
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--chrome-test" {   // draws the icon and round-trips the login item
  MainActor.assumeIsolated {
    let image = menuBarIcon(); image.isTemplate = false
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 288, pixelsHigh: 288, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 288, height: 288).fill()
    NSColor.black.setFill(); NSColor.black.setStroke()
    image.draw(in: NSRect(x: 0, y: 0, width: 288, height: 288))
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    let before = LoginItem.isOn; LoginItem.set(true); let on = LoginItem.isOn; LoginItem.set(false)
    print("login before", before, "on", on, "off", LoginItem.isOn)
  }
  exit(0)
}
runMeasurement(CommandLine.arguments)
#endif

// The warm-up copy never reaches the lock or AppKit below, and uses neither the camera nor the sink.
let warmFlag = "--warm-caches"
if CommandLine.arguments.dropFirst().first == warmFlag {
  setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG)
  #if JANELA_TEST
  alarm(UInt32(ProcessInfo.processInfo.environment["JANELA_WARM_TIMEOUT"] ?? "") ?? 120)
  #else
  alarm(120)   // the default action ends the process, even if the app has gone
  #endif
  _ = try? Compositor()
  _ = try? MatteEngine(compiledModel: Bundle.main.matteModel)
  exit(0)
}

// Two copies would both capture the camera and write into one sink, which corrupts the picture.
// An exclusive lock covers every launch path, and the OS releases it even after a crash.
try? FileManager.default.createDirectory(at: Config.url.deletingLastPathComponent(), withIntermediateDirectories: true)
let instanceLock = open(Config.url.deletingLastPathComponent().appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
if instanceLock < 0 || flock(instanceLock, LOCK_EX | LOCK_NB) != 0 { exit(0) }

let app = NSApplication.shared
let controller = MainActor.assumeIsolated { AppController() }
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
