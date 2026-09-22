//
//  ShelfStateViewModel.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-09.

import Foundation
import AppKit
import Combine
import Defaults

@MainActor
final class ShelfStateViewModel: ObservableObject {
    static let shared = ShelfStateViewModel()

    @Published private(set) var items: [ShelfItem] = [] {
        didSet {
            ShelfSelectionModel.shared.reconcile(with: items)
            scheduleExpiration()
            let snapshot = items
            Task { await ShelfPersistenceService.shared.scheduleSave(snapshot) }
        }
    }

    @Published var isLoading: Bool = false
    @Published var notice: String?
    static let maximumItems = 200
    private var expirationTask: Task<Void, Never>?
    private var expirationPreference: AnyCancellable?

    var isEmpty: Bool { items.isEmpty }

    // Queue for deferred bookmark updates to avoid publishing during view updates
    private var pendingBookmarkUpdates: [ShelfItem.ID: Data] = [:]
    private var updateTask: Task<Void, Never>?
    private var initialLoadTask: Task<[ShelfItem], Never>?

    private init() {
        expirationPreference = Defaults.publisher(.shelfExpirationHours)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.expireItems() }
            }
        isLoading = true
        let loadTask = Task { await ShelfPersistenceService.shared.load() }
        initialLoadTask = loadTask

        Task { @MainActor [weak self] in
            var restoredItems = await loadTask.value
            for index in restoredItems.indices {
                restoredItems[index].preparePresentationMetadata()
            }

            guard let self else { return }
            var merged = restoredItems
            var seen = Set(merged.map(\.identityKey))
            for item in self.items where seen.insert(item.identityKey).inserted {
                merged.append(item)
            }
            self.items = merged
            self.expireItems()
            self.isLoading = false
            self.initialLoadTask = nil
        }
    }


    func add(_ newItems: [ShelfItem]) {
        guard !newItems.isEmpty else { return }
        var merged = items
        // Deduplicate by identityKey while preserving order (existing first)
        var seen: Set<String> = Set(merged.map { $0.identityKey })
        for it in newItems {
            let key = it.identityKey
            if !seen.contains(key) {
                guard merged.count < Self.maximumItems else {
                    it.cleanupStoredData()
                    notice = "Shelf is full (200 items). Remove an item to make room."
                    continue
                }
                merged.append(it)
                seen.insert(key)
            }
        }
        items = merged
    }

    func setPinned(_ pinned: Bool, for selected: [ShelfItem]) {
        let ids = Set(selected.map(\.id))
        var updated = items
        for index in updated.indices where ids.contains(updated[index].id) {
            updated[index].isPinned = pinned
        }
        items = updated
        expireItems()
    }

    func rename(_ item: ShelfItem, to name: String) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].renamePresentation(to: name)
    }

    func expireItems() {
        let hours = Defaults[.shelfExpirationHours]
        guard hours > 0 else { scheduleExpiration(); return }
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
        let expired = items.filter { !$0.isPinned && ($0.addedAt ?? Date()) <= cutoff }
        guard !expired.isEmpty else { scheduleExpiration(); return }
        let ids = Set(expired.map(\.id))
        expired.forEach { $0.cleanupStoredData() }
        items.removeAll { ids.contains($0.id) }
    }

    private func scheduleExpiration() {
        expirationTask?.cancel()
        expirationTask = nil
        let hours = Defaults[.shelfExpirationHours]
        guard hours > 0,
              let oldest = items.filter({ !$0.isPinned }).compactMap(\.addedAt).min() else { return }
        let delay = max(1, oldest.addingTimeInterval(Double(hours) * 3600).timeIntervalSinceNow)
        expirationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.expireItems()
        }
    }

    func paste() {
        let pasteboard = NSPasteboard.general
        notice = nil
        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        if !urls.isEmpty {
            load(Array(urls.prefix(Self.maximumItems)).map { NSItemProvider(object: $0 as NSURL) })
        } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
            guard text.utf8.count <= 1_048_576 else {
                notice = "Clipboard text is too large. Save it as a file and add that file instead."
                return
            }
            add([ShelfItem(kind: .text(string: text))])
        } else if let type = pasteboard.availableType(from: [.png, .tiff]),
                  let data = pasteboard.data(forType: type) {
            guard data.count <= 20 * 1024 * 1024 else {
                notice = "Clipboard image is too large. Add an image file instead."
                return
            }
            let provider = NSItemProvider(item: data as NSData, typeIdentifier: type.rawValue)
            provider.suggestedName = type == .png ? "Clipboard.png" : "Clipboard.tiff"
            load([provider])
        } else {
            notice = "Copy files, a link, or text to paste onto the shelf."
        }
    }

    func remove(_ item: ShelfItem) {
        item.cleanupStoredData()
        items.removeAll { $0.id == item.id }
    }

    func updateBookmark(for item: ShelfItem, bookmark: Data) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if case .file = items[idx].kind {
            items[idx].kind = .file(bookmark: bookmark)
        }
    }

    private func scheduleDeferredBookmarkUpdate(for item: ShelfItem, bookmark: Data) {
        pendingBookmarkUpdates[item.id] = bookmark
        
        // Cancel existing task and schedule a new one
        updateTask?.cancel()
        updateTask = Task { @MainActor [weak self] in
            await Task.yield()
            
            guard let self = self else { return }
            
            for (itemID, bookmarkData) in self.pendingBookmarkUpdates {
                if let idx = self.items.firstIndex(where: { $0.id == itemID }),
                   case .file = self.items[idx].kind {
                    self.items[idx].kind = .file(bookmark: bookmarkData)
                }
            }
            
            self.pendingBookmarkUpdates.removeAll()
        }
    }


    func load(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        isLoading = true
        Task { [weak self] in
            let dropped = await ShelfDropService.items(from: Array(providers.prefix(Self.maximumItems)))
            await MainActor.run {
                self?.add(dropped)
                if dropped.isEmpty {
                    self?.notice = "No supported items could be added. Try a file, link, text, or image."
                }
                self?.isLoading = false
            }
        }
    }

    func cleanupInvalidItems() {
        expireItems()
        Task { [weak self] in
            guard let self else { return }
            _ = await self.initialLoadTask?.value
            var invalidIDs: Set<UUID> = []
            for item in self.items {
                switch item.kind {
                case .file(let data):
                    let bookmark = Bookmark(data: data)
                    if !(await bookmark.validate()) {
                        invalidIDs.insert(item.id)
                    }
                default:
                    break
                }
            }
            // Apply only removals to current state: validation can suspend while
            // the user adds, pins, or renames other shelf items.
            for item in self.items where invalidIDs.contains(item.id) {
                item.cleanupStoredData()
            }
            if !invalidIDs.isEmpty { self.items.removeAll { invalidIDs.contains($0.id) } }
        }
    }


    func resolveFileURL(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Bookmark for \(item) stale; refreshing")
            scheduleDeferredBookmarkUpdate(for: item, bookmark: refreshed)
        }
        return result.url
    }

    func resolveAndUpdateBookmark(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Bookmark for \(item) stale; refreshing")
            updateBookmark(for: item, bookmark: refreshed)
        }
        return result.url
    }

    func resolveFileURLs(for items: [ShelfItem]) -> [URL] {
        var urls: [URL] = []
        for it in items {
            if let u = resolveFileURL(for: it) { urls.append(u) }
        }
        return urls
    }
}
