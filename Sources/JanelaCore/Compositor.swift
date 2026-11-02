import CoreGraphics
import CoreVideo
import Metal
import MetalPerformanceShaders

public struct StabilizerSettings {
  public var kStill: Float = 0.07
  public var motionLo: Float = 2.5 / 255
  public var motionHi: Float = 8 / 255
  public var errorLo: Float = 0.08
  public var errorHi: Float = 0.30
  public var chokeLo: Float = 0.40
  public var chokeHi: Float = 0.97
  public init() {}
}

private struct StabilizerParams { var kStill, motionLo, motionHi, errorLo, errorHi, first: Float }
private struct CompositeParams { var bgMix, lo, hi: Float; var frame, showMatte: UInt32 }

public final class Compositor {
  public let device: MTLDevice
  public var settings = StabilizerSettings()
  public var showMatte = false
  private let queue: MTLCommandQueue
  private let textures: TextureCache
  private let lumaDownsample, lumaBlur, motionField, stabilize, composite, planar: MTLComputePipelineState
  private let scaler: MPSImageBilinearScale
  private let outPool = makePool(kCVPixelFormatType_32BGRA, minimum: 5)
  private let workPool = makePool(kCVPixelFormatType_32BGRA, minimum: 5)
  private var lumaRaw: MTLTexture
  private var luma: [MTLTexture]
  private let motion: MTLTexture
  private var history: [MTLTexture]
  private var frame: UInt32 = 0
  /// Latest stabilised matte, exposed for offline evaluation.
  public var latestAlpha: MTLTexture { history[0] }

  public init() throws {
    let dev = MTLCreateSystemDefaultDevice()!
    device = dev
    queue = dev.makeCommandQueue()!
    textures = TextureCache(device: dev)
    let lib = try dev.makeLibrary(source: shaderSource, options: nil)
    func pipe(_ n: String) throws -> MTLComputePipelineState {
      try dev.makeComputePipelineState(function: lib.makeFunction(name: n)!)
    }
    lumaDownsample = try pipe("lumaDownsample"); lumaBlur = try pipe("lumaBlur")
    motionField = try pipe("motionField"); stabilize = try pipe("stabilize"); composite = try pipe("composite")
    planar = try pipe("planar")
    scaler = MPSImageBilinearScale(device: dev)
    func tex(_ w: Int, _ h: Int, _ f: MTLPixelFormat) -> MTLTexture {
      let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
      d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
      return dev.makeTexture(descriptor: d)!
    }
    let (qw, qh) = (workingWidth / 4, workingHeight / 4)
    lumaRaw = tex(qw, qh, .r16Float)
    luma = [tex(qw, qh, .r16Float), tex(qw, qh, .r16Float)]
    motion = tex(qw, qh, .r8Unorm)
    history = [tex(workingWidth, workingHeight, .r16Float), tex(workingWidth, workingHeight, .r16Float)]
  }

  public func resetTemporal() { frame = 0 }

  /// Aspect-fills any source into a working-size BGRA buffer. Passes through when it already matches.
  public func normalize(_ src: CVPixelBuffer) -> CVPixelBuffer? {
    let (w, h) = (CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src))
    if w == workingWidth && h == workingHeight && CVPixelBufferGetIOSurface(src) != nil { return src }
    guard let dst = poolBuffer(workPool),
          let (s, st) = textures.texture(src, .bgra8Unorm), let (d, dt) = textures.texture(dst, .bgra8Unorm),
          let cb = queue.makeCommandBuffer() else { return nil }
    let scale = max(Double(workingWidth) / Double(w), Double(workingHeight) / Double(h))
    var t = MPSScaleTransform(scaleX: scale, scaleY: scale,
      translateX: (Double(workingWidth) - Double(w) * scale) / 2,
      translateY: (Double(workingHeight) - Double(h) * scale) / 2)
    withUnsafePointer(to: &t) { scaler.scaleTransform = $0; scaler.encode(commandBuffer: cb, sourceTexture: s, destinationTexture: d) }
    scaler.scaleTransform = nil
    cb.addCompletedHandler { _ in _ = (st, dt) }
    cb.commit(); cb.waitUntilCompleted()
    return dst
  }

  /// GPU downscale to the model's input size, as planar RGB.
  public func downscale(_ src: CVPixelBuffer, into dst: CVPixelBuffer) -> Bool {
    guard let (s, st) = textures.texture(src, .bgra8Unorm), let (d, dt) = textures.texture(dst, .r16Float),
          let cb = queue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() else { return false }
    e.setComputePipelineState(planar); e.setTexture(s, index: 0); e.setTexture(d, index: 1)
    e.dispatchThreads(MTLSize(width: d.width, height: d.height, depth: 1),
                      threadsPerThreadgroup: MTLSize(width: planar.threadExecutionWidth, height: 1, depth: 1))
    e.endEncoding()
    cb.addCompletedHandler { _ in _ = (st, dt) }
    cb.commit(); cb.waitUntilCompleted()
    return true
  }

  /// Encodes one frame. `completion` runs on a Metal thread once `out` is ready.
  public func render(_ r: MatteEngine.Result, scene: SceneFrame, completion: @escaping (CVPixelBuffer) -> Void) {
    guard let out = poolBuffer(outPool),
          let (src, t1) = textures.texture(r.source, .bgra8Unorm_srgb),
          let (fgr, t2) = textures.texture(r.foreground, .r16Float),
          let (pha, t3) = textures.texture(r.alpha, .r16Float),
          let (dst, t4) = textures.texture(out, .bgra8Unorm),
          let cb = queue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() else { return }
    func run(_ p: MTLComputePipelineState, _ ts: [MTLTexture], grid: MTLTexture) {
      e.setComputePipelineState(p)
      for (i, t) in ts.enumerated() { e.setTexture(t, index: i) }
      e.dispatchThreads(MTLSize(width: grid.width, height: grid.height, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: p.threadExecutionWidth, height: 1, depth: 1))
    }
    let first = frame == 0
    run(lumaDownsample, [src, lumaRaw], grid: lumaRaw)
    e.memoryBarrier(scope: .textures)
    run(lumaBlur, [lumaRaw, luma[0]], grid: luma[0])
    e.memoryBarrier(scope: .textures)
    run(motionField, [luma[0], first ? luma[0] : luma[1], motion], grid: motion)
    e.memoryBarrier(scope: .textures)
    var sp = StabilizerParams(kStill: settings.kStill, motionLo: settings.motionLo, motionHi: settings.motionHi,
                              errorLo: settings.errorLo, errorHi: settings.errorHi, first: first ? 1 : 0)
    e.setBytes(&sp, length: MemoryLayout<StabilizerParams>.size, index: 0)
    run(stabilize, [pha, history[0], motion, history[1]], grid: history[1])
    e.memoryBarrier(scope: .textures)
    var cp = CompositeParams(bgMix: scene.mix, lo: settings.chokeLo, hi: settings.chokeHi, frame: frame, showMatte: showMatte ? 1 : 0)
    e.setBytes(&cp, length: MemoryLayout<CompositeParams>.size, index: 0)
    run(composite, [src, fgr, history[1], scene.a, scene.b, dst], grid: dst)
    e.endEncoding()
    history.swapAt(0, 1); luma.swapAt(0, 1); frame &+= 1
    cb.addCompletedHandler { _ in _ = (t1, t2, t3, t4); completion(out) }
    cb.commit()
  }
}

extension Compositor {
  /// Slow, offline only: the composited-space matte downscaled to 810x540 for scoring.
  public func readAlphaForEvaluation() -> Data {
    let w = 810, h = 540
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
    d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .shared
    let t = device.makeTexture(descriptor: d)!
    let q = device.makeCommandQueue()!; let cb = q.makeCommandBuffer()!
    let s = MPSImageBilinearScale(device: device)
    // 1920x1080 is centre-cropped from 1620x1080; undo by reading the same crop region.
    var xf = MPSScaleTransform(scaleX: 810.0 / 1620.0 * (1620.0 / 1920.0), scaleY: 810.0 / 1620.0 * (1620.0 / 1920.0), translateX: 0, translateY: Double(540 - 455) / 2)
    withUnsafePointer(to: &xf) { s.scaleTransform = $0; s.encode(commandBuffer: cb, sourceTexture: latestAlpha, destinationTexture: t) }
    s.scaleTransform = nil
    cb.commit(); cb.waitUntilCompleted()
    var data = Data(count: w * h)
    data.withUnsafeMutableBytes { t.getBytes($0.baseAddress!, bytesPerRow: w, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
    return data
  }
}
