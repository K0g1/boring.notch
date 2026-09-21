//
//  ThumbnailService.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-07.
//

import AppKit
import Foundation
import QuickLookThumbnailing

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

actor ThumbnailService {
    static let shared = ThumbnailService()

    private let cache = NSCache<NSString, CGImage>()
    private var cacheKeysByURL: [URL: Set<NSString>] = [:]
    private var pendingRequests: [String: Task<CGImage?, Never>] = [:]
    private let thumbnailGenerator = QLThumbnailGenerator.shared
    private let generationLimiter = ThumbnailGenerationLimiter(limit: 4)
    private let memoryPressureSource: DispatchSourceMemoryPressure

    private init() {
        cache.countLimit = 100
        cache.totalCostLimit = 20 * 1024 * 1024

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        memoryPressureSource = source
        source.setEventHandler {
            Task { await ThumbnailService.shared.clearCache() }
        }
        source.resume()
    }

    func thumbnail(for url: URL, size: CGSize) async -> CGImage? {
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
        let key = Self.cacheKey(for: url, size: size, scale: scale)
        let cacheKey = key as NSString

        if let cachedImage = cache.object(forKey: cacheKey) {
            return cachedImage
        }
        if let pending = pendingRequests[key] {
            return await pending.value
        }

        let generator = thumbnailGenerator
        let limiter = generationLimiter
        let task = Task.detached(priority: .utility) {
            await limiter.withPermit {
                await Self.generateQuickLookThumbnail(
                    for: url,
                    size: size,
                    scale: scale,
                    generator: generator
                )
            }
        }
        pendingRequests[key] = task

        let thumbnail = await task.value
        pendingRequests[key] = nil

        if let thumbnail {
            let cost = thumbnail.bytesPerRow * thumbnail.height
            cache.setObject(thumbnail, forKey: cacheKey, cost: cost)
            cacheKeysByURL[url.standardizedFileURL, default: []].insert(cacheKey)
        }
        return thumbnail
    }

    func clearCache() {
        cache.removeAllObjects()
        cacheKeysByURL.removeAll(keepingCapacity: false)
    }

    func clearCache(for url: URL) {
        let normalizedURL = url.standardizedFileURL
        for key in cacheKeysByURL.removeValue(forKey: normalizedURL) ?? [] {
            cache.removeObject(forKey: key)
        }
    }

    private static func cacheKey(for url: URL, size: CGSize, scale: CGFloat) -> String {
        let pixelWidth = Int((size.width * scale).rounded(.up))
        let pixelHeight = Int((size.height * scale).rounded(.up))
        return "\(url.standardizedFileURL.path)|\(pixelWidth)x\(pixelHeight)@\(scale)"
    }

    private nonisolated static func generateQuickLookThumbnail(
        for url: URL,
        size: CGSize,
        scale: CGFloat,
        generator: QLThumbnailGenerator
    ) async -> CGImage? {
        await url.accessSecurityScopedResource { scopedURL -> CGImage? in
            let request = QLThumbnailGenerator.Request(
                fileAt: scopedURL,
                size: size,
                scale: scale,
                representationTypes: .all
            )
            request.iconMode = true

            let representation = try? await generator.generateBestRepresentation(for: request)
            return representation?.cgImage
        }
    }
}
