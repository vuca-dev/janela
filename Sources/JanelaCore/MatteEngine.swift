import CoreML
import CoreVideo
import Foundation

/// Robust Video Matting on Core ML. Stateful: frames must arrive in order, one at a time.
public final class MatteEngine {
  public struct Result { public let source: CVPixelBuffer; public let foreground: CVPixelBuffer; public let alpha: CVPixelBuffer }

  private final class Inputs: NSObject, MLFeatureProvider {
    let src: MLFeatureValue; let states: [String: MLFeatureValue]
    init(src: CVPixelBuffer, states: [String: MLFeatureValue]) { self.src = MLFeatureValue(pixelBuffer: src); self.states = states }
    var featureNames: Set<String> { Set(["src"]).union(states.keys) }
    func featureValue(for name: String) -> MLFeatureValue? { name == "src" ? src : states[name] }
  }

  private let model: MLModel
  private var states: [String: MLFeatureValue] = [:]
  private let fgrPool: CVPixelBufferPool
  private let phaPool: CVPixelBufferPool
  private let inPool: CVPixelBufferPool
  private var shapes: [(String, [NSNumber])] = []
  public let width: Int
  public let height: Int

  public init(compiledModel url: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
    let cfg = MLModelConfiguration(); cfg.computeUnits = computeUnits
    model = try MLModel(contentsOf: url, configuration: cfg)
    let inputs = model.modelDescription.inputDescriptionsByName
    let c = inputs["src"]!.imageConstraint!
    width = c.pixelsWide; height = c.pixelsHigh
    fgrPool = makePool(kCVPixelFormatType_32BGRA, width: width, height: height, minimum: 5)
    phaPool = makePool(kCVPixelFormatType_OneComponent8, width: width, height: height, minimum: 5)
    inPool = makePool(kCVPixelFormatType_32BGRA, width: width, height: height, minimum: 5)
    for n in ["r1", "r2", "r3", "r4"] { shapes.append((n, inputs[n + "i"]!.multiArrayConstraint!.shape)) }
    try reset()
  }

  public func reset() throws {
    for (n, shape) in shapes {
      let a = try MLMultiArray(shape: shape, dataType: .float32)
      a.withUnsafeMutableBytes { p, _ in p.initializeMemory(as: UInt8.self, repeating: 0) }
      states[n + "i"] = MLFeatureValue(multiArray: a)
    }
  }

  public func inputBuffer() -> CVPixelBuffer? { poolBuffer(inPool) }

  /// `small` is `src` at the model's input size, or `src` itself when they match.
  public func predict(_ src: CVPixelBuffer, small: CVPixelBuffer) throws -> Result {
    guard let fgr = poolBuffer(fgrPool), let pha = poolBuffer(phaPool) else { throw CocoaError(.featureUnsupported) }
    let opts = MLPredictionOptions()
    opts.outputBackings = ["fgr": fgr, "pha": pha]
    let out = try model.prediction(from: Inputs(src: small, states: states), options: opts)
    for (n, _) in shapes {
      if let v = out.featureValue(for: n + "o") { states[n + "i"] = v }
    }
    return Result(source: src,
                  foreground: out.featureValue(for: "fgr")?.imageBufferValue ?? fgr,
                  alpha: out.featureValue(for: "pha")?.imageBufferValue ?? pha)
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
