import SwiftUI

struct ShortcutFavoritesSettings: View {
    @ObservedObject private var store = ShortcutFavoritesStore.shared
    @AppStorage("showShortcutFavorites") private var showFavorites = true
    @State private var newName = ""

    var body: some View {
        Section {
            Toggle("Show favorites in the notch", isOn: $showFavorites)
            ForEach(Array(store.favorites.enumerated()), id: \.element.id) { index, favorite in
                HStack {
                    Label(favorite.name, systemImage: "square.stack.3d.up")
                        .lineLimit(1)
                        .help(favorite.name)
                    Spacer()
                    Button { store.move(favorite, by: -1) } label: {
                        Image(systemName: "arrow.up")
                    }
                    .disabled(index == 0)
                    .help("Move earlier")
                    .accessibilityLabel("Move \(favorite.name) earlier")
                    Button { store.move(favorite, by: 1) } label: {
                        Image(systemName: "arrow.down")
                    }
                    .disabled(index == store.favorites.count - 1)
                    .help("Move later")
                    .accessibilityLabel("Move \(favorite.name) later")
                    Button { store.remove(favorite) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .help("Remove favorite")
                    .accessibilityLabel("Remove \(favorite.name)")
                }
                .buttonStyle(.borderless)
            }
            if store.favorites.isEmpty {
                Text("Add a favorite to show the Shortcuts row in your notch.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                TextField("Exact shortcut name", text: $newName)
                    .onSubmit(addFavorite)
                Button("Add", action: addFavorite)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || store.favorites.count >= ShortcutFavoritesStore.maximumFavorites)
            }
            Button("Open Shortcuts", action: store.openShortcuts)
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("macOS Shortcuts")
        } footer: {
            Text("Add up to six favorites using their exact names in Shortcuts. Use the arrows to reorder them. If you rename a shortcut, remove and add its favorite again. Shortcuts handles execution, permission requests, and any missing-shortcut errors.")
        }
    }

    private func addFavorite() {
        if store.add(name: newName) { newName = "" }
    }
}
