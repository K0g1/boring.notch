import Foundation
import XCTest
@testable import boringNotch

final class LifecycleAndCacheTests: XCTestCase {
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
