import Foundation

public struct Place: Codable, Equatable { public var name: String; public var latitude, longitude: Double
  public init(name: String, latitude: Double, longitude: Double) { self.name = name; self.latitude = latitude; self.longitude = longitude } }
public struct Conditions { public var weather: Weather; public var sunrise, sunset: Date? }

/// Open-Meteo is the only network service, and it only ever receives the place you typed.
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
  private struct Forecast: Decodable {
    struct Current: Decodable { let weather_code: Int }
    struct Daily: Decodable { let sunrise: [String]; let sunset: [String] }
    let current: Current; let daily: Daily; let utc_offset_seconds: Int
  }
  private struct Geo: Decodable { struct R: Decodable { let name: String; let latitude, longitude: Double; let admin1: String?; let country: String? }; let results: [R]? }

  public static func conditions(_ p: Place) async throws -> Conditions {
    var u = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
    u.queryItems = [.init(name: "latitude", value: String(format: "%.2f", p.latitude)), .init(name: "longitude", value: String(format: "%.2f", p.longitude)),
      .init(name: "current", value: "weather_code"), .init(name: "daily", value: "sunrise,sunset"), .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "1")]
    let (d, _) = try await URLSession.shared.data(from: u.url!)
    let f = try JSONDecoder().decode(Forecast.self, from: d)
    let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd'T'HH:mm"; df.timeZone = TimeZone(secondsFromGMT: f.utc_offset_seconds)
    return Conditions(weather: weather(wmo: f.current.weather_code), sunrise: f.daily.sunrise.first.flatMap(df.date), sunset: f.daily.sunset.first.flatMap(df.date))
  }
  public static func search(_ q: String) async throws -> Place? {
    var u = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
    u.queryItems = [.init(name: "name", value: q), .init(name: "count", value: "1")]
    let (d, _) = try await URLSession.shared.data(from: u.url!)
    guard let r = try JSONDecoder().decode(Geo.self, from: d).results?.first else { return nil }
    return Place(name: [r.name, r.admin1].compactMap { $0 }.joined(separator: ", "), latitude: r.latitude, longitude: r.longitude)
  }
}
