// camera-probe: diagnostics for Janela's virtual camera output.
//
//   camera-probe list
//   camera-probe push <device> [--seconds N] [--fps N] [--verify] [--reconnect-at S]
//                     [--restart-at S] [--native] [--stale-pts]
//   camera-probe read <device> [--seconds N] [--avf]
//
// `push` writes 1920x1080 BGRA frames whose top band is a barcode of the frame number. `read` runs
// in its own process, reads the device's SOURCE side and decodes that barcode, so counting decoded
// frames proves they travelled through the extension rather than being a placeholder image.
// Exit status of `read` (and `push --verify`) is 0 only if frames were decoded.
//
// `--native` sends 420v 1280x720 instead, skipping conversion (for extensions with a native 720p sink).
// `--stale-pts` sends a pts far from the host clock, to exercise the fallback.
//
// macOS attributes camera access to the app that launched this tool. If that app (the terminal) has
// no Camera permission, `read` opens the stream and silently receives nothing.

import AVFoundation
import CoreMedia
import CoreMediaIO
import CoreVideo
import JanelaCamera
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let magic: UInt32 = 0xDB
let barcodeCells = 32

func value(of flag: String, in args: [String]) -> Double? {
  guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
  return Double(args[i + 1])
}

func hostSeconds() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

// MARK: Test pattern

func makePool(width: Int, height: Int) -> CVPixelBufferPool {
  let attributes: [CFString: Any] = [
    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey: width,
    kCVPixelBufferHeightKey: height,
    kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
  ]
  var pool: CVPixelBufferPool?
  CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
  return pool!
}

func makeNativePool() -> CVPixelBufferPool {
  let attributes: [CFString: Any] = [
    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    kCVPixelBufferWidthKey: 1280,
    kCVPixelBufferHeightKey: 720,
    kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
  ]
  var pool: CVPixelBufferPool?
  CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
  return pool!
}

func drawNativePattern(into buffer: CVPixelBuffer, frame: UInt32) {
  CVPixelBufferLockBaseAddress(buffer, [])
  defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
  let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
  let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
  let code = (magic << 24) | (frame & 0xff_ffff)
  let cell = 1280 / barcodeCells
  memset(luma, 0x30, stride * 720)
  for y in 0..<72 {
    for bit in 0..<barcodeCells where (code >> UInt32(barcodeCells - 1 - bit)) & 1 == 1 {
      memset(luma + y * stride + bit * cell, 0xe0, cell)
    }
  }
  memset(
    CVPixelBufferGetBaseAddressOfPlane(buffer, 1), 0x80,
    CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * 360)
}

func drawPattern(into buffer: CVPixelBuffer, frame: UInt32) {
  CVPixelBufferLockBaseAddress(buffer, [])
  defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
  let width = CVPixelBufferGetWidth(buffer)
  let height = CVPixelBufferGetHeight(buffer)
  let stride = CVPixelBufferGetBytesPerRow(buffer)
  let base = CVPixelBufferGetBaseAddress(buffer)!
  let code = (magic << 24) | (frame & 0xff_ffff)
  let band = height / 10
  let barX = Int(frame) * 12 % width
  let cell = width / barcodeCells
  var row = [UInt32](repeating: 0xff20_3040, count: width)
  for bit in 0..<barcodeCells where (code >> UInt32(barcodeCells - 1 - bit)) & 1 == 1 {
    for x in (bit * cell)..<((bit + 1) * cell) { row[x] = 0xffff_ffff }
  }
  for y in 0..<band {
    _ = row.withUnsafeBytes { memcpy(base + y * stride, $0.baseAddress!, width * 4) }
  }
  for x in 0..<width { row[x] = 0xff20_3040 }
  for x in barX..<min(barX + 120, width) { row[x] = 0xff40_d0ff }
  for y in band..<height {
    _ = row.withUnsafeBytes { memcpy(base + y * stride, $0.baseAddress!, width * 4) }
  }
}

// MARK: Reading frames back

func luma(_ buffer: CVPixelBuffer, x: Int, y: Int) -> Int {
  let format = CVPixelBufferGetPixelFormatType(buffer)
  if format == kCVPixelFormatType_32BGRA {
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let p = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    return Int(p[y * stride + x * 4 + 1])  // green is close enough to tell black from white
  }
  let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
  let p = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
  return Int(p[y * stride + x])
}

func decodeBarcode(_ buffer: CVPixelBuffer) -> UInt32? {
  CVPixelBufferLockBaseAddress(buffer, .readOnly)
  defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
  let width = CVPixelBufferGetWidth(buffer)
  let height = CVPixelBufferGetHeight(buffer)
  var code: UInt32 = 0
  for bit in 0..<barcodeCells {
    let x = (bit * 2 + 1) * width / (barcodeCells * 2)
    code = (code << 1) | (luma(buffer, x: x, y: height / 20) > 128 ? 1 : 0)
  }
  return code >> 24 == magic ? code & 0xff_ffff : nil
}

final class ReadStats: @unchecked Sendable {
  private let lock = NSLock()
  private var received = 0
  private var decoded: [UInt32] = []
  private var formats = Set<String>()
  private var latencies: [Double] = []
  private var ptsValues: [Double] = []
  private var first = 0.0
  private var last = 0.0

  func add(_ sample: CMSampleBuffer) {
    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
    let frame = decodeBarcode(buffer)
    let now = hostSeconds()
    let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
    let format =
      "\(fourCCString(CVPixelBufferGetPixelFormatType(buffer))) "
      + "\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer))"
      + (CVPixelBufferGetIOSurface(buffer) == nil ? " no-iosurface" : " iosurface")
    lock.withLock {
      received += 1
      if first == 0 { first = now }
      last = now
      formats.insert(format)
      ptsValues.append(pts)
      if let frame {
        decoded.append(frame)
        latencies.append(now - pts)
      }
    }
  }

  /// Prints a summary and returns the number of barcode frames decoded.
  func report() -> Int {
    lock.withLock {
      let unique = Set(decoded).count
      let ordered = zip(decoded, decoded.dropFirst()).allSatisfy { $0 < $1 }
      let gaps = zip(decoded, decoded.dropFirst()).filter { $1 > $0 + 1 }.count
      let span = last - first
      let sorted = latencies.sorted()
      print("read: received=\(received) decoded=\(decoded.count) unique=\(unique) ordered=\(ordered) gaps=\(gaps)")
      print("read: formats=\(formats.sorted())")
      if let a = decoded.first, let b = decoded.last { print("read: counter \(a)...\(b)") }
      if span > 0 { print(String(format: "read: %.1f fps over %.2fs", Double(received - 1) / span, span)) }
      if !sorted.isEmpty {
        print(String(
          format: "read: pts-to-receipt latency p50=%.1fms max=%.1fms",
          sorted[sorted.count / 2] * 1000, sorted.last! * 1000))
      }
      return decoded.count
    }
  }
}

func readCMIO(_ device: CameraDeviceInfo, seconds: Double) -> Int {
  guard let source = device.sourceStream else {
    print("read: \(device.name) has no source stream")
    return 0
  }
  var unmanaged: Unmanaged<CMSimpleQueue>?
  let altered: CMIODeviceStreamQueueAlteredProc = { _, _, _ in }
  let copied = CMIOStreamCopyBufferQueue(source.id, altered, nil, &unmanaged)
  guard copied == noErr, let queue = unmanaged?.takeRetainedValue() else {
    print("read: CMIOStreamCopyBufferQueue failed \(copied)")
    return 0
  }
  let started = CMIODeviceStartStream(device.id, source.id)
  guard started == noErr else {
    print("read: CMIODeviceStartStream failed \(started)")
    return 0
  }
  let stats = ReadStats()
  let end = Date().addingTimeInterval(seconds)
  while Date() < end {
    while let element = CMSimpleQueueDequeue(queue) {
      stats.add(Unmanaged<CMSampleBuffer>.fromOpaque(element).takeRetainedValue())
    }
    usleep(2000)
  }
  CMIODeviceStopStream(device.id, source.id)
  return stats.report()
}

final class CaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  let stats = ReadStats()
  func captureOutput(
    _ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection
  ) { stats.add(sample) }
}

func readAVFoundation(name: String, seconds: Double) -> Int {
  let status = AVCaptureDevice.authorizationStatus(for: .video)
  print("read: AVCaptureDevice authorization=\(status.rawValue) (3=authorized, 2=denied, 0=undetermined)")
  guard status == .authorized else {
    print("read: not authorized; refusing to raise a prompt. Use CMIO read instead.")
    return 0
  }
  let discovery = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.external], mediaType: .video, position: .unspecified)
  guard let device = discovery.devices.first(where: { $0.localizedName == name }),
    let input = try? AVCaptureDeviceInput(device: device)
  else {
    print("read: AVFoundation cannot open \(name); saw \(discovery.devices.map(\.localizedName))")
    return 0
  }
  let session = AVCaptureSession()
  let output = AVCaptureVideoDataOutput()
  let delegate = CaptureDelegate()
  output.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "capture"))
  session.addInput(input)
  session.addOutput(output)
  session.startRunning()
  Thread.sleep(forTimeInterval: seconds)
  session.stopRunning()
  return delegate.stats.report()
}

// MARK: Commands

func list() {
  let devices = CameraCatalog.devices()
  if devices.isEmpty { print("no CMIO devices") }
  for device in devices {
    print("\(device.name)  id=\(device.id) uid=\(device.uid) model=\(device.model ?? "-") alive=\(device.isAlive)")
    for stream in device.streams {
      print("  stream \(stream.id) [\(stream.direction.rawValue)] \(stream.name)")
      print("    active: \(stream.activeFormat.map(\.description) ?? "-")  fps: \(stream.frameRates)")
      print("    formats: \(stream.formats.map(\.description).joined(separator: ", "))")
    }
  }
}

func printStatus(_ label: String, _ sink: VirtualCameraSink) {
  let s = sink.status
  print(
    "push[\(label)]: device=\(s.deviceName ?? "none") format=\(s.sinkFormat?.description ?? "-")"
      + " passthrough=\(s.isPassthrough) capacity=\(s.queueCapacity) enqueued=\(s.enqueued) busy=\(s.droppedBusy)"
      + " full=\(s.droppedQueueFull) disconnected=\(s.droppedDisconnected) error=\(s.droppedError)"
      + " reconnects=\(s.reconnects) lastError=\(s.lastError ?? "-")")
}

func push(name: String, args: [String]) -> Int32 {
  let seconds = value(of: "--seconds", in: args) ?? 5
  let fps = value(of: "--fps", in: args) ?? 30
  let verify = args.contains("--verify")
  let reconnectAt = value(of: "--reconnect-at", in: args)
  let restartAt = value(of: "--restart-at", in: args)
  let native = args.contains("--native")
  let stalePTS = args.contains("--stale-pts")

  let sink = VirtualCameraSink(preferredNames: [name])
  let startClock = Date()
  do {
    try sink.start()
    print(String(format: "push: attached in %.0fms", Date().timeIntervalSince(startClock) * 1000))
  } catch {
    print("push: start failed softly: \(error)")
  }
  printStatus("start", sink)

  var reader: Process?
  let pipeline = Pipe()
  if verify {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).absoluteURL
    process.arguments = [
      "read", name, "--seconds", String(max(1, seconds - 2)),
    ]
    process.standardOutput = pipeline
    try? process.run()
    reader = process
  }

  let pool = native ? makeNativePool() : makePool(width: 1920, height: 1080)
  var frame: UInt32 = 0
  var longestSend = 0.0
  var didReconnect = false
  var didRestart = false
  let begin = hostSeconds()
  while true {
    let target = begin + Double(frame) / fps
    let now = hostSeconds()
    if now - begin >= seconds { break }
    if target > now { usleep(UInt32((target - now) * 1_000_000)) }

    if let reconnectAt, !didReconnect, hostSeconds() - begin >= reconnectAt {
      didReconnect = true
      sink.reconnect()
      print("push: reconnect requested")
    }
    if let restartAt, !didRestart, hostSeconds() - begin >= restartAt {
      didRestart = true
      sink.stop()
      printStatus("stopped", sink)
      try? sink.start()
      printStatus("restarted", sink)
    }

    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
      let buffer
    else { continue }
    if native {
      drawNativePattern(into: buffer, frame: frame)
    } else {
      drawPattern(into: buffer, frame: frame)
    }
    let sendStart = hostSeconds()
    sink.send(
      buffer,
      pts: stalePTS ? CMTime(value: 42, timescale: 1) : CMClockGetTime(CMClockGetHostTimeClock()))
    longestSend = max(longestSend, hostSeconds() - sendStart)
    frame += 1
    if frame % UInt32(fps) == 0 && frame <= UInt32(fps) * 3 { printStatus("t+\(frame / UInt32(fps))s", sink) }
  }
  print(String(format: "push: drew %d frames; longest send() %.2fms", frame, longestSend * 1000))

  var result: Int32 = 0
  if let reader {
    reader.waitUntilExit()
    let text = String(decoding: pipeline.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    print(text, terminator: "")
    result = reader.terminationStatus
  }
  printStatus("end", sink)
  sink.stop()
  return result
}

func read(name: String, args: [String]) -> Int32 {
  let seconds = value(of: "--seconds", in: args) ?? 3
  if args.contains("--avf") { return readAVFoundation(name: name, seconds: seconds) > 0 ? 0 : 1 }
  guard let device = CameraCatalog.device(named: name) else {
    print("read: no such device \(name)")
    return 1
  }
  return readCMIO(device, seconds: seconds) > 0 ? 0 : 1
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "running" where args.count >= 2:
  print(VirtualCameraSink.runningSomewhere(named: args[1]).map(String.init(describing:)) ?? "missing")
case "list":
  list()
case "push" where args.count >= 2:
  exit(push(name: args[1], args: args))
case "read" where args.count >= 2:
  exit(read(name: args[1], args: args))
default:
  print("usage: camera-probe list | push <device> [--seconds N --fps N --verify --reconnect-at S --restart-at S --native --stale-pts] | read <device> [--seconds N --avf]")
  exit(2)
}
