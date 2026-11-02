import Foundation
import MapKit

public struct LocationSuggestion: Identifiable {
  public let id = UUID()
  public let label: String
  let completion: MKLocalSearchCompletion
}

/// Apple Maps autocomplete: every script and postal format, with nothing to bundle.
/// Only what's typed here goes to Apple; weather stays with Open-Meteo.
@MainActor public final class LocationSearch: NSObject, MKLocalSearchCompleterDelegate {
  private let completer = MKLocalSearchCompleter()
  private var waiting: CheckedContinuation<[LocationSuggestion], Error>?
  private var generation = 0

  public override init() {
    super.init()
    completer.resultTypes = .address
    completer.delegate = self
  }

  public func search(_ q: String) async throws -> [LocationSuggestion] {
    let t = q.trimmingCharacters(in: .whitespaces)
    guard t.count >= 2 else { return [] }
    finish(.success([]))   // a newer query replaces any still in flight
    return try await withCheckedThrowingContinuation { (k: CheckedContinuation<[LocationSuggestion], Error>) in
      waiting = k
      generation += 1
      let mine = generation
      completer.cancel()
      completer.queryFragment = t
      DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
        MainActor.assumeIsolated { if self?.generation == mine { self?.finish(.failure(URLError(.timedOut))) } } }
    }
  }

  private func finish(_ r: Result<[LocationSuggestion], Error>) {
    guard let k = waiting else { return }
    waiting = nil; k.resume(with: r)
  }

  public nonisolated func completerDidUpdateResults(_ c: MKLocalSearchCompleter) {
    MainActor.assumeIsolated {
      finish(.success(c.results.prefix(5).map { r in
        let tail = r.subtitle.trimmingCharacters(in: .whitespaces)
        return LocationSuggestion(label: tail.isEmpty ? r.title : "\(r.title), \(tail)", completion: r)
      }))
    }
  }

  public nonisolated func completer(_ c: MKLocalSearchCompleter, didFailWithError e: Error) {
    MainActor.assumeIsolated {
      // Apple reports an empty result as an error.
      if (e as? MKError)?.code == .placemarkNotFound { finish(.success([])) } else { finish(.failure(e)) }
    }
  }

  /// Coordinates are stored to two decimals, about a kilometre.
  public func resolve(_ s: LocationSuggestion) async throws -> Place {
    let r = try await MKLocalSearch(request: MKLocalSearch.Request(completion: s.completion)).start()
    guard let c = r.mapItems.first?.placemark.coordinate else { throw URLError(.cannotFindHost) }
    return Place(name: s.label, latitude: (c.latitude * 100).rounded() / 100, longitude: (c.longitude * 100).rounded() / 100)
  }
}
