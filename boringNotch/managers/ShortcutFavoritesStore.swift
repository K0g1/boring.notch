import AppKit
import Combine
import Foundation

struct ShortcutFavorite: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
}

/// Names are supplied explicitly: the sandboxed app never reads the private
/// Shortcuts database or starts a background process to enumerate workflows.
@MainActor
final class ShortcutFavoritesStore: ObservableObject {
    static let shared = ShortcutFavoritesStore()
    static let maximumFavorites = 6
    private static let storageKey = "macOSShortcutFavorites.v1"

    @Published private(set) var favorites: [ShortcutFavorite] = []
    @Published var errorMessage: String?

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return }
        do {
            let saved = try JSONDecoder().decode([ShortcutFavorite].self, from: data)
            var ids = Set<UUID>()
            var names = Set<String>()
            favorites = Array(saved.filter {
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && ids.insert($0.id).inserted && names.insert($0.name).inserted
            }.prefix(Self.maximumFavorites))
        } catch {
            errorMessage = "Saved shortcut favorites could not be loaded. Add your favorites again in Settings."
        }
    }

    @discardableResult
    func add(name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        guard favorites.count < Self.maximumFavorites else {
            errorMessage = "You can add up to \(Self.maximumFavorites) favorites."
            return false
        }
        guard !favorites.contains(where: { $0.name == name }) else {
            errorMessage = "That shortcut is already a favorite."
            return false
        }
        favorites.append(ShortcutFavorite(id: UUID(), name: name))
        persist()
        return true
    }

    func remove(_ favorite: ShortcutFavorite) {
        favorites.removeAll { $0.id == favorite.id }
        persist()
    }

    func move(_ favorite: ShortcutFavorite, by offset: Int) {
        guard let index = favorites.firstIndex(where: { $0.id == favorite.id }),
              favorites.indices.contains(index + offset) else { return }
        favorites.swapAt(index, index + offset)
        persist()
    }

    func run(_ favorite: ShortcutFavorite) {
        // URLComponents escapes user-provided names, including &, # and Unicode.
        // Opening a URL acknowledges the handoff, not successful execution.
        // https://support.apple.com/guide/shortcuts-mac/apd624386f42/mac
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: favorite.name)]
        // Preserve literal plus signs even if the receiving app uses form decoding.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        open(components.url)
    }

    func openShortcuts() {
        open(URL(string: "shortcuts://"))
    }

    private func open(_ url: URL?) {
        errorMessage = nil
        guard let url, NSWorkspace.shared.open(url) else {
            errorMessage = "Shortcuts could not be opened. Make sure the Shortcuts app is installed, then try again."
            return
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(favorites)
            UserDefaults.standard.set(data, forKey: Self.storageKey)
            errorMessage = nil
        } catch {
            errorMessage = "Your shortcut favorites could not be saved. Please try again."
        }
    }
}
