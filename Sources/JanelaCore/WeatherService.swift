import Foundation

public struct Place: Codable, Equatable, Identifiable {
  public var name: String; public var latitude, longitude: Double
  public var id: String { "\(name)|\(latitude)|\(longitude)" }
  public init(name: String, latitude: Double, longitude: Double) { self.name = name; self.latitude = latitude; self.longitude = longitude }
}

/// Hourly conditions, cached on disk so scenes keep changing between fetches and offline.
public struct Forecast: Codable, Equatable {
  public struct Hour: Codable, Equatable { public var time: Date; public var code: Int; public var celsius: Double?
    public init(time: Date, code: Int, celsius: Double? = nil) { self.time = time; self.code = code; self.celsius = celsius } }
  public var place: Place; public var fetchedAt: Date; public var hours: [Hour]
  public var timeZone: String?   // the place's IANA name. Absent from forecasts saved by older versions.
  public init(place: Place, fetchedAt: Date, hours: [Hour], timeZone: String? = nil) {
    self.place = place; self.fetchedAt = fetchedAt; self.hours = hours; self.timeZone = timeZone }

  /// The hour covering `date`, or nil once the forecast has run out.
  public func hour(at date: Date) -> Hour? {
    guard let h = hours.last(where: { $0.time <= date }), date.timeIntervalSince(h.time) < 3600 else { return nil }
    return h
  }
  public func weather(at date: Date) -> Weather? { hour(at: date).map { WeatherService.weather(wmo: $0.code) } }
  public func isFresh(at date: Date, for p: Place, maxAge: TimeInterval = 3 * 3600) -> Bool {
    place == p && date.timeIntervalSince(fetchedAt) < maxAge
  }
}

/// Weather comes from Open-Meteo, which receives coordinates rounded to about a kilometre.
public enum WeatherService {
  public static func weather(wmo c: Int) -> Weather {
    switch c {
    case 0, 1: return .clear
    case 2, 3: return .cloudy
    case 45, 48: return .fog
    case 71...77, 85, 86: return .snow
    default: return .rain
    }
  }
  private struct Reply: Decodable {
    struct Hourly: Decodable { let time: [Double]; let weather_code: [Int?]; let temperature_2m: [Double?]? }
    let hourly: Hourly; let timezone: String?
  }

  /// Keeps the past hour plus the next 24.
  public static func forecast(_ p: Place, now: Date = Date()) async throws -> Forecast {
    var u = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
    u.queryItems = [.init(name: "latitude", value: String(format: "%.2f", p.latitude)), .init(name: "longitude", value: String(format: "%.2f", p.longitude)),
      .init(name: "hourly", value: "weather_code,temperature_2m"), .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "3"), .init(name: "timeformat", value: "unixtime")]
    let (d, _) = try await URLSession.shared.data(from: u.url!)
    let r = try JSONDecoder().decode(Reply.self, from: d), h = r.hourly
    let hours = h.time.indices.compactMap { i -> Forecast.Hour? in
      guard i < h.weather_code.count, let c = h.weather_code[i] else { return nil }
      let celsius = h.temperature_2m.flatMap { i < $0.count ? $0[i] : nil }
      return Forecast.Hour(time: Date(timeIntervalSince1970: h.time[i]), code: c, celsius: celsius)
    }.filter { $0.time > now.addingTimeInterval(-3600) && $0.time <= now.addingTimeInterval(24 * 3600) }
    return Forecast(place: p, fetchedAt: now, hours: hours, timeZone: r.timezone)
  }
}
