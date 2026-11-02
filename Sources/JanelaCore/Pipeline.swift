import CoreML
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import os

/// Camera frame -> matte -> composite. Holds at most one waiting frame, so a slow stage
/// drops input instead of building latency. Every matte is composited onto its own frame.
///
/// The model and GPU resources load on first use, off the main thread. Until the model is ready
/// the output is the background alone, so a reader sees the scene and never the raw camera.
public final class Pipeline: @unchecked Sendable {
  public struct Stats { public var frames = 0; public var backgroundFrames = 0; public var dropped = 0; public var matteMs = 0.0; public var totalMs = 0.0 }
  public var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
  /// Called on a background queue if the model can't load. The next `prepare()` retries.
  public var onLoadFailure: ((Error) -> Void)?
  public let scenes: SceneController
  private let model: URL
  private let worker = DispatchQueue(label: "janela.matte", qos: .userInteractive)
  private let loader = DispatchQueue(label: "janela.load", qos: .userInitiated)
  private let lock = OSAllocatedUnfairLock<State>(initialState: State())
  private struct State {
    var waiting: (CVPixelBuffer, CMTime)?; var running = false; var stats = Stats()
    var loading = false; var compositor: Compositor?; var engine: MatteEngine?
    var timings: [(matte: Double, total: Double)]?
  }
  private var pendingReset = false

  public var stats: Stats { lock.withLock { $0.stats } }
  public var modelReady: Bool { lock.withLock { $0.engine != nil } }
  /// Begins keeping every frame's times in milliseconds, for measurement.
  public func recordTimings() { lock.withLock { $0.timings = [] } }
  public func takeTimings() -> [(matte: Double, total: Double)] {
    lock.withLock { s in let t = s.timings ?? []; if s.timings != nil { s.timings = [] }; return t }
  }

  /// Does no work beyond remembering where the model and scenes are.
  public init(compiledModel: URL, scenesRoot: URL) {
    model = compiledModel
    scenes = SceneController(root: scenesRoot)
  }

  /// Loads everything that isn't loaded yet, in the background. Safe to call repeatedly.
  public func prepare() {
    let go = lock.withLock { s -> Bool in
      if s.engine != nil || s.loading { return false }
      s.loading = true; return true
    }
    if !go { return }
    loader.async { [self] in
      do {
        if lock.withLock({ $0.compositor }) == nil {
          let c = try Compositor()
          scenes.attach(c.device)
          lock.withLock { $0.compositor = c }
        }
        let e = try MatteEngine(compiledModel: model)
        lock.withLock { $0.engine = e; $0.loading = false }
      } catch {
        lock.withLock { $0.loading = false }
        onLoadFailure?(error)
      }
    }
  }

  /// Call after a gap in frames, so recurrent state never spans different moments.
  public func reset() { worker.async { [self] in pendingReset = true } }

  public func ingest(_ pb: CVPixelBuffer, pts: CMTime) {
    let start = lock.withLock { s -> Bool in
      if s.waiting != nil { s.stats.dropped += 1 }
      s.waiting = (pb, pts)
      if s.running { return false }
      s.running = true; return true
    }
    if start { worker.async { [self] in drain() } }
  }

  private func drain() {
    while let (pb, pts) = lock.withLock({ s -> (CVPixelBuffer, CMTime)? in
      guard let n = s.waiting else { s.running = false; return nil }
      s.waiting = nil; return n
    }) {
      autoreleasepool { process(pb, pts) }
    }
  }

  private func process(_ pb: CVPixelBuffer, _ pts: CMTime) {
    let t0 = CACurrentMediaTime()
    let (loaded, ready) = lock.withLock { ($0.compositor, $0.engine) }
    guard let compositor = loaded, let scene = scenes.frame() else { return }
    guard let engine = ready else {
      compositor.renderBackground(scene: scene) { [self] out in
        lock.withLock { $0.stats.backgroundFrames += 1 }
        onFrame?(out, pts)
      }
      return
    }
    if pendingReset { try? engine.reset(); compositor.resetTemporal(); pendingReset = false }
    guard let work = compositor.normalize(pb),
          let small = engine.inputBuffer(), compositor.downscale(work, into: small),
          let r = try? engine.predict(work, small: small) else { return }
    let t1 = CACurrentMediaTime()
    compositor.render(r, scene: scene) { [self] out in
      let t2 = CACurrentMediaTime()
      lock.withLock {
        $0.stats.frames += 1
        $0.stats.matteMs += ((t1 - t0) * 1000 - $0.stats.matteMs) * 0.05
        $0.stats.totalMs += ((t2 - t0) * 1000 - $0.stats.totalMs) * 0.05
        $0.timings?.append((matte: (t1 - t0) * 1000, total: (t2 - t0) * 1000))
      }
      onFrame?(out, pts)
    }
  }
}
