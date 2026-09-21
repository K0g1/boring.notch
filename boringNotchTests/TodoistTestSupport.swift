import Foundation
@testable import boringNotch

enum TestError: Error {
    case noResponse
    case offline
}

final class FakeCredentialStore: TodoistCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedToken: String?

    init(token: String? = nil) {
        storedToken = token
    }

    func readToken() throws -> String? {
        lock.withLock { storedToken }
    }

    func saveToken(_ token: String) throws {
        lock.withLock { storedToken = token }
    }

    func deleteToken() throws {
        lock.withLock { storedToken = nil }
    }
}

actor MockTodoistClient: TodoistClientProtocol {
    struct SyncCall: Equatable {
        let token: String
        let syncToken: String
    }

    struct CompletionCall: Equatable {
        let taskID: String
        let completed: Bool
        let token: String
    }

    private var responses: [Result<TodoistSyncResponse, Error>]
    private(set) var syncCalls: [SyncCall] = []
    private(set) var completionCalls: [CompletionCall] = []

    init(responses: [Result<TodoistSyncResponse, Error>]) {
        self.responses = responses
    }

    func sync(token: String, syncToken: String) async throws -> TodoistSyncResponse {
        syncCalls.append(SyncCall(token: token, syncToken: syncToken))
        guard !responses.isEmpty else { throw TestError.noResponse }
        return try responses.removeFirst().get()
    }

    func setCompleted(taskID: String, completed: Bool, token: String) async throws {
        completionCalls.append(
            CompletionCall(taskID: taskID, completed: completed, token: token)
        )
    }
}

func todoistResponse(_ json: String) throws -> TodoistSyncResponse {
    try JSONDecoder().decode(TodoistSyncResponse.self, from: Data(json.utf8))
}

func temporaryTestURL(_ filename: String = "sync-cache.json") -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("boringNotchTests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(filename)
}
