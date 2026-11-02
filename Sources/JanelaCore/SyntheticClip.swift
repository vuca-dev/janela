import AVFoundation
import CoreGraphics
import CoreVideo

/// Draws a 1080p, 30 fps H.264 clip of a stylised figure in a room, for benchmarks that must not
/// need anyone's footage. The same arguments always draw the same frames, and it loops cleanly
/// because every motion completes a whole number of cycles.
public enum SyntheticClip {
  public static func write(to url: URL, seconds: Int) async throws -> Int {
    try? FileManager.default.removeItem(at: url)
    let (w, h) = (workingWidth, workingHeight)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
      AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
    let pool = makePool(kCVPixelFormatType_32BGRA, minimum: 3)
    let room = drawRoom(w, h), grain = drawGrain(512)
    let total = seconds * 30
    for n in 0..<total {
      guard let pb = poolBuffer(pool) else { throw CocoaError(.featureUnsupported) }
      CVPixelBufferLockBaseAddress(pb, [])
      let cs = CGColorSpace(name: CGColorSpace.sRGB)!
      let c = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
      c.draw(room, in: CGRect(x: 0, y: 0, width: w, height: h))
      drawFigure(c, w, h, phase: Double(n) / Double(total))
      // Sensor-like grain, so the clip decodes like camera video and not like flat colour.
      c.setAlpha(0.05)
      c.draw(grain, in: CGRect(x: -(n * 37 % 256), y: -(n * 91 % 256), width: 2 * w, height: 2 * h), byTiling: true)
      CVPixelBufferUnlockBaseAddress(pb, [])
      while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
      adaptor.append(pb, withPresentationTime: CMTime(value: Int64(n), timescale: 30))
    }
    input.markAsFinished(); await writer.finishWriting()
    if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    return total
  }

  private static func context(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
  }

  private static func drawRoom(_ w: Int, _ h: Int) -> CGImage {
    let c = context(w, h)
    let wall = CGGradient(colorsSpace: nil, colors: [CGColor(red: 0.74, green: 0.70, blue: 0.62, alpha: 1), CGColor(red: 0.48, green: 0.45, blue: 0.42, alpha: 1)] as CFArray, locations: nil)!
    c.drawLinearGradient(wall, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
    var seed: UInt32 = 1
    func next() -> Double { seed = seed &* 1664525 &+ 1013904223; return Double(seed >> 8) / Double(1 << 24) }
    // A bookshelf: fine, high-contrast detail behind the figure.
    for shelf in 0..<5 {
      let y = 120 + shelf * 190
      c.setFillColor(CGColor(red: 0.30, green: 0.21, blue: 0.14, alpha: 1)); c.fill(CGRect(x: 1180, y: y, width: 660, height: 16))
      var x = 1190.0
      while x < 1820 {
        let t = 16 + next() * 34, tall = 110 + next() * 56
        c.setFillColor(CGColor(red: next(), green: next() * 0.8, blue: next() * 0.7, alpha: 1))
        c.fill(CGRect(x: x, y: Double(y) + 16, width: t, height: tall)); x += t + 2
      }
    }
    // A bright window.
    c.setFillColor(CGColor(red: 0.93, green: 0.96, blue: 1, alpha: 1)); c.fill(CGRect(x: 90, y: 330, width: 380, height: 560))
    c.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.22, alpha: 1))
    c.fill(CGRect(x: 272, y: 330, width: 12, height: 560)); c.fill(CGRect(x: 90, y: 600, width: 380, height: 12))
    return c.makeImage()!
  }

  private static func drawGrain(_ size: Int) -> CGImage {
    let c = context(size, size), p = c.data!.assumingMemoryBound(to: UInt8.self), row = c.bytesPerRow
    var seed: UInt32 = 7
    for y in 0..<size { for x in 0..<size {
      seed = seed &* 1664525 &+ 1013904223
      let v = UInt8(seed >> 24), q = p + y * row + x * 4
      q[0] = v; q[1] = v; q[2] = v; q[3] = 255
    } }
    return c.makeImage()!
  }

  /// A head and shoulders that sway, nod and raise an arm. `phase` runs from 0 to 1 over the clip.
  private static func drawFigure(_ c: CGContext, _ w: Int, _ h: Int, phase: Double) {
    let sway = sin(phase * 2 * .pi * 6) * 90, nod = sin(phase * 2 * .pi * 15) * 14
    let cx = Double(w) * 0.46 + sway
    c.saveGState()
    func color(_ r: Double, _ g: Double, _ b: Double) { c.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1)) }
    color(0.17, 0.25, 0.42)   // torso
    c.addPath(CGPath(roundedRect: CGRect(x: cx - 300, y: -100, width: 600, height: 560), cornerWidth: 170, cornerHeight: 170, transform: nil)); c.fillPath()
    color(0.82, 0.62, 0.50)   // neck and head
    c.fill(CGRect(x: cx - 62, y: 420, width: 124, height: 120))
    c.fillEllipse(in: CGRect(x: cx - 140, y: 500 + nod, width: 280, height: 350))
    color(0.16, 0.11, 0.08)   // hair
    c.addArc(center: CGPoint(x: cx, y: 690 + nod), radius: 150, startAngle: 0.1, endAngle: .pi - 0.1, clockwise: false); c.fillPath()
    // An arm that lifts and falls, for fast motion at the edge.
    let lift = max(0, sin(phase * 2 * .pi * 4)) * 420
    color(0.17, 0.25, 0.42); c.setLineWidth(120); c.setLineCap(.round)
    c.setStrokeColor(CGColor(red: 0.17, green: 0.25, blue: 0.42, alpha: 1))
    c.move(to: CGPoint(x: cx + 260, y: 300)); c.addLine(to: CGPoint(x: cx + 460, y: 120 + lift)); c.strokePath()
    color(0.82, 0.62, 0.50); c.fillEllipse(in: CGRect(x: cx + 395, y: 95 + lift, width: 130, height: 150))
    c.restoreGState()
  }
}
