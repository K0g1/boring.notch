import SwiftUI

struct ShortcutFavoritesRow: View {
    @ObservedObject private var store = ShortcutFavoritesStore.shared
    @AppStorage("showShortcutFavorites") private var showFavorites = true

    var body: some View {
        if showFavorites && !store.favorites.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                ForEach(store.favorites) { favorite in
                    Button { store.run(favorite) } label: {
                        Text(favorite.name)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(.white.opacity(0.09), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: 120)
                    .help("Run \(favorite.name)")
                    .accessibilityLabel("Run shortcut \(favorite.name)")
                }
                Spacer(minLength: 0)
                if let error = store.errorMessage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help(error)
                        .accessibilityLabel(error)
                }
            }
            .frame(height: 28)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Favorite Shortcuts")
        }
    }
}
