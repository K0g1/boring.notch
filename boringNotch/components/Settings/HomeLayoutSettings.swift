import Defaults
import SwiftUI

struct HomeLayoutSettings: View {
    @Default(.enableHomeLayout) private var enabled
    @Default(.homeLayouts) private var layouts
    @Default(.showOnAllDisplays) private var allDisplays
    @State private var selectedDisplay = HomeLayout.sharedKey

    private var key: String { allDisplays ? selectedDisplay : HomeLayout.sharedKey }
    private var panels: [HomePanel] {
        HomeLayout.panels(from: layouts[key] ?? layouts[HomeLayout.sharedKey])
    }

    var body: some View {
        Form {
            Section {
                Toggle("Customize home layout", isOn: $enabled)
                Text("Choose two or three panels for the expanded notch. Favorite Shortcuts remain below your panels.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                if allDisplays {
                    Picker("Layout for", selection: $selectedDisplay) {
                        Text("Default layout").tag(HomeLayout.sharedKey)
                        ForEach(NSScreen.screens.compactMap { screen -> DisplayChoice? in
                            guard let uuid = screen.displayUUID else { return nil }
                            return DisplayChoice(id: uuid, name: screen.localizedName)
                        }) { display in
                            Text(display.name).tag(display.id)
                        }
                    }
                }
                Picker("Preset", selection: Binding(
                    get: { presetName },
                    set: { name in
                        switch name {
                        case "Listen": save([.media, .utilities])
                        case "Plan": save([.agenda, .utilities])
                        case "Work": save([.agenda, .shelf, .utilities])
                        default: break
                        }
                    }
                )) {
                    Text("Listen").tag("Listen")
                    Text("Plan").tag("Plan")
                    Text("Work").tag("Work")
                    Text("Custom").tag("Custom")
                }
                ForEach(Array(panels.enumerated()), id: \.element.id) { index, panel in
                    HStack(spacing: 8) {
                        Text("\(index + 1)").foregroundStyle(.secondary).monospacedDigit()
                        Picker("Panel \(index + 1)", selection: Binding(
                            get: { panel },
                            set: { replacement in
                                var updated = panels
                                if let other = updated.firstIndex(of: replacement) {
                                    updated.swapAt(index, other)
                                } else {
                                    updated[index] = replacement
                                }
                                save(updated)
                            }
                        )) {
                            ForEach(HomePanel.allCases) { choice in
                                Label(choice.title, systemImage: choice.symbol).tag(choice)
                            }
                        }.labelsHidden()
                        Spacer()
                        Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(index == 0).help("Move \(panel.title) left")
                            .accessibilityLabel("Move \(panel.title) left")
                        Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(index == panels.count - 1).help("Move \(panel.title) right")
                            .accessibilityLabel("Move \(panel.title) right")
                        Button {
                            var updated = panels
                            updated.remove(at: index)
                            save(updated)
                        } label: { Image(systemName: "minus.circle") }
                            .disabled(panels.count == 2)
                            .accessibilityLabel("Remove \(panel.title)")
                    }
                }
                if panels.count < 3 {
                    Button("Add a third panel") {
                        if let next = HomePanel.allCases.first(where: { !panels.contains($0) }) {
                            save(panels + [next])
                        }
                    }
                }
                if key != HomeLayout.sharedKey {
                    Button("Use default layout") { layouts.removeValue(forKey: key) }
                        .disabled(layouts[key] == nil)
                }
            } header: {
                Text("Panels, left to right")
            } footer: {
                Text("Agenda and Shelf follow their feature settings. Disabled panels show a helpful placeholder. Each display inherits the default until you customize it; saved display layouts are kept when disconnected.")
            }
            .disabled(!enabled)
        }
        .navigationTitle("Layout")
    }

    private var presetName: String {
        switch panels {
        case [.media, .utilities]: return "Listen"
        case [.agenda, .utilities]: return "Plan"
        case [.agenda, .shelf, .utilities]: return "Work"
        default: return "Custom"
        }
    }

    private func save(_ panels: [HomePanel]) { layouts[key] = panels.map(\.rawValue) }
    private func move(_ index: Int, by offset: Int) {
        var updated = panels
        let destination = index + offset
        guard updated.indices.contains(index), updated.indices.contains(destination) else { return }
        updated.swapAt(index, destination)
        save(updated)
    }

    private struct DisplayChoice: Identifiable {
        let id: String
        let name: String
    }
}
