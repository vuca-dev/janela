import Foundation

/// What the setup window shows for a place, using the same weather and phase that pick the scene.
public struct PlaceNow: Equatable {
  public let symbol: String       // an SF Symbol
  public let conditions: String   // "Cloudy, 46°F", in the viewer's preferred units
  public let clock: String        // "8:42 AM MST"

  /// Nil when the forecast has run out or has no time zone.
  public init?(forecast f: Forecast, at date: Date, locale: Locale = .current) {
    guard let hour = f.hour(at: date), let name = f.timeZone, let zone = TimeZone(identifier: name) else { return nil }
    let weather = WeatherService.weather(wmo: hour.code)
    let sun = Sun.day(on: date, latitude: f.place.latitude, longitude: f.place.longitude)
    let night = DayClock.phase(at: date, sun: sun) == .night
    switch weather {
    case .clear: symbol = night ? "moon.stars" : "sun.max"
    case .cloudy: symbol = night ? "cloud.moon" : "cloud"
    case .rain: symbol = "cloud.rain"
    case .snow: symbol = "cloud.snow"
    case .fog: symbol = "cloud.fog"
    }
    var text = weather.rawValue.capitalized
    if let c = hour.celsius {
      let style = Measurement<UnitTemperature>.FormatStyle(width: .abbreviated, locale: locale, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0)))
      text += ", " + Measurement(value: c, unit: UnitTemperature.celsius).formatted(style)
    }
    conditions = text
    let time = DateFormatter()
    time.locale = locale; time.timeZone = zone; time.dateStyle = .none; time.timeStyle = .short
    let abbreviation = DateFormatter()
    abbreviation.locale = locale; abbreviation.timeZone = zone; abbreviation.dateFormat = "zzz"
    clock = time.string(from: date) + " " + abbreviation.string(from: date)
  }
}
