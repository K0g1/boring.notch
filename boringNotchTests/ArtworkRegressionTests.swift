import AppKit
import ImageIO
import XCTest
@testable import boringNotch

final class ArtworkRegressionTests: XCTestCase {
    func testDownloadedArtworkIsDownsampledBeforeDisplay() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: file) }
        let context = CGContext(data: nil, width: 2048, height: 1024, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let output = try ImageService.readDownloadedArtwork(from: file)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 512)
        XCTAssertEqual(image.height, 256)
    }

    func testOversizedDownloadIsRejectedBeforeImageDecoding() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 21 * 1024 * 1024)
        try handle.close()
        XCTAssertThrowsError(try ImageService.readDownloadedArtwork(from: file)) {
            XCTAssertEqual(($0 as? URLError)?.code, .dataLengthExceedsMaximum)
        }
    }
}
