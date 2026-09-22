//
//  ThumbnailService.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-07.
//

import AppKit
import Foundation
@preconcurrency import QuickLookThumbnailing

actor ThumbnailGenerationLimiter {
    private let limit: Int
    private var activeCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func withPermit<T: Sendable>(
        _ operation: @Sendable () async -> T
    ) async -> T {
        await acquire()
        defer { release() }
        return await operation()
    }

    private func acquire() async {
        guard activeCount >= limit else {
            activeCount += 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            activeCount -= 1
            return
        }
        waiters.removeFirst().resume()
    }
}

struct ThumbnailCacheIndex {
    let countLimit: Int
    private(set) var keysByURL: [URL: Set<String>] = [:]
    private(set) var keyOwners: [String: URL] = [:]
    private(set) var keyOrder: [String] = []

    var keyCount: Int { keyOwners.count }
    var urlCount: Int { keysByURL.count }

    mutating func record(key: String, for url: URL) -> [String] {
        if let previousURL = keyOwners[key], previousURL != url {
            keysByURL[previousURL]?.remove(key)
            removeEmptyURL(previousURL)
        }
        if keyOwners[key] == nil {
            keyOrder.append(key)
        }
        keyOwners[key] = url
        keysByURL[url, default: []].insert(key)

        var evictedKeys: [String] = []
        while keyOrder.count > max(1, countLimit) {
            let oldestKey = keyOrder.removeFirst()
            evictedKeys.append(oldestKey)
            if let oldestURL = keyOwners.removeValue(forKey: oldestKey) {
                keysByURL[oldestURL]?.remove(oldestKey)
                removeEmptyURL(oldestURL)
            }
        }
        return evictedKeys
    }

    mutating func remove(url: URL) -> Set<String> {
        let keys = keysByURL.removeValue(forKey: url) ?? []
        for key in keys {
            keyOwners[key] = nil
        }
        keyOrder.removeAll(where: keys.contains)
        return keys
    }

    mutating func removeAll() {
        keysByURL.removeAll(keepingCapacity: false)
        keyOwners.removeAll(keepingCapacity: false)
        keyOrder.removeAll(keepingCapacity: false)
    }

    private mutating func removeEmptyURL(_ url: URL) {
        if keysByURL[url]?.isEmpty == true {
            keysByURL[url] = nil
        }
    }
}

actor ThumbnailService {
    static let shared = ThumbnailService()

    private struct PendingRequest {
        let id = UUID()
        let url: URL
        let task: Task<CGImage?, Never>
        var consumers: Set<UUID>
    }

    private let cache = NSCache<NSString, CGImage>()
    private var cacheIndex = ThumbnailCacheIndex(countLimit: 100)
    private var pendingRequests: [String: PendingRequest] = [:]
    private let generate: @Sendable (URL, CGSize, CGFloat) async -> CGImage?
    private let generationLimiter = ThumbnailGenerationLimiter(limit: 4)
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private static let cacheCountLimit = 100

    init(
        generate: @escaping @Sendable (URL, CGSize, CGFloat) async -> CGImage? = {
            await ThumbnailService.generateQuickLookThumbnail($0, $1, $2)
        },
        observesMemoryPressure: Bool = true
    ) {
        self.generate = generate
        cache.countLimit = Self.cacheCountLimit
        cache.totalCostLimit = 20 * 1024 * 1024

        guard observesMemoryPressure else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        memoryPressureSource = source
        source.setEventHandler { [weak self] in
            Task { await self?.clearCache() }
        }
        source.resume()
    }

    deinit {
        memoryPressureSource?.cancel()
        for request in pendingRequests.values { request.task.cancel() }
    }

    func thumbnail(for url: URL, size: CGSize) async -> CGImage? {
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
        guard !Task.isCancelled else { return nil }
        let key = Self.cacheKey(for: url, size: size, scale: scale)
        let cacheKey = key as NSString

        if let cachedImage = cache.object(forKey: cacheKey) {
            return cachedImage
        }
        let consumer = UUID()
        let request: PendingRequest
        if var pending = pendingRequests[key] {
            pending.consumers.insert(consumer)
            request = pending
        } else {
            let generate = generate
            let limiter = generationLimiter
            let task = Task.detached(priority: .utility) { () -> CGImage? in
                await limiter.withPermit {
                    guard !Task.isCancelled else { return nil }
                    return await generate(url, size, scale)
                }
            }
            request = PendingRequest(url: url.standardizedFileURL, task: task, consumers: [consumer])
        }
        pendingRequests[key] = request

        return await withTaskCancellationHandler {
            let thumbnail = await request.task.value
            guard !request.task.isCancelled, !Task.isCancelled else { return nil }
            // Only the first completed consumer populates the cache. Invalidated
            // requests cannot remove or overwrite a newer request for the same URL.
            if pendingRequests[key]?.id == request.id {
                pendingRequests[key] = nil
                if let thumbnail {
                    let cost = thumbnail.bytesPerRow * thumbnail.height
                    cache.setObject(thumbnail, forKey: cacheKey, cost: cost)
                    for evictedKey in cacheIndex.record(key: key, for: request.url) {
                        cache.removeObject(forKey: evictedKey as NSString)
                    }
                }
            }
            return thumbnail
        } onCancel: {
            Task { await self.removeConsumer(consumer, key: key, requestID: request.id) }
        }
    }

    private func removeConsumer(_ consumer: UUID, key: String, requestID: UUID) {
        guard var request = pendingRequests[key], request.id == requestID else { return }
        request.consumers.remove(consumer)
        if request.consumers.isEmpty {
            request.task.cancel()
            pendingRequests[key] = nil
        } else {
            pendingRequests[key] = request
        }
    }

    func clearCache() {
        for request in pendingRequests.values { request.task.cancel() }
        pendingRequests.removeAll()
        cache.removeAllObjects()
        cacheIndex.removeAll()
    }

    func clearCache(for url: URL) {
        let normalizedURL = url.standardizedFileURL
        for (key, request) in pendingRequests where request.url == normalizedURL {
            request.task.cancel()
            pendingRequests[key] = nil
        }
        for key in cacheIndex.remove(url: normalizedURL) {
            cache.removeObject(forKey: key as NSString)
        }
    }

    private static func cacheKey(for url: URL, size: CGSize, scale: CGFloat) -> String {
        let pixelWidth = Int((size.width * scale).rounded(.up))
        let pixelHeight = Int((size.height * scale).rounded(.up))
        return "\(url.standardizedFileURL.path)|\(pixelWidth)x\(pixelHeight)@\(scale)"
    }

    nonisolated static func generateQuickLookThumbnail(
        _ url: URL,
        _ size: CGSize,
        _ scale: CGFloat
    ) async -> CGImage? {
        await url.accessSecurityScopedResource { scopedURL -> CGImage? in
            let request = QLThumbnailGenerator.Request(
                fileAt: scopedURL,
                size: size,
                scale: scale,
                representationTypes: .all
            )
            request.iconMode = true

            let generator = QLThumbnailGenerator.shared
            return await withTaskCancellationHandler {
                guard !Task.isCancelled else { return nil }
                let representation = try? await generator.generateBestRepresentation(for: request)
                return Task.isCancelled ? nil : representation?.cgImage
            } onCancel: {
                generator.cancel(request)
            }
        }
    }
}
