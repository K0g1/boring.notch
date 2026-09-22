import AppKit
import XCTest
@testable import boringNotch

final class ShelfRegressionTests: XCTestCase {
    @MainActor
    func testTextAndLinkItemsShareTheirIconBitmaps() {
        let firstText = ShelfItem(kind: .text(string: "First"))
        let secondText = ShelfItem(kind: .text(string: "Second"))
        let firstLink = ShelfItem(kind: .link(url: URL(string: "https://example.com/one")!))
        let secondLink = ShelfItem(kind: .link(url: URL(string: "https://example.com/two")!))
        XCTAssertTrue(firstText.icon === secondText.icon)
        XCTAssertTrue(firstLink.icon === secondLink.icon)
        XCTAssertFalse(firstText.icon === firstLink.icon)
    }

    func testLargeClipboardTextKeepsFullPayloadButHasABoundedTitle() throws {
        let text = String(repeating: "A", count: 1_048_576)
        let item = ShelfItem(kind: .text(string: text))
        XCTAssertEqual(item.displayName.count, 80)
        XCTAssertEqual(item.kind, .text(string: text))
        let restored = try JSONDecoder().decode(ShelfItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(restored.kind, item.kind)
        XCTAssertEqual(restored.displayName, item.displayName)
        XCTAssertEqual(ShelfItem(kind: .text(string: "First line\nSecond line")).displayName, "First line")
        XCTAssertTrue(ShelfItem(kind: .text(string: "First line\nSecond line")).matchesSearch("Second"))
    }

    func testInvalidatedThumbnailCannotRefillCacheOrEraseANewerRequest() async {
        let firstStarted = expectation(description: "First generation started")
        let secondStarted = expectation(description: "Replacement generation started")
        let generator = ControlledThumbnailGenerator(started: [firstStarted, secondStarted])
        let service = ThumbnailService(generate: { _, _, _ in await generator.generate() },
                                       observesMemoryPressure: false)
        let url = URL(fileURLWithPath: "/tmp/boringnotch-thumbnail-fixture")
        let size = CGSize(width: 56, height: 56)
        let first = Task { await service.thumbnail(for: url, size: size) }
        await fulfillment(of: [firstStarted], timeout: 2)
        await service.clearCache(for: url)
        let second = Task { await service.thumbnail(for: url, size: size) }
        await fulfillment(of: [secondStarted], timeout: 2)
        await generator.complete(0)
        let firstResult = await first.value
        XCTAssertNil(firstResult)
        await generator.complete(1)
        let secondResult = await second.value
        XCTAssertNotNil(secondResult)
        let cached = await service.thumbnail(for: url, size: size)
        XCTAssertTrue(cached === secondResult)
        let calls = await generator.count
        XCTAssertEqual(calls, 2)
    }

    func testMemoryPressureClearRejectsInFlightThumbnail() async {
        let started = expectation(description: "Generation started")
        let generator = ControlledThumbnailGenerator(started: [started])
        let service = ThumbnailService(generate: { _, _, _ in await generator.generate() },
                                       observesMemoryPressure: false)
        let request = Task {
            await service.thumbnail(for: URL(fileURLWithPath: "/tmp/boringnotch-pressure-fixture"),
                                    size: CGSize(width: 56, height: 56))
        }
        await fulfillment(of: [started], timeout: 2)
        await service.clearCache()
        await generator.complete(0)
        let result = await request.value
        XCTAssertNil(result)
    }

    func testDisappearingShelfCancelsUnusedThumbnailWork() async {
        let started = expectation(description: "Generation started")
        let cancelled = expectation(description: "Underlying generation cancelled")
        let generator = ControlledThumbnailGenerator(started: [started], cancelled: cancelled)
        let service = ThumbnailService(generate: { _, _, _ in await generator.generate() },
                                       observesMemoryPressure: false)
        let request = Task {
            await service.thumbnail(for: URL(fileURLWithPath: "/tmp/boringnotch-cancel-fixture"),
                                    size: CGSize(width: 56, height: 56))
        }
        await fulfillment(of: [started], timeout: 2)
        request.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        await generator.complete(0)
        let result = await request.value
        XCTAssertNil(result)
    }
}

private actor ControlledThumbnailGenerator {
    private(set) var count = 0
    private let started: [XCTestExpectation]
    private let cancelled: XCTestExpectation?
    private var continuations: [Int: CheckedContinuation<CGImage?, Never>] = [:]

    init(started: [XCTestExpectation], cancelled: XCTestExpectation? = nil) {
        self.started = started
        self.cancelled = cancelled
    }

    func generate() async -> CGImage? {
        let index = count
        count += 1
        // Unexpected duplicate work should fail an assertion, not hang the suite.
        guard index < started.count else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                continuations[index] = $0
                started[index].fulfill()
            }
        } onCancel: { [cancelled] in
            cancelled?.fulfill()
        }
    }

    func complete(_ index: Int) {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        continuations.removeValue(forKey: index)?.resume(returning: context.makeImage())
    }
}
