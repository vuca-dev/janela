import CoreML
import CoreVideo
import Foundation

/// Robust Video Matting on Core ML. Stateful: frames must arrive in order, one at a time.
/// Every tensor is Float16 in an IOSurface, shaped [1, channels, height, width] and planar, so the
/// GPU and Neural Engine share memory and the CPU never touches a pixel.
public final class MatteEngine {
  /// `foreground` holds R, G and B planes stacked vertically, each model-sized and sRGB-encoded.
  public struct Result { public let source: CVPixelBuffer; public let foreground: CVPixelBuffer; public let alpha: CVPixelBuffer }

  private final class Inputs: NSObject, MLFeatureProvider {
    let src: MLFeatureValue; let states: [String: MLFeatureValue]
    init(src: MLMultiArray, states: [String: MLFeatureValue]) { self.src = MLFeatureValue(multiArray: src); self.states = states }
    var featureNames: Set<String> { Set(["src"]).union(states.keys) }
    func featureValue(for name: String) -> MLFeatureValue? { name == "src" ? src : states[name] }
  }

  private let model: MLModel
  private var states: [String: MLFeatureValue] = [:]
  private let fgrPool: CVPixelBufferPool
  private let phaPool: CVPixelBufferPool
  private let inPool: CVPixelBufferPool
  private var shapes: [(String, [NSNumber])] = []
  private var statePools: [String: CVPixelBufferPool] = [:]
  public let width: Int
  public let height: Int

  public init(compiledModel url: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
    let cfg = MLModelConfiguration(); cfg.computeUnits = computeUnits
    model = try MLModel(contentsOf: url, configuration: cfg)
    let inputs = model.modelDescription.inputDescriptionsByName
    let c = inputs["src"]!.multiArrayConstraint!.shape
    width = c[3].intValue; height = c[2].intValue
    let f16 = kCVPixelFormatType_OneComponent16Half
    fgrPool = makePool(f16, width: width, height: height * 3, minimum: 5)
    phaPool = makePool(f16, width: width, height: height, minimum: 5)
    inPool = makePool(f16, width: width, height: height * 3, minimum: 5)
    for n in ["r1", "r2", "r3", "r4"] {
      let sh = inputs[n + "i"]!.multiArrayConstraint!.shape
      shapes.append((n, sh))
      statePools[n] = makePool(f16, width: sh[3].intValue, height: sh[1].intValue * sh[2].intValue, minimum: 3)
    }
    try reset()
  }

  /// Clears the recurrent state, in the same Float16 buffers the model writes.
  public func reset() throws {
    for (n, shape) in shapes {
      guard let pb = poolBuffer(statePools[n]!) else { throw CocoaError(.featureUnsupported) }
      CVPixelBufferLockBaseAddress(pb, [])
      memset(CVPixelBufferGetBaseAddress(pb), 0, CVPixelBufferGetDataSize(pb))
      CVPixelBufferUnlockBaseAddress(pb, [])
      states[n + "i"] = MLFeatureValue(multiArray: try MLMultiArray(pixelBuffer: pb, shape: shape))
    }
  }

  /// True while all recurrent state is Float16 in IOSurface buffers, the only form the model takes without a copy.
  public var stateMatchesModel: Bool {
    shapes.allSatisfy { n, _ in
      guard let a = states[n + "i"]?.multiArrayValue else { return false }
      return a.dataType == .float16 && a.pixelBuffer != nil
    }
  }

  public func inputBuffer() -> CVPixelBuffer? { poolBuffer(inPool) }

  /// `small` comes from `inputBuffer()` and holds `src` as planar RGB at the model's input size.
  public func predict(_ src: CVPixelBuffer, small: CVPixelBuffer) throws -> Result {
    guard let fgr = poolBuffer(fgrPool), let pha = poolBuffer(phaPool) else { throw CocoaError(.featureUnsupported) }
    let opts = MLPredictionOptions()
    func shape(_ c: Int) -> [NSNumber] { [1, c, height, width].map { NSNumber(value: $0) } }
    var backings: [String: Any] = ["fgr": try MLMultiArray(pixelBuffer: fgr, shape: shape(3)),
                                   "pha": try MLMultiArray(pixelBuffer: pha, shape: shape(1))]
    for (n, sh) in shapes {
      guard let pb = poolBuffer(statePools[n]!) else { throw CocoaError(.featureUnsupported) }
      backings[n + "o"] = try MLMultiArray(pixelBuffer: pb, shape: sh)
    }
    opts.outputBackings = backings
    let input = Inputs(src: try MLMultiArray(pixelBuffer: small, shape: shape(3)), states: states)
    let out = try model.prediction(from: input, options: opts)
    for (n, _) in shapes {
      if let v = out.featureValue(for: n + "o") { states[n + "i"] = v }
    }
    return Result(source: src, foreground: fgr, alpha: pha)
  }

  /// Compiles a .mlmodel once, into a stable cache location.
  public static func compiled(_ source: URL, cacheDirectory: URL) throws -> URL {
    if source.pathExtension == "mlmodelc" { return source }
    let dst = cacheDirectory.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".mlmodelc")
    if FileManager.default.fileExists(atPath: dst.path) { return dst }
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    let tmp = try MLModel.compileModel(at: source)
    try FileManager.default.moveItem(at: tmp, to: dst)
    return dst
  }
}
