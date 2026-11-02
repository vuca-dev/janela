import AVFoundation
import CoreVideo

public protocol FrameSource: AnyObject {
  var onFrame: ((CVPixelBuffer, CMTime) -> Void)? { get set }
  func start() throws
  func stop()
}

public enum SourceError: Error, CustomStringConvertible {
  case noCamera, denied
  public var description: String { self == .denied ? "Camera access denied" : "No camera found" }
}

public final class CameraSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate {
  public var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
  private let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "janela.capture", qos: .userInteractive)
  private var configured = false

  /// nil until the user has been asked.
  public static var access: Bool? {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: return true
    case .notDetermined: return nil
    default: return false
    }
  }

  public static func request(_ done: @escaping @Sendable (Bool) -> Void) { AVCaptureDevice.requestAccess(for: .video, completionHandler: done) }

  /// Physical cameras only: a virtual camera must never be able to feed itself.
  static func device() -> AVCaptureDevice? {
    let d = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
      .filter { !$0.localizedName.localizedCaseInsensitiveContains("virtual") }
    return d.first { $0.deviceType == .builtInWideAngleCamera } ?? d.first
  }

  private func configure() throws {
    guard let dev = Self.device() else { throw SourceError.noCamera }
    session.beginConfiguration(); defer { session.commitConfiguration() }
    session.addInput(try AVCaptureDeviceInput(device: dev))
    let out = AVCaptureVideoDataOutput()
    out.alwaysDiscardsLateVideoFrames = true
    out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                         kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
    out.setSampleBufferDelegate(self, queue: queue)
    session.addOutput(out)
    // Set last: adding inputs and outputs can reset the format.
    let fmt = dev.formats.filter { f in
      let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
      return d.width >= 1280 && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 29 }
    }.min { a, b in
      // Closest at or above 1080p, preferring 16:9.
      func score(_ f: AVCaptureDevice.Format) -> Int {
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        return abs(Int(d.height) - 1080) + (Int(d.width) * 9 == Int(d.height) * 16 ? 0 : 500)
      }
      return score(a) < score(b)
    }
    if let fmt {
      try dev.lockForConfiguration()
      dev.activeFormat = fmt
      dev.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
      dev.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
      dev.unlockForConfiguration()
    }
    configured = true
  }

  public func start() throws {
    if AVCaptureDevice.authorizationStatus(for: .video) != .authorized { throw SourceError.denied }
    if !configured { try configure() }
    session.startRunning()
  }
  public func stop() { session.stopRunning() }

  public func captureOutput(_ o: AVCaptureOutput, didOutput s: CMSampleBuffer, from c: AVCaptureConnection) {
    if let pb = CMSampleBufferGetImageBuffer(s) { onFrame?(pb, CMSampleBufferGetPresentationTimeStamp(s)) }
  }
}

/// Replays a clip in a loop in real time, with host-clock timestamps. Drives the entire live path in tests.
public final class FileSource: FrameSource {
  public var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
  private let url: URL; private var running = false
  private let queue = DispatchQueue(label: "janela.file", qos: .userInteractive)
  public init(url: URL) { self.url = url }
  public func start() throws { running = true; queue.async { [self] in while running { playOnce() } } }
  public func stop() { running = false }
  private func playOnce() {
    let sem = DispatchSemaphore(value: 0); nonisolated(unsafe) var track: AVAssetTrack?
    let asset = AVURLAsset(url: url)
    Task { track = try? await asset.loadTracks(withMediaType: .video).first; sem.signal() }
    sem.wait()
    guard let track, let r = try? AVAssetReader(asset: asset) else { running = false; return }
    let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
    r.add(o); r.startReading()
    var next = CACurrentMediaTime()
    while running, let s = o.copyNextSampleBuffer() {
      autoreleasepool {
        let wait = next - CACurrentMediaTime(); if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        next += 1.0 / 30
        if let pb = CMSampleBufferGetImageBuffer(s) { onFrame?(pb, CMClockGetTime(CMClockGetHostTimeClock())) }
      }
    }
    r.cancelReading()
  }
}
