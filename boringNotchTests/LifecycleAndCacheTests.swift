import AppKit
import Foundation
import XCTest
@testable import boringNotch

final class LifecycleAndCacheTests: XCTestCase {
    @MainActor
    func testNotchViewModelsReleaseAcrossOneThousandDisplayLifecycles() {
        for _ in 0..<1_000 {
            weak var releasedModel: BoringViewModel?
            autoreleasepool {
                let model = BoringViewModel()
                releasedModel = model
                model.dropZoneTargeting = true
                XCTAssertTrue(model.anyDropZoneTargeting)
                model.dropZoneTargeting = false
                XCTAssertFalse(model.anyDropZoneTargeting)
            }
            if releasedModel != nil {
                XCTFail("A discarded display model is retained by its own subscriptions")
                return
            }
        }
    }

    @MainActor
    func testBlinkControllerRemainsBoundedAcrossOneThousandCycles() {
        let controller = BlinkTaskController()
        var isBlinking = false

        for _ in 0..<1_000 {
            XCTAssertTrue(
                controller.start(interval: .seconds(60)) { isBlinking = $0 }
            )
            XCTAssertFalse(
                controller.start(interval: .seconds(60)) { isBlinking = $0 },
                "A visible face must own at most one blink task"
            )
            XCTAssertTrue(controller.isRunning)
            controller.stop { isBlinking = $0 }
            XCTAssertFalse(controller.isRunning)
            XCTAssertFalse(isBlinking)
        }
    }

    func testThumbnailLimiterNeverExceedsConfiguredConcurrency() async {
        let limiter = ThumbnailGenerationLimiter(limit: 4)
        let counter = ConcurrencyCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await limiter.withPermit {
                        await counter.enter()
                        try? await Task.sleep(for: .milliseconds(10))
                        await counter.leave()
                    }
                }
            }
        }

        let peak = await counter.peak
        let active = await counter.active
        XCTAssertEqual(peak, 4)
        XCTAssertEqual(active, 0)
    }

    func testThumbnailReverseIndexHasSameHardBoundAsImageCache() {
        var index = ThumbnailCacheIndex(countLimit: 100)
        var evictedKeys: [String] = []

        for item in 0..<250 {
            let url = URL(fileURLWithPath: "/tmp/thumbnail-\(item)")
            evictedKeys += index.record(key: "key-\(item)", for: url)
        }

        XCTAssertEqual(index.keyCount, 100)
        XCTAssertEqual(index.urlCount, 100)
        XCTAssertEqual(evictedKeys.count, 150)
        XCTAssertEqual(evictedKeys.first, "key-0")
        XCTAssertEqual(evictedKeys.last, "key-149")

        let finalURL = URL(fileURLWithPath: "/tmp/thumbnail-249")
        XCTAssertEqual(index.remove(url: finalURL), ["key-249"])
        XCTAssertEqual(index.keyCount, 99)
        XCTAssertEqual(index.urlCount, 99)
    }

    @MainActor
    func testShelfIconCostUsesPixelDimensions() {
        let image = NSImage(size: NSSize(width: 64, height: 80))
        image.addRepresentation(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 128,
                pixelsHigh: 160,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )!
        )

        XCTAssertEqual(ShelfItem.imageCost(image), 128 * 160 * 4)
    }

    func testTaskProviderFiltersDatedAndUndatedItems() async {
        let now = Date()
        let interval = DateInterval(start: now.addingTimeInterval(-30), duration: 60)
        let provider = FixedTaskProvider(
            tasks: [
                TaskItem(
                    providerID: "inside",
                    source: .todoist,
                    title: "Inside",
                    due: now,
                    color: .todoistRed
                ),
                TaskItem(
                    providerID: "outside",
                    source: .todoist,
                    title: "Outside",
                    due: now.addingTimeInterval(3_600),
                    color: .todoistRed
                ),
                TaskItem(
                    providerID: "next-day-boundary",
                    source: .todoist,
                    title: "Exactly at the interval end",
                    due: interval.end,
                    color: .todoistRed
                ),
                TaskItem(
                    providerID: "undated",
                    source: .todoist,
                    title: "Undated",
                    color: .todoistRed
                )
            ]
        )

        let tasks = await provider.tasks(in: interval)
        XCTAssertEqual(tasks.map(\.providerID), ["inside"])
    }
}

private actor ConcurrencyCounter {
    private(set) var active = 0
    private(set) var peak = 0

    func enter() {
        active += 1
        peak = max(peak, active)
    }

    func leave() {
        active -= 1
    }
}

private actor FixedTaskProvider: TaskProvider {
    private let tasks: [TaskItem]

    init(tasks: [TaskItem]) {
        self.tasks = tasks
    }

    func refresh(force: Bool) async throws {}
    func cachedTasks() async -> [TaskItem] { tasks }
    func containers() async -> [TaskContainer] { [] }
    func setCompleted(taskID: String, completed: Bool) async throws {}
}
