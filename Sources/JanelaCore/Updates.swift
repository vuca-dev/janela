import Foundation

/// Tells people a newer release exists. It never downloads or installs anything.
public enum Updates {
  public static let page = URL(string: "https://github.com/vuca-dev/janela/releases/latest")!

  /// Numeric version parts, so 0.1.10 is newer than 0.1.9. Anything else counts as not newer.
  public static func isNewer(_ tag: String, than current: String) -> Bool {
    func parts(_ s: String) -> [Int]? {
      let p = (s.hasPrefix("v") ? String(s.dropFirst()) : s).split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
      return p.isEmpty || p.contains(nil) ? nil : p.compactMap { $0 }
    }
    guard let a = parts(tag), let b = parts(current) else { return false }
    for i in 0..<max(a.count, b.count) {
      let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
      if x != y { return x > y }
    }
    return false
  }

  public static func parseTag(_ data: Data) -> String? {
    struct R: Decodable { let tag_name: String }
    return (try? JSONDecoder().decode(R.self, from: data))?.tag_name
  }

  /// The newer version's number, or nil if there's none or GitHub can't be reached.
  public static func available(current: String) async -> String? {
    var q = URLRequest(url: URL(string: "https://api.github.com/repos/vuca-dev/janela/releases/latest")!)
    q.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    q.timeoutInterval = 10
    guard let (data, _) = try? await URLSession.shared.data(for: q), let tag = parseTag(data), isNewer(tag, than: current) else { return nil }
    return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
  }
}
