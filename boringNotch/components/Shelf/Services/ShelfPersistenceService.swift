//
//  ShelfPersistenceService.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import Foundation

/// Serializes Shelf state away from the main actor and coalesces bursts of
/// mutations (multi-item drops, reorders, bookmark refreshes) into one write.
actor ShelfPersistenceService {
    static let shared = ShelfPersistenceService()

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var pendingSave: Task<Void, Never>?

    private init() {
        let fileManager = FileManager.default
        let support = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = (support ?? fileManager.temporaryDirectory)
            .appendingPathComponent("boringNotch", isDirectory: true)
            .appendingPathComponent("Shelf", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("items.json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    deinit {
        pendingSave?.cancel()
    }

    func load() -> [ShelfItem] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        if let items = try? decoder.decode([ShelfItem].self, from: data) {
            return items
        }

        guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }

        return jsonArray.compactMap { jsonItem in
            guard let itemData = try? JSONSerialization.data(withJSONObject: jsonItem) else {
                return nil
            }
            return try? decoder.decode(ShelfItem.self, from: itemData)
        }
    }

    func scheduleSave(_ items: [ShelfItem]) {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.write(items)
        }
    }

    func saveImmediately(_ items: [ShelfItem]) {
        pendingSave?.cancel()
        pendingSave = nil
        write(items)
    }

    private func write(_ items: [ShelfItem]) {
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
