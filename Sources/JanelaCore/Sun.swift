import Foundation

public enum SunDay { case normal(rise: Date, set: Date), alwaysUp(noon: Date), alwaysDown }

/// NOAA solar equations. Works offline; accurate to about a minute at normal latitudes.
public enum Sun {
  /// Sunrise and sunset around `date`, or nil during polar day or night.
  public static func times(on date: Date, latitude: Double, longitude: Double) -> (rise: Date, set: Date)? {
    if case let .normal(r, s) = day(on: date, latitude: latitude, longitude: longitude) { return (r, s) }
    return nil
  }

  /// The solar day whose noon is nearest `date`. Works in absolute time, so a place
  /// in any time zone can be compared with the current moment.
  public static func day(on date: Date, latitude: Double, longitude: Double) -> SunDay {
    let noonUTC = (date.timeIntervalSince1970 / 86400).rounded(.down) * 86400 + 43200
    // Centre the UTC day on local solar noon, so both events belong to the same local day.
    var mid = noonUTC - longitude / 360 * 86400
    if mid - date.timeIntervalSince1970 > 43200 { mid -= 86400 }
    if date.timeIntervalSince1970 - mid > 43200 { mid += 86400 }
    let t = (mid / 86400 + 2440587.5 - 2451545) / 36525
    let d2r = Double.pi / 180
    let l = (280.46646 + t * (36000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
    let m = 357.52911 + t * (35999.05029 - 0.0001537 * t)
    let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
    let c = sin(m * d2r) * (1.914602 - t * (0.004817 + 0.000014 * t)) + sin(2 * m * d2r) * (0.019993 - 0.000101 * t) + sin(3 * m * d2r) * 0.000289
    let omega = 125.04 - 1934.136 * t
    let lambda = l + c - 0.00569 - 0.00478 * sin(omega * d2r)
    let obl = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60 + 0.00256 * cos(omega * d2r)
    let decl = asin(sin(obl * d2r) * sin(lambda * d2r))
    let y = pow(tan(obl / 2 * d2r), 2)
    let eq = 4 / d2r * (y * sin(2 * l * d2r) - 2 * e * sin(m * d2r) + 4 * e * y * sin(m * d2r) * cos(2 * l * d2r)
      - 0.5 * y * y * sin(4 * l * d2r) - 1.25 * e * e * sin(2 * m * d2r))
    let phi = latitude * d2r
    let ch = (cos(90.833 * d2r) - sin(phi) * sin(decl)) / (cos(phi) * cos(decl))
    let solarNoon = mid + (-longitude * 4 - eq) * 60 + longitude / 360 * 86400
    if ch < -1 { return .alwaysUp(noon: Date(timeIntervalSince1970: solarNoon)) }
    if ch > 1 { return .alwaysDown }
    let ha = acos(ch) / d2r
    return .normal(rise: Date(timeIntervalSince1970: solarNoon - ha * 240), set: Date(timeIntervalSince1970: solarNoon + ha * 240))
  }
}

/// A rough location from the Mac's time zone, for people who skip the location step.
/// Reads the system's zone table, so nothing leaves the machine.
public enum ZoneLocation {
  public static func parse(_ s: String) -> (Double, Double)? {
    let c = Array(s)
    guard let split = c.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
    func part(_ a: ArraySlice<Character>, _ deg: Int) -> Double? {
      let sign: Double = a.first == "-" ? -1 : 1, n = a.dropFirst().map(String.init).joined()
      guard n.count >= deg + 2, let d = Double(n.prefix(deg)), let m = Double(n.dropFirst(deg).prefix(2)) else { return nil }
      let sec = Double(n.dropFirst(deg + 2)) ?? 0
      return sign * (d + m / 60 + sec / 3600)
    }
    guard let lat = part(c[0..<split], 2), let lon = part(c[split...], 3) else { return nil }
    return (lat, lon)
  }
  public static func coordinates(zone: String = TimeZone.current.identifier, table: String = "/usr/share/zoneinfo/zone.tab") -> (Double, Double)? {
    guard let t = try? String(contentsOfFile: table, encoding: .utf8) else { return nil }
    for line in t.split(separator: "\n") where !line.hasPrefix("#") {
      let f = line.split(separator: "\t")
      if f.count >= 3, f[2] == zone { return parse(String(f[1])) }
    }
    return nil
  }
  /// Some Macs report older zone names, such as Asia/Calcutta, that the table has renamed.
  /// Longitude from the UTC offset still gives the right time of day.
  public static func estimate(_ tz: TimeZone = .current) -> (Double, Double) {
    coordinates(zone: tz.identifier) ?? (0, Double(tz.secondsFromGMT()) / 240)
  }
}
