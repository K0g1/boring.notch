import Foundation
import XCTest
@testable import boringNotch

final class TodoistProviderTests: XCTestCase {
    func testLegacySyncPayloadDecodesFlexibleFields() throws {
        let response = try todoistResponse(
            """
            {
              "sync_token": "next",
              "full_sync": true,
              "projects": [{
                "id": "42", "name": "Work", "color": 31,
                "is_deleted": 0, "is_archived": "false", "inbox_project": 1
              }],
              "sections": [],
              "items": [{
                "id": "100", "project_id": "42", "content": "Ship it",
                "checked": 0, "is_deleted": "false", "priority": 4
              }]
            }
            """
        )

        XCTAssertEqual(response.syncToken, "next")
        XCTAssertEqual(response.projects?.first?.color?.value, "31")
        XCTAssertEqual(response.projects?.first?.inboxProject?.value, true)
        XCTAssertEqual(response.items?.first?.checked?.value, false)
        XCTAssertEqual(response.items?.first?.isDeleted?.value, false)
    }

    func testConnectPerformsFullThenIncrementalSyncAndMapsTask() async throws {
        let full = try todoistResponse(
            """
            {
              "sync_token": "full-token", "full_sync": true,
              "projects": [{"id":"p1","name":"Work","color":"berry_red"}],
              "sections": [],
              "items": [{
                "id":"t1", "project_id":"p1", "content":"Review release",
                "description":"Before launch", "priority":4, "checked":0,
                "due":{"datetime":"2026-09-20T18:30:00Z","is_recurring":false}
              }]
            }
            """
        )
        let incremental = try todoistResponse(
            """
            {"sync_token":"incremental-token","full_sync":false,
             "projects":[],"sections":[],"items":[]}
            """
        )
        let client = MockTodoistClient(responses: [.success(full), .success(incremental)])
        let credentials = FakeCredentialStore()
        let provider = TodoistProvider(
            client: client,
            credentials: credentials,
            cacheURL: temporaryTestURL()
        )

        try await provider.connect(token: "  secret-token  ")

        let calls = await client.syncCalls
        XCTAssertEqual(calls.map(\.syncToken), ["*", "full-token"])
        XCTAssertEqual(calls.map(\.token), ["secret-token", "secret-token"])
        XCTAssertEqual(try credentials.readToken(), "secret-token")

        let tasks = await provider.cachedTasks()
        let task = try XCTUnwrap(tasks.first)
        XCTAssertEqual(task.id, "todoist:t1")
        XCTAssertEqual(task.title, "Review release")
        XCTAssertEqual(task.notes, "Before launch")
        XCTAssertEqual(task.containerName, "Work")
        XCTAssertEqual(task.priority, .urgent)
        XCTAssertEqual(task.deepLink?.absoluteString, "https://app.todoist.com/app/task/t1")
        XCTAssertNotNil(task.due)
        XCTAssertFalse(task.isAllDay)
    }

    func testIncrementalRenameAndDeletionReplaceCachedState() async throws {
        let full = try todoistResponse(
            """
            {"sync_token":"one","full_sync":true,
             "projects":[{"id":"p1","name":"Old","color":"red"}],"sections":[],
             "items":[{"id":"t1","project_id":"p1","content":"One","checked":0},
                      {"id":"t2","project_id":"p1","content":"Two","checked":0}]}
            """
        )
        let empty = try todoistResponse(
            #"{"sync_token":"two","full_sync":false,"projects":[],"sections":[],"items":[]}"#
        )
        let delta = try todoistResponse(
            """
            {"sync_token":"three","full_sync":false,
             "projects":[{"id":"p1","name":"Renamed","color":"orange"}],"sections":[],
             "items":[{"id":"t1","is_deleted":1}]}
            """
        )
        let client = MockTodoistClient(
            responses: [.success(full), .success(empty), .success(delta)]
        )
        let provider = TodoistProvider(
            client: client,
            credentials: FakeCredentialStore(),
            cacheURL: temporaryTestURL()
        )
        try await provider.connect(token: "token")
        try await provider.refresh(force: true)

        let tasks = await provider.cachedTasks()
        let containers = await provider.containers()
        XCTAssertEqual(tasks.map(\.providerID), ["t2"])
        XCTAssertEqual(tasks.first?.containerName, "Renamed")
        XCTAssertEqual(containers.first?.name, "Renamed")
    }

    func testCompletionUsesTodoistMutationAndPreservesOptimisticCompletedTask() async throws {
        let full = try todoistResponse(
            """
            {"sync_token":"one","full_sync":true,
             "projects":[{"id":"p1","name":"Inbox"}],"sections":[],
             "items":[{"id":"t1","project_id":"p1","content":"Done","checked":0}]}
            """
        )
        let empty = try todoistResponse(
            #"{"sync_token":"two","full_sync":false,"projects":[],"sections":[],"items":[]}"#
        )
        let deletionDelta = try todoistResponse(
            """
            {"sync_token":"three","full_sync":false,"projects":[],"sections":[],
             "items":[{"id":"t1","is_deleted":1}]}
            """
        )
        let client = MockTodoistClient(
            responses: [.success(full), .success(empty), .success(deletionDelta)]
        )
        let provider = TodoistProvider(
            client: client,
            credentials: FakeCredentialStore(),
            cacheURL: temporaryTestURL()
        )
        try await provider.connect(token: "token")
        try await provider.setCompleted(taskID: "t1", completed: true)

        let mutations = await client.completionCalls
        XCTAssertEqual(
            mutations,
            [.init(taskID: "t1", completed: true, token: "token")]
        )
        let tasks = await provider.cachedTasks()
        let completed = try XCTUnwrap(tasks.first)
        XCTAssertTrue(completed.isCompleted)
    }

    func testOfflineCacheLoadsWithoutPersistingCredential() async throws {
        let cacheURL = temporaryTestURL()
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let full = try todoistResponse(
            """
            {"sync_token":"one","full_sync":true,
             "projects":[{"id":"p1","name":"Offline"}],"sections":[],
             "items":[{"id":"t1","project_id":"p1","content":"Cached","checked":0}]}
            """
        )
        let empty = try todoistResponse(
            #"{"sync_token":"two","full_sync":false,"projects":[],"sections":[],"items":[]}"#
        )
        let credentials = FakeCredentialStore()
        let onlineClient = MockTodoistClient(responses: [.success(full), .success(empty)])
        let onlineProvider = TodoistProvider(
            client: onlineClient,
            credentials: credentials,
            cacheURL: cacheURL
        )
        try await onlineProvider.connect(token: "never-write-this-token")

        let cacheData = try Data(contentsOf: cacheURL)
        XCTAssertNil(String(decoding: cacheData, as: UTF8.self).range(of: "never-write-this-token"))

        let offlineClient = MockTodoistClient(responses: [.failure(TestError.offline)])
        let offlineProvider = TodoistProvider(
            client: offlineClient,
            credentials: credentials,
            cacheURL: cacheURL
        )
        do {
            try await offlineProvider.refresh(force: true)
            XCTFail("Expected an offline refresh error")
        } catch TestError.offline {
            // Cached state remains available after the failed incremental sync.
        }
        let cachedTasks = await offlineProvider.cachedTasks()
        XCTAssertEqual(cachedTasks.first?.title, "Cached")
    }

    func testConcurrentRefreshesCoalesceIntoOneIncrementalRequest() async throws {
        let response = try todoistResponse(
            #"{"sync_token":"next","full_sync":false,"projects":[],"sections":[],"items":[]}"#
        )
        let client = MockTodoistClient(
            responses: [.success(response)],
            delay: .milliseconds(50)
        )
        let provider = TodoistProvider(
            client: client,
            credentials: FakeCredentialStore(token: "token"),
            cacheURL: temporaryTestURL()
        )

        async let first: Void = provider.refresh(force: true)
        async let second: Void = provider.refresh(force: true)
        async let third: Void = provider.refresh(force: true)
        _ = try await (first, second, third)

        let syncCallCount = await client.syncCalls.count
        XCTAssertEqual(syncCallCount, 1)
    }
}
