import CoreVideo
import Metal

public let workingWidth = 1920
public let workingHeight = 1080

func makePool(_ format: OSType, width: Int = workingWidth, height: Int = workingHeight, minimum: Int) -> CVPixelBufferPool {
  let attrs: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: format,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
    kCVPixelBufferMetalCompatibilityKey as String: true,
    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
  ]
  var pool: CVPixelBufferPool?
  let poolAttrs = [kCVPixelBufferPoolMinimumBufferCountKey as String: minimum]
  CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, attrs as CFDictionary, &pool)
  return pool!
}

func poolBuffer(_ pool: CVPixelBufferPool) -> CVPixelBuffer? {
  var pb: CVPixelBuffer?
  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
  return pb
}

final class TextureCache {
  let cache: CVMetalTextureCache
  init(device: MTLDevice) {
    var c: CVMetalTextureCache?
    CVMetalTextureCacheCreate(nil, nil, device, nil, &c)
    cache = c!
  }
  /// The CVMetalTexture must outlive GPU use; callers retain it in the command buffer handler.
  func texture(_ pb: CVPixelBuffer, _ format: MTLPixelFormat) -> (MTLTexture, CVMetalTexture)? {
    var t: CVMetalTexture?
    let s = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, format,
      CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &t)
    guard s == kCVReturnSuccess, let t, let tex = CVMetalTextureGetTexture(t) else { return nil }
    return (tex, t)
  }
}
