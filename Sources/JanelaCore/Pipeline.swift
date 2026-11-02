import CoreML
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import os

/// Camera frame -> matte -> composite. Holds at most one waiting frame, so a slow stage
/// drops input instead of building latency. Every matte is composited onto its own frame.
public final class Pipeline: @unchecked Sendable {
  public struct Stats { public var frames = 0; public var dropped = 0; public var matteMs = 0.0; public var totalMs = 0.0 }
  public var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
  public let compositor: Compositor
  public let scenes: SceneController
  private let engine: MatteEngine
  private let worker = DispatchQueue(label: "janela.matte", qos: .userInteractive)
  private let lock = OSAllocatedUnfairLock<State>(initialState: State())
  private struct State { var waiting: (CVPixelBuffer, CMTime)?; var running = false; var stats = Stats() }
  private var pendingReset = false

  public var stats: Stats { lock.withLock { $0.stats } }

  public init(compiledModel: URL, scenesRoot: URL) throws {
    engine = try MatteEngine(compiledModel: compiledModel)
    compositor = try Compositor()
    scenes = SceneController(device: compositor.device, root: scenesRoot)
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
    if pendingReset { try? engine.reset(); compositor.resetTemporal(); pendingReset = false }
    guard let work = compositor.normalize(pb), let scene = scenes.frame(),
          let small = engine.inputBuffer(), compositor.downscale(work, into: small),
          let r = try? engine.predict(work, small: small) else { return }
    let t1 = CACurrentMediaTime()
    compositor.render(r, scene: scene) { [self] out in
      let t2 = CACurrentMediaTime()
      lock.withLock {
        $0.stats.frames += 1
        $0.stats.matteMs += ((t1 - t0) * 1000 - $0.stats.matteMs) * 0.05
        $0.stats.totalMs += ((t2 - t0) * 1000 - $0.stats.totalMs) * 0.05
      }
      onFrame?(out, pts)
    }
  }
}
