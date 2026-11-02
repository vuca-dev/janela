#if JANELA_TEST
import AppKit
import CoreVideo
import Darwin
import JanelaCore
import QuartzCore

// Test builds only. These run inside the app's own binary because macOS keeps a prepared model per
// app and model path, so another tool can't see the app's cache. No camera, sink or instance lock.

private func footprintMB() -> Double {
  var i = task_vm_info_data_t(); var c = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / 4)
  _ = withUnsafeMutablePointer(to: &i) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &c) } }
  return Double(i.phys_footprint) / 1_048_576
}

private func cpuSeconds() -> Double {
  var r = rusage(); getrusage(RUSAGE_SELF, &r)
  func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
  return s(r.ru_utime) + s(r.ru_stime)
}

private func frame() -> CVPixelBuffer {
  var pb: CVPixelBuffer?
  CVPixelBufferCreate(nil, workingWidth, workingHeight, kCVPixelFormatType_32BGRA,
    [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](), kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary, &pb)
  return pb!
}

private let testScene = SceneKey(scene: "atelier", weather: .clear, phase: .noon)
private func ms(_ a: Double, _ b: Double) -> String { String(format: "%.0f", (b - a) * 1000) }

/// --first-matte: from a call to `prepare()` until the first matte frame reaches `onFrame`, fed at 30 fps.
func measureFirstMatte(model: URL, scenes: URL) -> Never {
  let p = Pipeline(compiledModel: model, scenesRoot: scenes)
  let gate = NSLock(); nonisolated(unsafe) var background: Double?
  p.scenes.select(testScene)
  let pb = frame()
  let t0 = CACurrentMediaTime()
  p.prepare()
  p.onFrame = { _, _ in gate.lock(); if background == nil { background = CACurrentMediaTime() }; gate.unlock() }
  while p.stats.frames == 0 {
    if CACurrentMediaTime() - t0 > 60 { print("first-matte timeout"); exit(1) }
    p.ingest(pb, pts: .zero); usleep(33_000)
  }
  let t1 = CACurrentMediaTime()
  gate.lock(); let bg = background ?? t1; gate.unlock()
  print("first-output \(ms(t0, bg)) first-matte \(ms(t0, t1)) background-frames \(p.stats.backgroundFrames)")
  exit(0)
}

/// --stages: the same work one stage at a time, so each can be timed alone.
func measureStages(model: URL, scenes: URL) throws -> Never {
  let t0 = CACurrentMediaTime()
  let c = try Compositor()
  let t1 = CACurrentMediaTime()
  let s = SceneController(device: c.device, root: scenes)
  try s.show(testScene)
  let t2 = CACurrentMediaTime()
  let e = try MatteEngine(compiledModel: model)
  let t3 = CACurrentMediaTime()
  let small = e.inputBuffer()!
  _ = try e.predict(small, small: small)
  let t4 = CACurrentMediaTime()
  print("compositor \(ms(t0, t1)) scene \(ms(t1, t2)) model \(ms(t2, t3)) first-predict \(ms(t3, t4))")
  exit(0)
}

/// --replay <clip> <seconds>: the live path from a replayed clip, with no sink.
func measureReplay(clip: String, seconds: Double, model: URL, scenes: URL) -> Never {
  let p = Pipeline(compiledModel: model, scenesRoot: scenes)
  p.scenes.select(testScene); p.prepare()
  let source = FileSource(url: URL(fileURLWithPath: clip))
  source.onFrame = { pb, pts in p.ingest(pb, pts: pts) }
  try? source.start()
  while p.stats.frames == 0 { usleep(50_000) }
  sleep(5)
  p.recordTimings()
  let (f0, d0, c0, t0) = (p.stats.frames, p.stats.dropped, cpuSeconds(), CACurrentMediaTime())
  var peak = 0.0, sum = 0.0, n = 0.0
  let end = t0 + seconds
  while CACurrentMediaTime() < end { usleep(1_000_000); let m = footprintMB(); peak = max(peak, m); sum += m; n += 1 }
  let (f1, d1, c1, t1) = (p.stats.frames, p.stats.dropped, cpuSeconds(), CACurrentMediaTime())
  source.stop(); usleep(200_000)
  let total = p.takeTimings().map(\.total).sorted()
  print(String(format: "fps %.1f cpu %.1f%% dropped %d frame-p50 %.1f frame-p95 %.1f footprint-avg %.0f footprint-peak %.0f",
    Double(f1 - f0) / (t1 - t0), (c1 - c0) * 100 / (t1 - t0), d1 - d0, total[total.count / 2], total[total.count * 95 / 100], sum / n, peak))
  exit(0)
}

func runMeasurement(_ a: [String]) {
  let model = Bundle.main.resourceURL!.appendingPathComponent("rvm.mlmodelc"), scenes = Bundle.main.resourceURL!.appendingPathComponent("scenes")
  guard a.count > 1 else { return }
  switch a[1] {
  case "--first-matte": measureFirstMatte(model: model, scenes: scenes)
  case "--stages": do { try measureStages(model: model, scenes: scenes) } catch { print("failed", error); exit(1) }
  case "--replay": measureReplay(clip: a[2], seconds: Double(a[3])!, model: model, scenes: scenes)
  default: return
  }
}
#endif
