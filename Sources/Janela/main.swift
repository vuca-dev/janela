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
  lazy var alwaysOn = UserDefaults.standard.bool(forKey: "alwaysOn")
  lazy var probeEvery: TimeInterval = { let v = UserDefaults.standard.double(forKey: "probeEvery"); return v > 0 ? v : 120 }()
  var forecast: Forecast?
  var lastAttempt = Date.distantPast
  var setup: SetupWindow?
  static let forecastURL = Config.url.deletingLastPathComponent().appendingPathComponent("forecast.json")
  var message: String?
  let filePath = UserDefaults.standard.string(forKey: "file")      // -file <path> replays a clip
  let statsPath = UserDefaults.standard.string(forKey: "stats")    // -stats <path> appends one line a second

  func applicationDidFinishLaunching(_ n: Notification) {
    status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    status.button?.image = NSImage(systemSymbolName: "sun.horizon.fill", accessibilityDescription: "Janela")
    let menu = NSMenu(); menu.delegate = self; status.menu = menu
    do {
      let res = Bundle.main.resourceURL!
      pipeline = try Pipeline(compiledModel: res.appendingPathComponent("rvm.mlmodelc"), scenesRoot: res.appendingPathComponent("scenes"))
    } catch { message = "Could not load the model: \(error)"; return }
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
      MainActor.assumeIsolated { self?.tick() } }
    tick()
    if let statsPath { startStats(statsPath) }
    if config.enabled { setRunning(true) }
    if config.setupDone != true || UserDefaults.standard.string(forKey: "setupDemo") != nil { showSetup(firstRun: true) }
  }

  func applicationShouldHandleReopen(_ a: NSApplication, hasVisibleWindows v: Bool) -> Bool {
    showSetup(firstRun: false); return false
  }

  func startStats(_ path: String) {
    FileManager.default.createFile(atPath: path, contents: nil)
    let fh = FileHandle(forWritingAtPath: path)
    var last = 0
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      guard let self else { return }
      let s = pipeline.stats, v = sink.status
      let line = String(format: "run=%d probes=%d fps=%d dropped=%d matte=%.1f total=%.1f sinkOK=%d busy=%d full=%d dev=%@\n", running ? 1 : 0, probeCount, s.frames - last, s.dropped, s.matteMs, s.totalMs, v.enqueued, v.droppedBusy, v.droppedQueueFull, v.deviceName ?? "none")
      last = s.frames; fh?.write(line.data(using: .utf8)!)
    }
  }

  /// Off means fully off. On means armed: the camera and model only run while a meeting app reads the virtual camera.
  func setRunning(_ on: Bool) {
    if on == armed { return }
    armed = on; config.enabled = on; config.save()
    if on {
      watchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.watch() }
      if filePath == nil { CameraSource.request { ok in DispatchQueue.main.async { [weak self] in
        if !ok { self?.message = "Camera access is off. Enable it in System Settings." } } } }
      if alwaysOn { activate() }
    } else {
      watchTimer?.invalidate(); watchTimer = nil; deactivate()
    }
  }

  func outputDevice() -> String? {
    sink.preferredNames.first { n in CameraCatalog.device(named: n)?.isAlive == true }
  }

  func watch() {
    guard let name = outputDevice() else {
      if !running { message = "Virtual camera not installed. See README." }
      return
    }
    // A preferred camera can appear while running. Move to it rather than keep feeding the old one.
    if running, !probing, let current = sink.status.deviceName, current != name { sink.reconnect() }
    if case .some(true) = VirtualCameraSink.runningSomewhere(named: name), !running {
      message = nil; activate()
    } else if running, !alwaysOn, !probing, Date().timeIntervalSince(lastProbe) >= probeEvery {
      probing = true; lastProbe = Date(); probeCount += 1
      sink.stop()
      // The sink was the only stream if the device now goes quiet.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
        guard let self else { return }
        probing = false
        if VirtualCameraSink.runningSomewhere(named: name) == false { deactivate() } else { try? sink.start() }
      }
    }
  }

  func activate() {
    if running { return }
    pipeline.reset()
    if source == nil { source = filePath.map { FileSource(url: URL(fileURLWithPath: $0)) } ?? CameraSource() }
    source.onFrame = { [weak self] pb, pts in self?.pipeline.ingest(pb, pts: pts) }
    try? sink.start()   // stays armed if the extension is late
    do { try source.start(); running = true; lastProbe = Date() } catch { message = "\(error)"; sink.stop() }
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
    if immediate { try? pipeline.scenes.show(key()) } else { pipeline.scenes.transition(to: key()) }
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
    let m = SetupModel(place: config.place, scene: k.scene, scenes: scenes, firstRun: firstRun, cameraName: outputDevice())
    let w = SetupWindow(model: m); setup = w
    m.onScene = { [weak self] s in self?.setScene(s) }
    m.onDone = { [weak self, weak w] p in
      guard let self else { return }
      let changed = p != config.place
      config.place = p; config.setupDone = true; config.save()
      if changed { forecast = nil; try? FileManager.default.removeItem(at: Self.forecastURL); updateScene(immediate: true); refreshWeather(force: true) }
      w?.window.close()
    }
    w.show()
    if let d = UserDefaults.standard.string(forKey: "setupDemo") { runDemo(d, m, w) }
  }

  func setScene(_ s: String) { config.scene = s; config.save(); updateScene(immediate: true) }

  /// -setupDemo <query> -setupShots <prefix>: drives the real window for tests, without saving.
  func runDemo(_ q: String, _ m: SetupModel, _ w: SetupWindow) {
    let shots = UserDefaults.standard.string(forKey: "setupShots") ?? "/tmp/janela"
    Task { @MainActor in
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
    m.addItem(.separator())
    m.addItem(item("Quit Janela", false, #selector(quit)))
  }

  @objc func toggle() { setRunning(!armed) }
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

extension JSONEncoder { static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e } }
extension JSONDecoder { static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }

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
