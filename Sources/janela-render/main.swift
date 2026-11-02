import AVFoundation
import CoreML
import JanelaCore
import Foundation
import Metal

// Offline harness: runs a clip through the production engine.
// janela-render <input> <model> <scenes-dir> <scene/weather/phase> <out.mp4> <alpha.raw> [cpuAndNE|all|cpuAndGPU]
let a = CommandLine.arguments
if a.count > 1, a[1] == "selftest" {
  var bad = 0
  func check(_ n: String, _ ok: Bool) { print(ok ? "ok  " : "FAIL", n); if !ok { bad += 1 } }
  var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Chicago")!
  func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: h, minute: m))! }
  let rise = at(5, 30), set = at(20, 30)
  let expect: [(Int, Phase)] = [(3, .night), (5, .dawn), (8, .morning), (13, .noon), (17, .afternoon), (20, .sunset), (22, .night)]
  for (h, p) in expect { check("\(h):00 -> \(p)", DayClock.phase(at: at(h), sunrise: rise, sunset: set, calendar: cal) == p) }
  check("no sun data falls back", DayClock.phase(at: at(12), sunrise: nil, sunset: nil, calendar: cal) == .noon)
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
  let place = try await WeatherService.search("Chicago")
  check("geocode \(place?.name ?? "nil")", place != nil)
  if let place { let c = try await WeatherService.conditions(place); check("forecast \(c.weather) rise \(c.sunrise.map(String.init(describing:)) ?? "nil")", c.sunrise != nil && c.sunset != nil) }
  exit(bad == 0 ? 0 : 1)
}
guard a.count >= 7 else { print("usage"); exit(2) }
let parts = a[4].split(separator: "/").map(String.init)
let units: MLComputeUnits = a.count > 7 ? (a[7] == "cpuAndNE" ? .cpuAndNeuralEngine : a[7] == "cpuAndGPU" ? .cpuAndGPU : .all) : .all
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
