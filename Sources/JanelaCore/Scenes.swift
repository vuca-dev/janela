import CoreGraphics
import Foundation
import ImageIO
import Metal

public enum Weather: String, CaseIterable { case clear, cloudy, rain, snow, fog }
public enum Phase: String, CaseIterable { case dawn, morning, noon, afternoon, sunset, night }
public struct SceneKey: Hashable { public var scene: String; public var weather: Weather; public var phase: Phase
  public init(scene: String, weather: Weather, phase: Phase) { self.scene = scene; self.weather = weather; self.phase = phase }
  var file: String { "\(scene)/\(weather.rawValue)-\(phase.rawValue).jpg" } }

public struct SceneFrame { public let a: MTLTexture; public let b: MTLTexture; public let mix: Float }

public enum DayClock {
  /// Maps a moment onto a phase, using today's sunrise and sunset when known.
  public static func phase(at date: Date, sunrise: Date?, sunset: Date?, calendar: Calendar = .current) -> Phase {
    let c = calendar.dateComponents([.hour, .minute], from: date)
    let h = Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60
    func hours(_ d: Date?, _ fallback: Double) -> Double {
      guard let d else { return fallback }
      let c = calendar.dateComponents([.hour, .minute], from: d); return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }
    let rise = hours(sunrise, 6.5), set = hours(sunset, 18.5)
    let day = max(set - rise, 1)
    switch h {
    case ..<(rise - 0.75): return .night
    case ..<(rise + 0.75): return .dawn
    case ..<(rise + day * 0.40): return .morning
    case ..<(rise + day * 0.60): return .noon
    case ..<(set - 0.75): return .afternoon
    case ..<(set + 0.5): return .sunset
    default: return .night
    }
  }
}

/// Owns at most two decoded backgrounds and crossfades between them.
public final class SceneController {
  private let device: MTLDevice; private let root: URL
  private let loader = DispatchQueue(label: "janela.scene", qos: .utility)
  private let lock = NSLock()
  private var current: (SceneKey, MTLTexture)?
  private var previous: MTLTexture?
  private var fadeStart: Date = .distantPast
  private var pending: SceneKey?
  public var transition: TimeInterval = 90

  public init(device: MTLDevice, root: URL) { self.device = device; self.root = root }

  public func availableScenes() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
  }

  /// Blocks until the image is decoded and shows it immediately.
  public func show(_ key: SceneKey) throws {
    let t = try Self.load(root.appendingPathComponent(key.file), device: device)
    lock.lock(); current = (key, t); previous = nil; pending = nil; lock.unlock()
  }

  /// Decodes off the render path, then fades.
  public func transition(to key: SceneKey, now: Date = Date()) {
    lock.lock(); defer { lock.unlock() }
    if current?.0 == key || pending == key { return }
    pending = key
    loader.async { [self] in
      guard let t = try? Self.load(root.appendingPathComponent(key.file), device: device) else { return }
      lock.lock(); defer { lock.unlock() }
      guard pending == key else { return }
      previous = current?.1; current = (key, t); fadeStart = Date(); pending = nil
    }
  }

  public func frame(now: Date = Date()) -> SceneFrame? {
    lock.lock(); defer { lock.unlock() }
    guard let c = current?.1 else { return nil }
    guard let p = previous else { return SceneFrame(a: c, b: c, mix: 0) }
    let t = now.timeIntervalSince(fadeStart) / transition
    if t >= 1 { previous = nil; return SceneFrame(a: c, b: c, mix: 0) }
    let s = max(0, t); return SceneFrame(a: p, b: c, mix: Float(s * s * (3 - 2 * s)))
  }

  static func load(_ url: URL, device: MTLDevice) throws -> MTLTexture {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }
    let (w, h) = (workingWidth, workingHeight)
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    px.withUnsafeMutableBytes { raw in
      let c = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
      c.interpolationQuality = .high
      let s = max(CGFloat(w) / CGFloat(img.width), CGFloat(h) / CGFloat(img.height))
      let (dw, dh) = (CGFloat(img.width) * s, CGFloat(img.height) * s)
      c.draw(img, in: CGRect(x: (CGFloat(w) - dw) / 2, y: (CGFloat(h) - dh) / 2, width: dw, height: dh))
    }
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: w, height: h, mipmapped: false)
    d.usage = .shaderRead; d.storageMode = .shared
    let t = device.makeTexture(descriptor: d)!
    px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4) }
    return t
  }
}
