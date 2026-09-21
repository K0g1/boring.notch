//
//  ImageService.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-13.
//

import Foundation
import Defaults
import ImageIO
import UniformTypeIdentifiers

public protocol ImageServiceProtocol {
    func fetchImageData(from url: URL) async throws -> Data
}

public final class ImageService: ImageServiceProtocol {
    public static let shared = ImageService()

    private let session: URLSession
    private let maximumArtworkDimension = 512
    private let maximumDownloadSize = 20 * 1024 * 1024

    private init() {
        let config = URLSessionConfiguration.default
        let cache = URLCache(memoryCapacity: 8 * 1024 * 1024,
                             diskCapacity: 64 * 1024 * 1024,
                             diskPath: "artwork_cache")
        config.urlCache = cache
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        self.session = URLSession(configuration: config)

        performLegacyCacheCleanupIfNeeded()
    }

    private func performLegacyCacheCleanupIfNeeded() {

        if !Defaults[.didClearLegacyURLCacheV1] {
            URLCache.shared.removeAllCachedResponses()
            Defaults[.didClearLegacyURLCacheV1] = true
        }
    }

    public func fetchImageData(from url: URL) async throws -> Data {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw URLError(.unsupportedURL)
        }
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard data.count <= maximumDownloadSize else {
            throw URLError(.dataLengthExceedsMaximum)
        }

        return try Self.downsampledImageData(
            data,
            maximumPixelSize: maximumArtworkDimension
        )
    }

    private static func downsampledImageData(
        _ data: Data,
        maximumPixelSize: Int
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            throw URLError(.cannotDecodeContentData)
        }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ] as CFDictionary

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              let output = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                output,
                UTType.png.identifier as CFString,
                1,
                nil
              ) else {
            throw URLError(.cannotDecodeContentData)
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw URLError(.cannotDecodeContentData)
        }
        return output as Data
    }
}
