import AppKit
import CryptoKit
import Foundation
import Security

/// Gets OBS's signed camera extension running without the user touching OBS.
public enum OBSSetup {
  public enum ExtensionState: Equatable { case active, waitingForUser, disabled, absent }
  public enum Failure: Error, CustomStringConvertible {
    case noDownload, badChecksum, badSignature, notWritable, command(String)
    public var description: String {
      switch self {
      case .noDownload: return "Couldn't find the OBS download."
      case .badChecksum: return "The download didn't match its checksum, so it wasn't installed."
      case .badSignature: return "OBS's signature didn't verify, so it wasn't installed."
      case .notWritable: return "Your account can't install to Applications."
      case let .command(s): return "Installing OBS failed: \(s)"
      }
    }
  }

  public static let bundleID = "com.obsproject.obs-studio"
  static let team = "2MMRE5MTB8"
  static let extensionID = "com.obsproject.obs-studio.mac-camera-extension"
  public static let extensionSettings = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
  public static let cameraPrivacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!

  /// Only the standard location, never a lookup by bundle ID, which any app could claim.
  public static func installedURL() -> URL? {
    let u = URL(fileURLWithPath: "/Applications/OBS.app")
    return FileManager.default.fileExists(atPath: u.path) ? u : nil
  }

  // MARK: Extension state

  public static func parseState(_ listing: String) -> ExtensionState {
    guard let line = listing.split(separator: "\n").first(where: { $0.contains(extensionID) }) else { return .absent }
    if line.contains("[activated enabled]") { return .active }
    if line.contains("waiting for user") { return .waitingForUser }
    return line.contains("[activated") ? .disabled : .absent
  }

  public static func extensionState() -> ExtensionState {
    parseState((try? run("/usr/bin/systemextensionsctl", ["list"])) ?? "")
  }

  // MARK: Hidden launch

  /// Skips OBS's first-run wizard. Only ever written when OBS has no settings of its own.
  public static func prepareProfile(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
    let dir = home.appendingPathComponent("Library/Application Support/obs-studio")
    if FileManager.default.fileExists(atPath: dir.appendingPathComponent("user.ini").path) ||
       FileManager.default.fileExists(atPath: dir.appendingPathComponent("global.ini").path) { return }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "[General]\nFirstRun=true\n".write(to: dir.appendingPathComponent("user.ini"), atomically: true, encoding: .utf8)
  }

  /// OBS's plugin asks macOS to activate the extension as it loads.
  @MainActor public static func launchHidden() async throws -> NSRunningApplication? {
    guard let url = installedURL() else { throw Failure.noDownload }
    guard verifySignature(at: url) else { throw Failure.badSignature }
    if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil { return nil } // the user's own session
    try prepareProfile()
    let c = NSWorkspace.OpenConfiguration()
    c.activates = false; c.hides = true; c.addsToRecentItems = false
    c.arguments = ["--minimize-to-tray", "--disable-updater"]
    return try await NSWorkspace.shared.openApplication(at: url, configuration: c)
  }

  // MARK: Download and install

  public struct Release { public let url: URL; public let size: Int64; public let sha256: String }

  public static func parseRelease(_ data: Data) throws -> Release {
    struct R: Decodable { struct A: Decodable { let name: String; let browser_download_url: URL; let size: Int64; let digest: String? }; let assets: [A] }
    let r = try JSONDecoder().decode(R.self, from: data)
    guard let a = r.assets.first(where: { $0.name.hasSuffix("-macOS-Apple.dmg") }), let d = a.digest, d.hasPrefix("sha256:") else { throw Failure.noDownload }
    return Release(url: a.browser_download_url, size: a.size, sha256: String(d.dropFirst(7)))
  }

  public static func latestRelease() async throws -> Release {
    var q = URLRequest(url: URL(string: "https://api.github.com/repos/obsproject/obs-studio/releases/latest")!)
    q.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    return try parseRelease(try await URLSession.shared.data(for: q).0)
  }

  /// Downloads, then verifies the checksum and OBS's Apple signature before anything lands in Applications.
  public static func install(to folder: URL = URL(fileURLWithPath: "/Applications"), progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    let dest = folder.appendingPathComponent("OBS.app")
    if FileManager.default.fileExists(atPath: dest.path) { return dest }
    guard FileManager.default.isWritableFile(atPath: folder.path) else { throw Failure.notWritable }
    let release = try await latestRelease()
    let dmg = try await Downloader.fetch(release.url, expected: release.size, progress: progress)
    defer { try? FileManager.default.removeItem(at: dmg) }
    guard try sha256(of: dmg) == release.sha256 else { throw Failure.badChecksum }
    let mount = FileManager.default.temporaryDirectory.appendingPathComponent("janela-obs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    _ = try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-quiet", "-mountpoint", mount.path])
    defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"]); try? FileManager.default.removeItem(at: mount) }
    let partial = folder.appendingPathComponent(".OBS-\(UUID().uuidString).app")
    defer { try? FileManager.default.removeItem(at: partial) }
    _ = try run("/usr/bin/ditto", [mount.appendingPathComponent("OBS.app").path, partial.path])
    guard verifySignature(at: partial) else { throw Failure.badSignature }
    try FileManager.default.moveItem(at: partial, to: dest)
    return dest
  }

  public static func verifySignature(at app: URL) -> Bool {
    var code: SecStaticCode?, req: SecRequirement?
    let r = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(team)\""
    guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
          SecRequirementCreateWithString(r as CFString, [], &req) == errSecSuccess else { return false }
    return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate).union(.enforceRevocationChecks), req) == errSecSuccess
  }

  static func sha256(of url: URL) throws -> String {
    let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
    var s = SHA256()
    while let d = try h.read(upToCount: 1 << 20), !d.isEmpty { s.update(data: d) }
    return s.finalize().map { String(format: "%02x", $0) }.joined()
  }

  @discardableResult static func run(_ tool: String, _ args: [String]) throws -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = out
    try p.run()
    let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    let s = String(decoding: d, as: UTF8.self)
    if p.terminationStatus != 0 { throw Failure.command(String(s.prefix(160))) }
    return s
  }
}

private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private var done: CheckedContinuation<URL, Error>?
  private let progress: @Sendable (Double) -> Void; private let expected: Int64
  init(expected: Int64, progress: @escaping @Sendable (Double) -> Void) { self.expected = expected; self.progress = progress }

  static func fetch(_ url: URL, expected: Int64, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    let d = Downloader(expected: expected, progress: progress)
    let s = URLSession(configuration: .ephemeral, delegate: d, delegateQueue: nil)
    defer { s.finishTasksAndInvalidate() }
    return try await withCheckedThrowingContinuation { k in d.done = k; s.downloadTask(with: url).resume() }
  }
  func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didWriteData b: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite e: Int64) {
    progress(Double(w) / Double(max(e > 0 ? e : expected, 1)))
  }
  func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo u: URL) {
    let keep = FileManager.default.temporaryDirectory.appendingPathComponent("janela-obs-\(UUID().uuidString).dmg")
    do { try FileManager.default.moveItem(at: u, to: keep); done?.resume(returning: keep) } catch { done?.resume(throwing: error) }
    done = nil
  }
  func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError e: Error?) {
    if let e { done?.resume(throwing: e); done = nil }
  }
}
