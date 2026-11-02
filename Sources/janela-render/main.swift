import AVFoundation
import CoreML
import JanelaCore
import Foundation
import Metal

// Offline harness: runs a clip through the production engine.
// janela-render <input> <model> <scenes-dir> <scene/weather/phase> <out.mp4> <alpha.raw> [cpuAndNE|all|cpuAndGPU]
let a = CommandLine.arguments
if a.count > 3, a[1] == "compile" {   // the build compiles the model here, because Core ML's compiler ships with macOS, not the Command Line Tools
  let dst = URL(fileURLWithPath: a[3])
  try? FileManager.default.removeItem(at: dst)
  try FileManager.default.moveItem(at: try MLModel.compileModel(at: URL(fileURLWithPath: a[2])), to: dst)
  exit(0)
}
if a.count > 3, a[1] == "synth" {   // a drawn, reproducible stand-in for a camera, with no person's likeness
  let frames = try await SyntheticClip.write(to: URL(fileURLWithPath: a[2]), seconds: Int(a[3])!)
  print("wrote", frames, "frames"); exit(0)
}
if a.count > 3, a[1] == "decode" {   // the cost of file replay alone: the same 30 fps decode, with no matting
  let src = FileSource(url: URL(fileURLWithPath: a[2]))
  src.onFrame = { _, _ in }
  try src.start()
  try await Task.sleep(for: .seconds(Double(a[3])!))
  src.stop(); exit(0)
}
if a.count > 1, a[1] == "obs-hidden" {   // the app's real launch and close, on this Mac's profile
  let app = try await OBSSetup.launchHidden()
  print("launched:", app != nil, "state:", OBSSetup.extensionState())
  try await Task.sleep(for: .seconds(6))
  print("hidden:", app?.isHidden ?? false, "active:", app?.isActive ?? false)
  let t = Date(); app?.terminate()
  while app?.isTerminated == false, Date().timeIntervalSince(t) < 8 { try await Task.sleep(for: .milliseconds(200)) }
  print(String(format: "closed in %.1fs:", Date().timeIntervalSince(t)), app?.isTerminated ?? false); exit(0)
}
if a.count > 2, a[1] == "obs-verify" { print("signature:", OBSSetup.verifySignature(at: URL(fileURLWithPath: a[2]))); exit(0) }
if a.count > 2, a[1] == "obs-install" {   // real download and install into a test folder
  let folder = URL(fileURLWithPath: a[2])
  let t0 = Date()
  do {
    let u = try await OBSSetup.install(to: folder) { p in if Int(p * 1000) % 250 == 0 { print("progress", Int(p * 100)) } }
    print("installed", u.path, String(format: "%.0fs", Date().timeIntervalSince(t0)), "signature:", OBSSetup.verifySignature(at: u))
  } catch { print("failed:", error) }
  exit(0)
}
if a.count > 1, a[1] == "selftest" {
  var bad = 0
  func check(_ n: String, _ ok: Bool) { print(ok ? "ok  " : "FAIL", n); if !ok { bad += 1 } }
  var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Chicago")!
  func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: h, minute: m))! }
  let rise = at(5, 30), set = at(20, 30)
  let expect: [(Int, Phase)] = [(3, .night), (5, .dawn), (8, .morning), (13, .noon), (17, .afternoon), (20, .sunset), (22, .night)]
  for (h, p) in expect { check("\(h):00 -> \(p)", DayClock.phase(at: at(h), sun: .normal(rise: rise, set: set), calendar: cal) == p) }
  check("no sun data falls back", DayClock.phase(at: at(12), sun: nil, calendar: cal) == .noon)
  for (c, w) in [(0, Weather.clear), (3, .cloudy), (45, .fog), (61, .rain), (73, .snow), (95, .rain)] { check("wmo \(c) -> \(w)", WeatherService.weather(wmo: c) == w) }
  let root = URL(fileURLWithPath: a[2])
  let dev = MTLCreateSystemDefaultDevice()!
  let sc = SceneController(device: dev, root: root); sc.transition = 0.3
  for s in sc.availableScenes() { for w in Weather.allCases { for p in Phase.allCases { do { try sc.show(SceneKey(scene: s, weather: w, phase: p)) } catch { check("\(s)/\(w)/\(p)", false) } } } }
  check("every scene image decodes (\(sc.availableScenes().count) scenes)", true)
  try sc.show(SceneKey(scene: "room", weather: .clear, phase: .noon))
  sc.transition(to: SceneKey(scene: "room", weather: .rain, phase: .noon))
  var mixes: [Float] = []; let end = Date().addingTimeInterval(1.2)
  while Date() < end { if let f = sc.frame() { mixes.append(f.mix) }; usleep(10000) }
  check("crossfade rises then settles", (mixes.max() ?? 0) > 0.5 && mixes.last == 0 && Set(mixes).count > 5)
  // Checked against Open-Meteo: Chicago sunrise on 2026-11-01 was 12:23 UTC.
  let nov = Sun.times(on: Date(timeIntervalSince1970: 1793556000), latitude: 41.88, longitude: -87.63)
  check("matches Open-Meteo sunrise", nov.map { abs($0.rise.timeIntervalSince1970 - 1793535780) < 180 } ?? false)
  // Chicago, 2026-06-21: about 05:15 and 20:29 CDT.
  let chi = Sun.times(on: at(12), latitude: 41.88, longitude: -87.63)
  func hm(_ d: Date?) -> Int { guard let d else { return -1 }; let c = cal.dateComponents([.hour, .minute], from: d); return c.hour! * 60 + c.minute! }
  check("Chicago sunrise \(hm(chi?.rise))", abs(hm(chi?.rise) - (5 * 60 + 15)) <= 3)
  check("Chicago sunset \(hm(chi?.set))", abs(hm(chi?.set) - (20 * 60 + 29)) <= 3)
  check("polar day has no sunset", Sun.times(on: at(12), latitude: 78.2, longitude: 15.6) == nil)
  for (zone, lat, lon) in [("Asia/Tokyo", 35.68, 139.77), ("Pacific/Auckland", -36.87, 174.77), ("America/Los_Angeles", 34.05, -118.24)] {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!
    let noon = c.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 12))!
    let t = Sun.times(on: noon, latitude: lat, longitude: lon)
    let ok = t.map { $0.rise < noon && noon < $0.set && noon.timeIntervalSince($0.rise) < 8 * 3600 } ?? false
    check("\(zone) noon falls inside its own day", ok)
  }
  let z = ZoneLocation.parse("+415100-0873900"); check("zone.tab parse", z != nil && abs(z!.0 - 41.85) < 0.01 && abs(z!.1 + 87.65) < 0.01)
  let z2 = ZoneLocation.parse("-2312-04312"); check("zone.tab short form", z2 != nil && abs(z2!.0 + 23.2) < 0.01 && abs(z2!.1 + 43.2) < 0.01)
  check("local zone resolves", ZoneLocation.coordinates() != nil)
  let t0 = Date(timeIntervalSince1970: 1_800_000_000); let pl = Place(name: "T", latitude: 1, longitude: 2)
  let fc = Forecast(place: pl, fetchedAt: t0, hours: [.init(time: t0, code: 0), .init(time: t0 + 3600, code: 61)])
  check("forecast hour lookup", fc.weather(at: t0 + 1800) == .clear && fc.weather(at: t0 + 3700) == .rain)
  check("forecast expires", fc.weather(at: t0 + 7300) == nil)
  check("3-hour freshness", fc.isFresh(at: t0 + 10000, for: pl) && !fc.isFresh(at: t0 + 11000, for: pl))
  // International. A Mac on Chicago time, set to places elsewhere.
  func noon(_ zone: String, _ lat: Double, _ lon: Double) -> Phase {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!
    let d = c.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 12, minute: 30))!
    return DayClock.phase(at: d, sun: Sun.day(on: d, latitude: lat, longitude: lon), calendar: cal)
  }
  for (z, la, lo) in [("Asia/Tokyo", 35.68, 139.77), ("Pacific/Auckland", -36.87, 174.77), ("Europe/Lisbon", 38.72, -9.14), ("Asia/Kolkata", 28.61, 77.21), ("America/Sao_Paulo", -23.55, -46.63)] {
    let p = noon(z, la, lo); check("midday in \(z) is \(p) on a Chicago Mac", p == .noon)
  }
  var nz = Calendar(identifier: .gregorian); nz.timeZone = TimeZone(identifier: "Pacific/Auckland")!
  for (m, exp) in [(1, 20.5), (7, 17.5)] { // southern summer and winter sunsets
    let d = nz.date(from: DateComponents(year: 2026, month: m, day: 15, hour: 12))!
    let s = Sun.times(on: d, latitude: -36.87, longitude: 174.77)?.set
    let h = s.map { Double(nz.component(.hour, from: $0)) + Double(nz.component(.minute, from: $0)) / 60 } ?? -1
    check("Auckland month \(m) sunset \(String(format: "%.2f", h))", abs(h - exp) < 0.75)
  }
  var sv = Calendar(identifier: .gregorian); sv.timeZone = TimeZone(identifier: "Arctic/Longyearbyen")!
  let june = sv.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: 12))!, dec = sv.date(from: DateComponents(year: 2026, month: 12, day: 21, hour: 12))!
  check("Svalbard June stays light", DayClock.phase(at: june, sun: Sun.day(on: june, latitude: 78.2, longitude: 15.6)) != .night)
  check("Svalbard December stays dark", DayClock.phase(at: dec, sun: Sun.day(on: dec, latitude: 78.2, longitude: 15.6)) == .night)
  let old = ZoneLocation.estimate(TimeZone(identifier: "Asia/Calcutta")!); check("old zone name estimates longitude \(old.1)", abs(old.1 - 82.5) < 15)
  let ls = LocationSearch()
  let cases: [(String, Double, Double)] = [("Chicago", 41.88, -87.63), ("90210", 34.1, -118.4), ("東京", 35.68, 139.77), ("Москва", 55.75, 37.62), ("القاهرة", 30.04, 31.24),
    ("München", 48.14, 11.58), ("Lisboa", 38.72, -9.14), ("São Paulo", -23.55, -46.63), ("Reykjavík", 64.15, -21.94), ("Sydney Australia", -33.87, 151.21),
    ("SW1A 1AA", 51.5, -0.14), ("10115 Berlin", 52.53, 13.38), ("M5V", 43.64, -79.4), ("75001 Paris", 48.86, 2.34), ("100-0001", 35.68, 139.75), ("01310-100", -23.56, -46.65), ("2000 Australia", -33.87, 151.2)]
  for (q, la, lo) in cases {
    do {
      let r = try await ls.search(q)
      guard let f = r.first else { check("search \(q) -> none", false); continue }
      let p = try await ls.resolve(f)
      check("search \(q) -> \(p.name) (\(p.latitude), \(p.longitude))", abs(p.latitude - la) < 1 && abs(p.longitude - lo) < 1)
    } catch {
      let e = error as NSError
      if e.domain == "MKErrorDomain", e.code == 3 { print("skip search \(q): Apple Maps throttled it") }   // a limit on Apple's side, not a bug here
      else { check("search \(q) error \(error.localizedDescription)", false) }
    }
  }
  let one = try await ls.search("C"); check("one letter returns nothing", one.isEmpty)
  let nope = try await ls.search("zzzzqqqqxxxx"); check("nonsense returns nothing", nope.isEmpty)
  for (n, la, lo) in [("Tokyo", 35.68, 139.77), ("Reykjavik", 64.15, -21.94), ("Sydney", -33.87, 151.21), ("Nairobi", -1.29, 36.82)] {
    let f = try await WeatherService.forecast(Place(name: n, latitude: la, longitude: lo))
    check("forecast \(n): \(f.hours.count)h, \(f.weather(at: Date()).map(\.rawValue) ?? "nil")", f.hours.count >= 24 && f.weather(at: Date()) != nil)
  }
  // Model
  let model = URL(fileURLWithPath: a.count > 3 ? a[3] : "Resources/rvm.mlpackage")
  let tmpCache = FileManager.default.temporaryDirectory.appendingPathComponent("janela-cache-\(UUID().uuidString)")
  let tmpA = tmpCache.appendingPathComponent("a/m.mlpackage"), tmpB = tmpCache.appendingPathComponent("b/m.mlpackage")
  for u in [tmpA, tmpB] {
    try FileManager.default.createDirectory(at: u.appendingPathComponent("Data"), withIntermediateDirectories: true)
    try "weights".write(to: u.appendingPathComponent("Data/w.bin"), atomically: true, encoding: .utf8)
  }
  check("equal content keys the same", try MatteEngine.contentKey(tmpA) == MatteEngine.contentKey(tmpB))
  try "weights2".write(to: tmpB.appendingPathComponent("Data/w.bin"), atomically: true, encoding: .utf8)
  check("a re-export changes the key", try MatteEngine.contentKey(tmpA) != MatteEngine.contentKey(tmpB))
  let compiledModel = try MatteEngine.compiled(model, cacheDirectory: tmpCache)
  check("compiled name carries the key", compiledModel.lastPathComponent.contains(try MatteEngine.contentKey(model)))
  check("compiled model is reused", try MatteEngine.compiled(model, cacheDirectory: tmpCache).path == compiledModel.path)
  let comp = try Compositor()
  let eng = try MatteEngine(compiledModel: compiledModel)
  check("fresh state matches the model", eng.stateMatchesModel)
  func bgra(_ fill: (UnsafeMutablePointer<UInt8>, Int) -> Void) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, workingWidth, workingHeight, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](), kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary, &pb)
    CVPixelBufferLockBaseAddress(pb!, []); let row = CVPixelBufferGetBytesPerRow(pb!)
    let p = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<workingHeight { fill(p + y * row, y) }
    CVPixelBufferUnlockBaseAddress(pb!, []); return pb!
  }
  // Red, green and blue bands: the planes must come back in R, G, B order and the right place.
  let bands = bgra { p, y in
    let (r, g, b): (UInt8, UInt8, UInt8) = y < 360 ? (255, 0, 0) : y < 720 ? (0, 255, 0) : (0, 0, 255)
    for x in 0..<workingWidth { p[x * 4] = b; p[x * 4 + 1] = g; p[x * 4 + 2] = r; p[x * 4 + 3] = 255 }
  }
  let small = eng.inputBuffer()!
  check("GPU writes planar input", comp.downscale(bands, into: small))
  CVPixelBufferLockBaseAddress(small, .readOnly)
  let half = CVPixelBufferGetBaseAddress(small)!.assumingMemoryBound(to: Float16.self), rowLength = CVPixelBufferGetBytesPerRow(small) / 2
  func plane(_ c: Int, _ y: Int) -> Float { Float(half[(c * eng.height + y) * rowLength + 640]) }
  check("planes are R, G, B", abs(plane(0, 100) - 1) < 0.01 && plane(1, 100) < 0.01 && plane(2, 100) < 0.01
    && plane(0, 360) < 0.01 && abs(plane(1, 360) - 1) < 0.01 && plane(2, 360) < 0.01
    && plane(0, 640) < 0.01 && plane(1, 640) < 0.01 && abs(plane(2, 640) - 1) < 0.01)
  CVPixelBufferUnlockBaseAddress(small, .readOnly)
  func output(_ r: MatteEngine.Result) -> [Float16] {
    CVPixelBufferLockBaseAddress(r.foreground, .readOnly); defer { CVPixelBufferUnlockBaseAddress(r.foreground, .readOnly) }
    let n = CVPixelBufferGetDataSize(r.foreground) / 2
    return Array(UnsafeBufferPointer(start: CVPixelBufferGetBaseAddress(r.foreground)!.assumingMemoryBound(to: Float16.self), count: n))
  }
  let run1 = output(try eng.predict(bands, small: small))
  check("state after a frame matches the model", eng.stateMatchesModel)
  let run2 = output(try eng.predict(bands, small: small))
  try eng.reset()
  check("state after reset matches the model", eng.stateMatchesModel)
  check("state carries between frames", run1 != run2)
  check("reset restores the first-frame result", output(try eng.predict(bands, small: small)) == run1)
  // Lazy loading. macOS prepares a model per path, so a fresh copy guarantees a slow load to watch.
  let slowModel = tmpCache.appendingPathComponent("slow-\(UUID().uuidString).mlmodelc")
  try FileManager.default.copyItem(at: compiledModel, to: slowModel)
  let lazy = Pipeline(compiledModel: slowModel, scenesRoot: root)
  let lazyKey = SceneKey(scene: "room", weather: .clear, phase: .noon)
  lazy.scenes.select(lazyKey); lazy.scenes.transition(to: lazyKey); usleep(200_000)
  check("nothing decodes before first use", lazy.scenes.frame() == nil && !lazy.modelReady)
  // A frame of pure magenta stands in for the camera: it must never reach the output before the model does.
  let cameraFrame = bgra { p, _ in for x in 0..<workingWidth { p[x * 4] = 255; p[x * 4 + 1] = 0; p[x * 4 + 2] = 255; p[x * 4 + 3] = 255 } }
  let leak = NSLock(); nonisolated(unsafe) var leaked = false, shown = 0
  lazy.onFrame = { pb, _ in
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), row = CVPixelBufferGetBytesPerRow(pb)
    var magenta = 0, n = 0
    for y in stride(from: 0, to: workingHeight, by: 40) { for x in stride(from: 0, to: workingWidth, by: 40) {
      let q = p + y * row + x * 4; n += 1
      if q[0] > 240 && q[2] > 240 && q[1] < 20 { magenta += 1 }
    } }
    leak.lock(); if !lazy.modelReady && magenta > n / 50 { leaked = true }; shown += 1; leak.unlock()
  }
  let prepareStart = Date(); lazy.prepare(); lazy.prepare()
  check("prepare returns at once", Date().timeIntervalSince(prepareStart) < 0.05)
  let lazyDeadline = Date().addingTimeInterval(30)
  while (lazy.stats.frames < 5) && Date() < lazyDeadline { lazy.ingest(cameraFrame, pts: .zero); usleep(33_000) }
  check("background shows while the model loads (\(lazy.stats.backgroundFrames) frames)", lazy.stats.backgroundFrames > 0)
  check("the camera frame never shows before the model is ready", !leaked)
  check("matte frames follow once the model is ready", lazy.modelReady && lazy.stats.frames >= 5)
  check("nothing left to load after loading", !lazy.needsLoad)
  let broken = Pipeline(compiledModel: tmpCache.appendingPathComponent("missing.mlmodelc"), scenesRoot: root)
  let failed = DispatchSemaphore(value: 0)
  broken.onLoadFailure = { _ in failed.signal() }
  broken.scenes.select(lazyKey); broken.prepare()
  check("a model that can't load reports it", failed.wait(timeout: .now() + 10) == .success)
  check("a failed load can be retried", broken.needsLoad)
  try? FileManager.default.removeItem(at: tmpCache)
  // Benchmark clip
  let clipURL = FileManager.default.temporaryDirectory.appendingPathComponent("janela-synth-\(UUID().uuidString).mov")
  let wrote = try await SyntheticClip.write(to: clipURL, seconds: 1)
  check("synthetic clip writes 30 frames", wrote == 30 && (try? clipURL.checkResourceIsReachable()) == true)
  try? FileManager.default.removeItem(at: clipURL)
  // OBS setup
  let ext = "com.obsproject.obs-studio.mac-camera-extension (33.0.1/40954849292)\tOBS Virtual Camera\t"
  check("extension active", OBSSetup.parseState("*\t*\t2MMRE5MTB8\t\(ext)[activated enabled]") == .active)
  check("extension waiting", OBSSetup.parseState("\t\t2MMRE5MTB8\t\(ext)[activated waiting for user]") == .waitingForUser)
  check("extension switched off", OBSSetup.parseState("\t\t2MMRE5MTB8\t\(ext)[activated disabled]") == .disabled)
  check("extension absent", OBSSetup.parseState("0 extension(s)") == .absent)
  check("extension being removed", OBSSetup.parseState("\t\t2MMRE5MTB8\t\(ext)[terminated waiting to uninstall on reboot]") == .absent)
  check("this Mac's extension is active", OBSSetup.extensionState() == .active)
  check("real OBS signature verifies", OBSSetup.verifySignature(at: URL(fileURLWithPath: "/Applications/OBS.app")))
  check("other apps fail the OBS signature check", !OBSSetup.verifySignature(at: URL(fileURLWithPath: "/System/Applications/Calculator.app")))
  let rel = try await OBSSetup.latestRelease()
  check("latest release \(rel.url.lastPathComponent), \(rel.size / 1_000_000) MB", rel.url.lastPathComponent.hasSuffix("-macOS-Apple.dmg") && rel.sha256.count == 64)
  let tmpHome = FileManager.default.temporaryDirectory.appendingPathComponent("janela-home-\(UUID().uuidString)")
  try OBSSetup.prepareProfile(home: tmpHome)
  let ini = tmpHome.appendingPathComponent("Library/Application Support/obs-studio/user.ini")
  check("wizard skip written on a fresh profile", (try? String(contentsOf: ini, encoding: .utf8))?.contains("FirstRun=true") == true)
  try "mine".write(to: ini, atomically: true, encoding: .utf8); try OBSSetup.prepareProfile(home: tmpHome)
  check("existing OBS settings are left alone", (try? String(contentsOf: ini, encoding: .utf8)) == "mine")
  try? FileManager.default.removeItem(at: tmpHome)
  check("a newer patch is an update", Updates.isNewer("v0.1.3", than: "0.1.2"))
  check("0.1.10 is newer than 0.1.9", Updates.isNewer("v0.1.10", than: "0.1.9"))
  check("0.2 is newer than 0.1.9", Updates.isNewer("0.2", than: "0.1.9"))
  check("the same version is not an update", !Updates.isNewer("v0.1.2", than: "0.1.2"))
  check("0.1 equals 0.1.0", !Updates.isNewer("0.1", than: "0.1.0"))
  check("an older release is not an update", !Updates.isNewer("v0.1.1", than: "0.1.2"))
  check("a pre-release tag is not an update", !Updates.isNewer("v0.2-beta", than: "0.1.2"))
  check("an empty tag is not an update", !Updates.isNewer("", than: "0.1.2"))
  check("release tag parses", Updates.parseTag(Data(#"{"tag_name":"v0.1.3"}"#.utf8)) == "v0.1.3")
  check("a bad reply parses to nothing", Updates.parseTag(Data("{}".utf8)) == nil)
  let liveOld = await Updates.available(current: "0.0.1"), liveNew = await Updates.available(current: "99.0")
  check("GitHub reports a newer release, \(liveOld ?? "none")", liveOld != nil)
  check("no update past the latest release", liveNew == nil)
  exit(bad == 0 ? 0 : 1)
}
guard a.count >= 7 else { print("usage"); exit(2) }
let parts = a[4].split(separator: "/").map(String.init)
let units: MLComputeUnits = a.count > 7 ? (a[7] == "cpuAndGPU" ? .cpuAndGPU : a[7] == "all" ? .all : .cpuAndNeuralEngine) : .cpuAndNeuralEngine
let cache = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/Janela")
let engine = try MatteEngine(compiledModel: MatteEngine.compiled(URL(fileURLWithPath: a[2]), cacheDirectory: cache), computeUnits: units)
let comp = try Compositor()
let env = ProcessInfo.processInfo.environment
func f(_ k: String) -> Float? { env[k].flatMap(Float.init) }
if let v = f("LO") { comp.settings.chokeLo = v }
if let v = f("HI") { comp.settings.chokeHi = v }
if let v = f("K") { comp.settings.kStill = v }
if let v = f("MLO") { comp.settings.motionLo = v / 255 }
if let v = f("MHI") { comp.settings.motionHi = v / 255 }
if let v = f("ELO") { comp.settings.errorLo = v }
if let v = f("EHI") { comp.settings.errorHi = v }
let scenes = SceneController(device: comp.device, root: URL(fileURLWithPath: a[3]))
try scenes.show(SceneKey(scene: parts[0], weather: Weather(rawValue: parts[1])!, phase: Phase(rawValue: parts[2])!))

let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let tracks = try await asset.loadTracks(withMediaType: .video)
let reader = try AVAssetReader(asset: asset)
let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [
  kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
  kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
])
reader.add(output); reader.startReading()
let dst = URL(fileURLWithPath: a[5]); try? FileManager.default.removeItem(at: dst)
let writer = try AVAssetWriter(outputURL: dst, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
  AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: workingWidth, AVVideoHeightKey: workingHeight,
  AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
FileManager.default.createFile(atPath: a[6], contents: nil)
let alphaFile = FileHandle(forWritingAtPath: a[6])!

var ml: [Double] = [], gpu: [Double] = [], norm: [Double] = []
var n = 0
let done = DispatchSemaphore(value: 0)
while let s = output.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(s) {
  autoreleasepool {
    let t0 = CACurrentMediaTime()
    guard let work = comp.normalize(pb) else { return }
    let t1 = CACurrentMediaTime()
    let small = engine.inputBuffer()!; _ = comp.downscale(work, into: small)
    let r = try! engine.predict(work, small: small)
    let t2 = CACurrentMediaTime()
    comp.render(r, scene: scenes.frame()!) { out in
      gpu.append(CACurrentMediaTime() - t2)
      while !input.isReadyForMoreMediaData { usleep(500) }
      adaptor.append(out, withPresentationTime: CMTime(value: Int64(n), timescale: 30))
      done.signal()
    }
    done.wait()
    norm.append(t1 - t0); ml.append(t2 - t1); n += 1
    alphaFile.write(comp.readAlphaForEvaluation())
  }
}
input.markAsFinished(); await writer.finishWriting()
func stat(_ v: [Double]) -> String { let s = v.dropFirst(10).sorted(); return String(format: "p50 %.1f  p95 %.1f  max %.1f ms", s[s.count/2]*1000, s[s.count*95/100]*1000, s.last!*1000) }
print("frames", n, "writer", writer.status.rawValue, writer.error?.localizedDescription ?? "ok")
print("normalize", stat(norm)); print("matte    ", stat(ml)); print("gpu      ", stat(gpu))
