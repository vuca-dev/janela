import CoreMedia
import CoreMediaIO
import Foundation

/// Thin read-only wrappers over the CMIO C property API.
enum CMIOProperty {
  static func address(
    _ selector: Int, scope: Int = kCMIOObjectPropertyScopeGlobal
  ) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(selector),
      mScope: CMIOObjectPropertyScope(scope),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
  }

  static func array<T>(_ object: CMIOObjectID, _ selector: Int, of type: T.Type) -> [T] {
    var addr = address(selector)
    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else {
      return []
    }
    let count = Int(size) / MemoryLayout<T>.stride
    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
    defer { raw.deallocate() }
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, raw) == noErr else {
      return []
    }
    return (0..<min(count, Int(used) / MemoryLayout<T>.stride)).map {
      raw.load(fromByteOffset: $0 * MemoryLayout<T>.stride, as: T.self)
    }
  }

  static func uint32(_ object: CMIOObjectID, _ selector: Int) -> UInt32? {
    var addr = address(selector)
    guard CMIOObjectHasProperty(object, &addr) else { return nil }
    return array(object, selector, of: UInt32.self).first
  }

  static func string(_ object: CMIOObjectID, _ selector: Int) -> String? {
    var addr = address(selector)
    var value: Unmanaged<CFString>?
    var used: UInt32 = 0
    let status = withUnsafeMutablePointer(to: &value) {
      CMIOObjectGetPropertyData(
        object, &addr, 0, nil, UInt32(MemoryLayout<CFString?>.size), &used, $0)
    }
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
  }

  static func formats(_ stream: CMIOObjectID) -> [CMFormatDescription] {
    var addr = address(kCMIOStreamPropertyFormatDescriptions)
    var value: Unmanaged<CFArray>?
    var used: UInt32 = 0
    let status = withUnsafeMutablePointer(to: &value) {
      CMIOObjectGetPropertyData(
        stream, &addr, 0, nil, UInt32(MemoryLayout<CFArray?>.size), &used, $0)
    }
    guard status == noErr, let array = value?.takeRetainedValue() else { return [] }
    return (array as [AnyObject]).map { $0 as! CMFormatDescription }
  }

  static func activeFormat(_ stream: CMIOObjectID) -> CMFormatDescription? {
    var addr = address(kCMIOStreamPropertyFormatDescription)
    var value: Unmanaged<CMFormatDescription>?
    var used: UInt32 = 0
    let status = withUnsafeMutablePointer(to: &value) {
      CMIOObjectGetPropertyData(
        stream, &addr, 0, nil, UInt32(MemoryLayout<CMFormatDescription?>.size), &used, $0)
    }
    guard status == noErr else { return nil }
    return value?.takeRetainedValue()
  }

  static func setActiveFormat(_ stream: CMIOObjectID, _ format: CMFormatDescription) -> OSStatus {
    var addr = address(kCMIOStreamPropertyFormatDescription)
    var value: CMFormatDescription? = format
    return withUnsafeBytes(of: &value) {
      CMIOObjectSetPropertyData(stream, &addr, 0, nil, UInt32($0.count), $0.baseAddress)
    }
  }
}

/// One stream on a CMIO device.
public struct CameraStreamInfo: Sendable {
  public enum Direction: String, Sendable {
    case source  // the extension produces frames; apps read these
    case sink  // the extension consumes frames; we write these
    case unknown
  }

  public struct Format: Sendable, CustomStringConvertible {
    public let pixelFormat: FourCharCode
    public let width: Int
    public let height: Int
    public var fourCC: String { fourCCString(pixelFormat) }
    public var description: String { "\(fourCC) \(width)x\(height)" }
  }

  public let id: CMIOStreamID
  public let name: String
  public let direction: Direction
  public let formats: [Format]
  public let activeFormat: Format?
  public let frameRates: [Double]
}

public struct CameraDeviceInfo: Sendable {
  public let id: CMIODeviceID
  public let name: String
  public let uid: String
  public let model: String?
  public let isAlive: Bool
  public let streams: [CameraStreamInfo]

  public var sinkStream: CameraStreamInfo? { streams.first { $0.direction == .sink } }
  public var sourceStream: CameraStreamInfo? { streams.first { $0.direction == .source } }
}

/// Discovery of CMIO devices. Safe to call whether or not any extension exists.
public enum CameraCatalog {
  public static func devices() -> [CameraDeviceInfo] {
    CMIOProperty.array(
      CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices, of: CMIODeviceID.self
    ).compactMap(device)
  }

  public static func device(named name: String) -> CameraDeviceInfo? {
    devices().first { $0.name == name }
  }

  static func device(_ id: CMIODeviceID) -> CameraDeviceInfo? {
    guard let name = CMIOProperty.string(id, kCMIOObjectPropertyName) else { return nil }
    return CameraDeviceInfo(
      id: id,
      name: name,
      uid: CMIOProperty.string(id, kCMIODevicePropertyDeviceUID) ?? "",
      model: CMIOProperty.string(id, kCMIODevicePropertyModelUID),
      isAlive: (CMIOProperty.uint32(id, kCMIODevicePropertyDeviceIsAlive) ?? 1) != 0,
      streams: CMIOProperty.array(id, kCMIODevicePropertyStreams, of: CMIOStreamID.self)
        .map(stream))
  }

  static func stream(_ id: CMIOStreamID) -> CameraStreamInfo {
    // kCMIOStreamPropertyDirection: 0 = output from the host (sink), 1 = input to the host (source).
    let direction: CameraStreamInfo.Direction
    switch CMIOProperty.uint32(id, kCMIOStreamPropertyDirection) {
    case 0: direction = .sink
    case 1: direction = .source
    default: direction = .unknown
    }
    return CameraStreamInfo(
      id: id,
      name: CMIOProperty.string(id, kCMIOObjectPropertyName) ?? "",
      direction: direction,
      formats: CMIOProperty.formats(id).map(format),
      activeFormat: CMIOProperty.activeFormat(id).map(format),
      frameRates: CMIOProperty.array(id, kCMIOStreamPropertyFrameRates, of: Double.self))
  }

  static func format(_ description: CMFormatDescription) -> CameraStreamInfo.Format {
    let dimensions = CMVideoFormatDescriptionGetDimensions(description)
    return CameraStreamInfo.Format(
      pixelFormat: CMFormatDescriptionGetMediaSubType(description),
      width: Int(dimensions.width), height: Int(dimensions.height))
  }
}

public func fourCCString(_ code: FourCharCode) -> String {
  let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
  if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) { return String(decoding: bytes, as: UTF8.self) }
  return String(format: "0x%08x", code)
}
