import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import VideoToolbox
import os

/// Publishes frames into an already installed CoreMediaIO camera extension's sink stream.
///
/// Soft-failure contract: nothing here crashes or blocks the caller when the extension is absent.
/// `start()` throws if no sink is available *but stays armed*, attaching automatically when one
/// appears (for example once the user approves OBS in System Settings). A lost extension is
/// re-attached the same way, and a more preferred device replaces a less preferred one. Call
/// `stop()` to disarm. `send` is safe to call in any state.
///
/// Frames matching the sink's format, size and backed by an IOSurface go through untouched: the
/// surface itself crosses the process boundary, so the caller must not write to a buffer after
/// sending it (take a fresh one from a CVPixelBufferPool for each frame). Anything else is
/// converted once by VTPixelTransferSession into a private IOSurface pool.
public final class VirtualCameraSink: @unchecked Sendable {
  public enum Failure: Error, CustomStringConvertible {
    case noSinkDevice(searched: [String], visible: [String])
    case queueUnavailable(device: String, status: OSStatus)
    case startRefused(device: String, status: OSStatus)

    public var description: String {
      switch self {
      case .noSinkDevice(let searched, let visible):
        return "no sink stream on \(searched); visible devices: \(visible)"
      case .queueUnavailable(let device, let status):
        return "\(device): CMIOStreamCopyBufferQueue failed (\(status))"
      case .startRefused(let device, let status):
        return "\(device): CMIODeviceStartStream failed (\(status))"
      }
    }
  }

  public struct Status: Sendable {
    public var deviceName: String?
    public var sinkFormat: CameraStreamInfo.Format?
    public var isPassthrough = false
    public var queueCapacity = 0
    public var enqueued = 0
    public var droppedBusy = 0
    public var droppedQueueFull = 0
    public var droppedDisconnected = 0
    public var droppedError = 0
    public var reconnects = 0
    public var lastError: String?
  }

  /// How long the sink may refuse every frame before we assume the extension died under us.
  private static let stallTimeout: TimeInterval = 3
  private static let pollInterval: TimeInterval = 1

  private struct Shared {
    var connection: Connection?
    var busy = false
    var status = Status()
    var queueFullSince: Date?
  }

  public let preferredNames: [String]
  private let work = DispatchQueue(label: "janela.virtualcamera", qos: .userInteractive)
  private let shared = OSAllocatedUnfairLock(initialState: Shared())
  private var watchdog: DispatchSourceTimer?  // work queue only

  public init(preferredNames: [String] = ["OBS Virtual Camera"]) {
    self.preferredNames = preferredNames
  }

  deinit { watchdog?.cancel() }

  public var status: Status { shared.withLock { $0.status } }

  /// Attaches to the most preferred available sink. Blocks briefly on CMIO IPC, so call it off the
  /// render thread. Idempotent. See the type comment for what a throw means.
  public func start() throws {
    let result: Result<Void, Error> = work.sync {
      if watchdog == nil { armWatchdog() }
      if shared.withLock({ $0.connection }) != nil { return .success(()) }
      return Result { try connect() }
    }
    try result.get()
  }

  /// Never blocks: frames are dropped if the sink is absent, its queue is full, or the previous
  /// frame is still being converted. `pts` should be on the host clock (the extensions forward it
  /// as the frame's host time); a pts more than a second away from it is replaced with now.
  public func send(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
    let connection: Connection? = shared.withLock { state in
      guard let connection = state.connection else {
        state.status.droppedDisconnected += 1
        return nil
      }
      if connection.isFull {
        state.status.droppedQueueFull += 1
        if state.queueFullSince == nil { state.queueFullSince = Date() }
        return nil
      }
      state.queueFullSince = nil
      if state.busy {
        state.status.droppedBusy += 1
        return nil
      }
      state.busy = true
      return connection
    }
    guard let connection else { return }
    nonisolated(unsafe) let frame = pixelBuffer
    work.async { [self] in
      let result = connection.enqueue(frame, pts: pts)
      shared.withLock { state in
        state.busy = false
        switch result {
        case .enqueued: state.status.enqueued += 1
        case .queueFull: state.status.droppedQueueFull += 1
        case .failed(let message):
          state.status.droppedError += 1
          state.status.lastError = message
        }
      }
    }
  }

  /// Detaches and disarms. Blocks until pending work has finished. Safe to call repeatedly.
  /// True while any process has this device's streams running, including our own sink.
  public static func runningSomewhere(named name: String) -> Bool? {
    guard let d = CameraCatalog.device(named: name) else { return nil }
    return CMIOProperty.uint32(d.id, kCMIODevicePropertyDeviceIsRunningSomewhere).map { $0 != 0 }
  }

  public func stop() {
    work.sync {
      watchdog?.cancel()
      watchdog = nil
      disconnect()
    }
  }

  /// Tears the connection down and re-attaches, exactly as the watchdog does after a stall.
  public func reconnect() {
    work.async { [self] in
      disconnect()
      try? connect()
    }
  }

  // MARK: Work queue only

  private func armWatchdog() {
    let timer = DispatchSource.makeTimerSource(queue: work)
    timer.schedule(
      deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .milliseconds(100)
    )
    timer.setEventHandler { [weak self] in self?.poll() }
    timer.resume()
    watchdog = timer
  }

  private func poll() {
    let (connection, fullSince) = shared.withLock { ($0.connection, $0.queueFullSince) }
    guard let connection else {
      if (try? connect()) != nil { bumpReconnects() }
      return
    }
    let best = bestDevice()
    let lost = best == nil || !CameraCatalog.deviceExists(connection.deviceID)
    let stalled = fullSince.map { Date().timeIntervalSince($0) > Self.stallTimeout } ?? false
    if lost || stalled || (best.map { $0.id != connection.deviceID } ?? false) {
      disconnect()
      if (try? connect()) != nil { bumpReconnects() }
    }
  }

  private func bumpReconnects() {
    shared.withLock { $0.status.reconnects += 1 }
  }

  private func bestDevice() -> CameraDeviceInfo? {
    let devices = CameraCatalog.devices()
    for name in preferredNames {
      if let device = devices.first(where: { $0.name == name && $0.isAlive }),
        device.sinkStream != nil
      {
        return device
      }
    }
    return nil
  }

  private func connect() throws {
    guard let device = bestDevice(), let sink = device.sinkStream else {
      let failure = Failure.noSinkDevice(
        searched: preferredNames, visible: CameraCatalog.devices().map(\.name))
      shared.withLock { $0.status.lastError = failure.description }
      throw failure
    }
    do {
      let connection = try Connection(device: device, sink: sink)
      shared.withLock { state in
        state.connection = connection
        state.busy = false
        state.queueFullSince = nil
        state.status.deviceName = device.name
        state.status.sinkFormat = connection.format
        state.status.isPassthrough = connection.format.pixelFormat == kCVPixelFormatType_32BGRA
        state.status.queueCapacity = Int(connection.queueCapacity)
        state.status.lastError = nil
      }
    } catch {
      shared.withLock { $0.status.lastError = "\(error)" }
      throw error
    }
  }

  private func disconnect() {
    let connection: Connection? = shared.withLock { state in
      defer {
        state.connection = nil
        state.busy = false
        state.queueFullSince = nil
        state.status.deviceName = nil
        state.status.sinkFormat = nil
        state.status.isPassthrough = false
      }
      return state.connection
    }
    connection?.close()
  }
}

/// A started sink stream. Everything but `isFull` runs on the sink's work queue.
private final class Connection: @unchecked Sendable {
  enum Outcome {
    case enqueued
    case queueFull
    case failed(String)
  }

  let deviceID: CMIODeviceID
  let format: CameraStreamInfo.Format
  private let streamID: CMIOStreamID
  private let queue: CMSimpleQueue
  let queueCapacity: Int32
  private let fallbackDuration: CMTime
  private var transfer: VTPixelTransferSession?
  private var pool: CVPixelBufferPool?
  private var formatDescription: CMFormatDescription?
  private var lastPTS = CMTime.invalid

  init(device: CameraDeviceInfo, sink: CameraStreamInfo) throws {
    deviceID = device.id
    streamID = sink.id
    format = Self.negotiate(sink)
    fallbackDuration = CMTime(
      value: 1, timescale: Int32((sink.frameRates.max() ?? 30).rounded()))

    var unmanaged: Unmanaged<CMSimpleQueue>?
    let altered: CMIODeviceStreamQueueAlteredProc = { _, _, _ in }
    let status = CMIOStreamCopyBufferQueue(sink.id, altered, nil, &unmanaged)
    guard status == noErr, let queue = unmanaged?.takeRetainedValue() else {
      throw VirtualCameraSink.Failure.queueUnavailable(device: device.name, status: status)
    }
    self.queue = queue
    queueCapacity = CMSimpleQueueGetCapacity(queue)

    let started = CMIODeviceStartStream(device.id, sink.id)
    guard started == noErr else {
      throw VirtualCameraSink.Failure.startRefused(device: device.name, status: started)
    }
  }

  /// Exact size wins, BGRA breaks ties since it can be passed straight through; otherwise the
  /// largest available. Extensions are free to offer several formats, ours each offer one.
  private static func negotiate(_ sink: CameraStreamInfo) -> CameraStreamInfo.Format {
    let descriptions = CMIOProperty.formats(sink.id)
    func score(_ f: CameraStreamInfo.Format) -> Int {
      var score = f.width * f.height
      if f.width == 1920 && f.height == 1080 { score += 1 << 40 }
      if f.pixelFormat == kCVPixelFormatType_32BGRA { score += 1 }
      return score
    }
    let best = descriptions.max { score(CameraCatalog.format($0)) < score(CameraCatalog.format($1)) }
    if let best, let active = sink.activeFormat, score(CameraCatalog.format(best)) > score(active) {
      _ = CMIOProperty.setActiveFormat(sink.id, best)
    }
    if let active = CMIOProperty.activeFormat(sink.id) { return CameraCatalog.format(active) }
    return sink.formats.first
      ?? .init(pixelFormat: kCVPixelFormatType_32BGRA, width: 1920, height: 1080)
  }

  /// Single-word read of the queue's counters, so this cannot block.
  var isFull: Bool { CMSimpleQueueGetCount(queue) >= queueCapacity }

  func enqueue(_ input: CVPixelBuffer, pts: CMTime) -> Outcome {
    let frame: CVPixelBuffer
    if needsConversion(input) {
      switch convert(input) {
      case .success(let converted): frame = converted
      case .failure(let failure): return .failed(failure.message)
      }
    } else {
      frame = input
    }

    if let existing = formatDescription,
      CMVideoFormatDescriptionMatchesImageBuffer(existing, imageBuffer: frame)
    {
    } else {
      formatDescription = nil
      let status = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: frame,
        formatDescriptionOut: &formatDescription)
      guard status == noErr else { return .failed("format description: \(status)") }
    }

    let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
    let usable = pts.isValid && abs((pts - hostNow).seconds) < 1
    let presentation = usable ? pts : hostNow
    var duration = fallbackDuration
    if lastPTS.isValid {
      let delta = presentation - lastPTS
      if delta.seconds > 0 && delta.seconds < 1 { duration = delta }
    }
    lastPTS = presentation

    var timing = CMSampleTimingInfo(
      duration: duration, presentationTimeStamp: presentation, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    let status = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: frame, formatDescription: formatDescription!,
      sampleTiming: &timing, sampleBufferOut: &sample)
    guard status == noErr, let sample else { return .failed("sample buffer: \(status)") }

    // The consumer of a CMIO queue takes over the +1 we hand it.
    let element = Unmanaged.passRetained(sample)
    guard CMSimpleQueueEnqueue(queue, element: element.toOpaque()) == noErr else {
      element.release()
      return .queueFull
    }
    return .enqueued
  }

  func close() {
    CMIODeviceStopStream(deviceID, streamID)
    while let element = CMSimpleQueueDequeue(queue) {
      Unmanaged<CMSampleBuffer>.fromOpaque(element).release()
    }
    if let transfer { VTPixelTransferSessionInvalidate(transfer) }
    transfer = nil
    pool = nil
  }

  private func needsConversion(_ frame: CVPixelBuffer) -> Bool {
    CVPixelBufferGetPixelFormatType(frame) != format.pixelFormat
      || CVPixelBufferGetWidth(frame) != format.width
      || CVPixelBufferGetHeight(frame) != format.height
      || CVPixelBufferGetIOSurface(frame) == nil
  }

  private struct ConversionFailure: Error { let message: String }

  private func convert(_ input: CVPixelBuffer) -> Result<CVPixelBuffer, ConversionFailure> {
    if pool == nil || transfer == nil {
      if let failure = makeConverter() { return .failure(ConversionFailure(message: failure)) }
    }
    var output: CVPixelBuffer?
    // A threshold makes an exhausted pool fail instead of growing while a client hoards frames.
    let aux = [kCVPixelBufferPoolAllocationThresholdKey: 8] as CFDictionary
    let created = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
      kCFAllocatorDefault, pool!, aux, &output)
    guard created == kCVReturnSuccess, let output else {
      return .failure(ConversionFailure(message: "pool: \(created)"))
    }
    let status = VTPixelTransferSessionTransferImage(transfer!, from: input, to: output)
    guard status == noErr else {
      return .failure(ConversionFailure(message: "pixel transfer: \(status)"))
    }
    // The conversion tags the output BT.709. Some extensions rewraps the surface using a format
    // description with no colour extensions; tagged buffers then fail CMSampleBufferCreate in the
    // extension and its source stream silently stops, even for buffers sent later. Untagged 8-bit
    // video-range YUV at these sizes is read as BT.709 by clients anyway.
    CVBufferRemoveAllAttachments(output)
    return .success(output)
  }

  private func makeConverter() -> String? {
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: format.pixelFormat,
      kCVPixelBufferWidthKey: format.width,
      kCVPixelBufferHeightKey: format.height,
      kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
    ]
    var created: CVPixelBufferPool?
    let poolStatus = CVPixelBufferPoolCreate(
      kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
    guard poolStatus == kCVReturnSuccess else { return "pool create: \(poolStatus)" }

    var session: VTPixelTransferSession?
    let sessionStatus = VTPixelTransferSessionCreate(
      allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
    guard sessionStatus == noErr, let session else { return "transfer session: \(sessionStatus)" }
    VTSessionSetProperty(
      session, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(
      session, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries,
      value: kCVImageBufferColorPrimaries_ITU_R_709_2)
    VTSessionSetProperty(
      session, key: kVTPixelTransferPropertyKey_DestinationTransferFunction,
      value: kCVImageBufferTransferFunction_ITU_R_709_2)
    VTSessionSetProperty(
      session, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
      value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    pool = created
    transfer = session
    return nil
  }
}

extension CameraCatalog {
  /// Cheaper than `devices()`: only reads the id list.
  static func deviceExists(_ id: CMIODeviceID) -> Bool {
    CMIOProperty.array(
      CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices, of: CMIODeviceID.self
    ).contains(id)
  }
}
