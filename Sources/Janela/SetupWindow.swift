import AppKit
import JanelaCore
import SwiftUI

@MainActor final class SetupModel: ObservableObject {
  @Published var query = "" { didSet { if query != oldValue { lookUp() } } }
  @Published var suggestions: [LocationSuggestion] = []
  @Published var place: Place?
  @Published var scene: String
  @Published var problem: String?
  @Published var cameraName: String?
  let scenes: [(name: String, image: CGImage?)]
  let firstRun: Bool
  var onScene: (String) -> Void = { _ in }
  var onDone: (Place?) -> Void = { _ in }
  private var task: Task<Void, Never>?
  private let search = LocationSearch()

  init(place: Place?, scene: String, scenes: [(name: String, image: CGImage?)], firstRun: Bool, cameraName: String?) {
    self.place = place; self.scene = scene; self.scenes = scenes; self.firstRun = firstRun; self.cameraName = cameraName
    if let place { query = place.name }
  }

  func choose(_ s: LocationSuggestion) async {
    task?.cancel(); suggestions = []
    do {
      let p = try await search.resolve(s)
      place = p; query = p.name; task?.cancel(); problem = nil
    } catch { problem = "Couldn't find that place. Try another." }
  }

  private func lookUp() {
    task?.cancel(); problem = nil
    if query == place?.name { return }
    place = nil
    let q = query
    guard q.trimmingCharacters(in: .whitespaces).count >= 2 else { suggestions = []; return }
    task = Task {
      try? await Task.sleep(for: .milliseconds(220))
      if Task.isCancelled { return }
      do {
        let r = try await search.search(q)
        if Task.isCancelled { return }
        suggestions = r
        problem = r.isEmpty ? "No matches. Try a nearby city or add the country." : nil
      } catch { if !Task.isCancelled { suggestions = []; problem = "Can't search right now. Check your connection." } }
    }
  }
}

struct SetupView: View {
  @ObservedObject var model: SetupModel
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      VStack(alignment: .leading, spacing: 4) {
        Text(model.firstRun ? "Welcome to Janela" : "Janela Settings").font(.title2.weight(.semibold))
        if model.firstRun { Text("Your window follows your local time and weather.").foregroundStyle(.secondary) }
      }
      VStack(alignment: .leading, spacing: 8) {
        Text("Location").font(.headline)
        HStack {
          TextField("City or postal code", text: $model.query).textFieldStyle(.roundedBorder)
            .onSubmit { if let f = model.suggestions.first { Task { await model.choose(f) } } }
          if model.place != nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        }
        if !model.suggestions.isEmpty {
          VStack(spacing: 0) {
            ForEach(model.suggestions) { p in
              Button { Task { await model.choose(p) } } label: { Text(p.label).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5).padding(.horizontal, 8).contentShape(Rectangle()) }
                .buttonStyle(.plain)
            }
          }.background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
           .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
        }
        Text(model.problem ?? "Search uses Apple Maps. Weather comes from Open-Meteo.")
          .font(.caption).foregroundStyle(model.problem == nil ? Color.secondary : Color.orange)
      }
      VStack(alignment: .leading, spacing: 8) {
        Text("Background").font(.headline)
        HStack(spacing: 12) {
          ForEach(model.scenes, id: \.name) { s in
            Button { model.scene = s.name; model.onScene(s.name) } label: {
              VStack(spacing: 6) {
                Group {
                  if let i = s.image { Image(decorative: i, scale: 1).resizable().aspectRatio(16 / 9, contentMode: .fill) } else { Color.gray }
                }.frame(width: 200, height: 112).clipShape(RoundedRectangle(cornerRadius: 8))
                 .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.scene == s.name ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: model.scene == s.name ? 3 : 1))
                Text(s.name.capitalized).font(.callout).fontWeight(model.scene == s.name ? .semibold : .regular)
              }
            }.buttonStyle(.plain)
          }
        }
      }
      HStack(spacing: 6) {
        Image(systemName: model.cameraName == nil ? "exclamationmark.triangle.fill" : "video.fill").foregroundStyle(model.cameraName == nil ? Color.orange : Color.secondary)
        Text(model.cameraName.map { "In your meeting app, choose \($0)." } ?? "Virtual camera not found. See the README to set up OBS.").font(.callout)
      }
      HStack {
        if model.firstRun && model.place == nil {
          Text("Without a location, time of day uses your time zone and weather stays clear.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
        Button(model.firstRun && model.place == nil ? "Skip for Now" : "Done") { model.onDone(model.place) }
          .keyboardShortcut(model.suggestions.isEmpty ? .defaultAction : .cancelAction)
      }
    }.padding(24).frame(width: 460, alignment: .leading)
  }
}

@MainActor final class SetupWindow {
  let window: NSWindow
  private let host: NSHostingController<SetupView>
  init(model: SetupModel) {
    host = NSHostingController(rootView: SetupView(model: model))
    host.sizingOptions = [.preferredContentSize]   // grows as suggestions appear
    window = NSWindow(contentViewController: host)
    window.styleMask = [.titled, .closable]; window.title = "Janela"; window.isReleasedWhenClosed = false
  }
  func show() { window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
  func snapshot(to path: String) {
    let view: NSView = window.contentView!
    guard let r = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: r)
    try? r.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
  }
}
