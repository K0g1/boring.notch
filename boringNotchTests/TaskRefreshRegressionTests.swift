import Combine
import Defaults
import EventKit
import XCTest
@testable import boringNotch

final class TaskRefreshRegressionTests: XCTestCase {
    @MainActor
    func testLocalCalendarNotificationBurstDoesNotResyncTodoistOrRepublishUnchangedTasks() async throws {
        let previousProjects = Defaults[.selectedTodoistProjectIDs]
        let previousLists = Defaults[.reminderSelectionState]
        defer {
            Defaults[.selectedTodoistProjectIDs] = previousProjects
            Defaults[.reminderSelectionState] = previousLists
        }
        Defaults[.selectedTodoistProjectIDs] = nil
        Defaults[.reminderSelectionState] = .all
        let full = try todoistResponse(
            #"{"sync_token":"one","full_sync":true,"projects":[{"id":"p1","name":"Work"}],"sections":[],"items":[]}"#
        )
        let delta = try todoistResponse(
            #"{"sync_token":"two","full_sync":false,"projects":[],"sections":[],"items":[]}"#
        )
        let client = MockTodoistClient(responses: [.success(full), .success(delta), .success(delta)])
        let cache = temporaryTestURL()
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let todoist = TodoistProvider(client: client, credentials: FakeCredentialStore(), cacheURL: cache)
        try await todoist.connect(token: "fixture")
        let reminders = FixtureRemindersProvider()
        let store = TaskStore(appleProvider: reminders, todoistProvider: todoist)
        store.start()
        // Allow the startup task (including its connection-state read) to finish.
        try await Task.sleep(for: .milliseconds(100))
        await store.refresh(force: false)
        let initialReminderRefreshes = await reminders.refreshCount
        var taskPublications = 0
        let subscription = store.$tasks.dropFirst().sink { _ in taskPublications += 1 }
        defer { subscription.cancel() }
        let refreshed = expectation(description: "Debounced local refresh finished")
        let refreshSubscription = store.$isRefreshing.dropFirst().filter { !$0 }.prefix(1).sink { _ in
            refreshed.fulfill()
        }
        defer { refreshSubscription.cancel() }

        for _ in 0..<100 {
            NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil)
        }
        await fulfillment(of: [refreshed], timeout: 3)
        let syncs = await client.syncCalls
        let reminderRefreshes = await reminders.refreshCount
        XCTAssertEqual(syncs.count, 2, "Local changes must not force a remote network sync")
        XCTAssertEqual(reminderRefreshes, initialReminderRefreshes + 1)
        XCTAssertEqual(taskPublications, 0, "Identical snapshots must not invalidate the entire agenda")
        XCTAssertEqual(store.tasks.map(\.providerID), ["a", "b"])

        await store.refresh(force: true)
        let manualSyncs = await client.syncCalls
        XCTAssertEqual(manualSyncs.count, 3, "Explicit refresh still refreshes both providers")
    }
}

private actor FixtureRemindersProvider: AppleRemindersProviding {
    private(set) var refreshCount = 0
    nonisolated func authorizationStatus() -> EKAuthorizationStatus { .fullAccess }
    func requestAccess() async throws -> Bool { true }
    func clearCache() {}
    func refresh(force: Bool) { refreshCount += 1 }
    func containers() -> [TaskContainer] { [] }
    func setCompleted(taskID: String, completed: Bool) {}
    func cachedTasks() -> [TaskItem] {
        [
            TaskItem(providerID: "b", source: .appleReminders, title: "Same", priority: nil, color: .reminderBlue),
            TaskItem(providerID: "a", source: .appleReminders, title: "Same", priority: .normal, color: .reminderBlue)
        ]
    }
}
