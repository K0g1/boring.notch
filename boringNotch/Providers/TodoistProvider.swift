//
//  TodoistProvider.swift
//  boringNotch
//

import Foundation
import Security

// MARK: - Credentials

protocol TodoistCredentialStoring: Sendable {
    func readToken() throws -> String?
    func saveToken(_ token: String) throws
    func deleteToken() throws
}

enum TodoistKeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain operation failed (\(status))."
        case .invalidData:
            return "The Todoist credential in Keychain is invalid."
        }
    }
}

struct TodoistKeychainStore: TodoistCredentialStoring {
    private let service: String
    private let account = "personal-api-token"

    init(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.k0g1.boringnotch.optimized") {
        service = "\(bundleIdentifier).todoist-api-token"
    }

    func readToken() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw TodoistKeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            throw TodoistKeychainError.invalidData
        }
        return token
    }

    func saveToken(_ token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw TodoistKeychainError.invalidData
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw TodoistKeychainError.unexpectedStatus(updateStatus)
        }

        var query = baseQuery
        attributes.forEach { query[$0.key] = $0.value }
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TodoistKeychainError.unexpectedStatus(addStatus)
        }
    }

    func deleteToken() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TodoistKeychainError.unexpectedStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

// MARK: - Network client

enum TodoistClientError: LocalizedError {
    case invalidToken
    case rateLimited
    case httpStatus(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "Todoist rejected the API token."
        case .rateLimited:
            return "Todoist rate-limited the request. Try again shortly."
        case .httpStatus(let status):
            return "Todoist returned HTTP \(status)."
        case .invalidResponse:
            return "Todoist returned an invalid response."
        }
    }
}

protocol TodoistClientProtocol: Sendable {
    func sync(token: String, syncToken: String) async throws -> TodoistSyncResponse
    func setCompleted(taskID: String, completed: Bool, token: String) async throws
    func create(_ draft: TaskDraft, token: String) async throws -> TodoistItemDTO
    func update(taskID: String, change: TaskChange, token: String) async throws -> TodoistItemDTO
    func delete(taskID: String, token: String) async throws
}

extension TodoistClientProtocol {
    func create(_ draft: TaskDraft, token: String) async throws -> TodoistItemDTO { throw TaskEditingError.unsupported }
    func update(taskID: String, change: TaskChange, token: String) async throws -> TodoistItemDTO { throw TaskEditingError.unsupported }
    func delete(taskID: String, token: String) async throws { throw TaskEditingError.unsupported }
}

actor TodoistClient: TodoistClientProtocol {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let maximumRateLimitRetries: Int
    private let sleep: Sleep

    init(
        baseURL: URL = URL(string: "https://api.todoist.com/api/v1")!,
        session: URLSession? = nil,
        maximumRateLimitRetries: Int = 2,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.baseURL = baseURL
        self.maximumRateLimitRetries = max(0, maximumRateLimitRetries)
        self.sleep = sleep
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: configuration)
        }
        decoder = JSONDecoder()
    }

    func sync(token: String, syncToken: String) async throws -> TodoistSyncResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("sync"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )

        let resourcesData = try JSONEncoder().encode(["items", "projects", "sections"])
        guard let resources = String(data: resourcesData, encoding: .utf8) else {
            throw TodoistClientError.invalidResponse
        }
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "sync_token", value: syncToken),
            URLQueryItem(name: "resource_types", value: resources)
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let data = try await perform(request)
        do {
            return try decoder.decode(TodoistSyncResponse.self, from: data)
        } catch {
            throw TodoistClientError.invalidResponse
        }
    }

    func setCompleted(taskID: String, completed: Bool, token: String) async throws {
        let escapedID = taskID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? taskID
        let action = completed ? "close" : "reopen"
        let url = baseURL
            .appendingPathComponent("tasks")
            .appendingPathComponent(escapedID)
            .appendingPathComponent(action)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await perform(request)
    }

    func create(_ draft: TaskDraft, token: String) async throws -> TodoistItemDTO {
        var body: [String: Any] = ["content": draft.title, "project_id": draft.containerID]
        if let due = draft.due { body.merge(dueBody(due, allDay: draft.isAllDay)) { _, new in new } }
        let data = try await mutate(path: "tasks", method: "POST", body: body, token: token)
        return try decoder.decode(TodoistItemDTO.self, from: data)
    }

    func update(taskID: String, change: TaskChange, token: String) async throws -> TodoistItemDTO {
        let body: [String: Any]
        switch change {
        case .title(let title): body = ["content": title]
        case .priority(let priority): body = ["priority": priority?.rawValue ?? 1]
        case .due(let date, let allDay):
            body = date.map { dueBody($0, allDay: allDay) } ?? ["due_string": "no date"]
        }
        let data = try await mutate(path: "tasks/\(taskID)", method: "POST", body: body, token: token)
        return try decoder.decode(TodoistItemDTO.self, from: data)
    }

    func delete(taskID: String, token: String) async throws {
        _ = try await mutate(path: "tasks/\(taskID)", method: "DELETE", body: nil, token: token)
    }

    private func dueBody(_ date: Date, allDay: Bool) -> [String: Any] {
        if allDay {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return ["due_date": formatter.string(from: date)]
        }
        return ["due_datetime": ISO8601DateFormatter().string(from: date)]
    }

    private func mutate(path: String, method: String, body: [String: Any]?, token: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Reuse this request ID across rate-limit retries; never replay ambiguous failures.
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-Id")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        var retryCount = 0
        while true {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw TodoistClientError.invalidResponse
            }
            switch response.statusCode {
            case 200..<300:
                return data
            case 401, 403:
                throw TodoistClientError.invalidToken
            case 429 where retryCount < maximumRateLimitRetries:
                retryCount += 1
                let retryAfter = min(
                    30,
                    max(1, TimeInterval(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1)
                )
                try await sleep(.seconds(retryAfter))
            case 429:
                throw TodoistClientError.rateLimited
            default:
                throw TodoistClientError.httpStatus(response.statusCode)
            }
        }
    }
}

// MARK: - Sync DTOs

struct TodoistSyncResponse: Decodable, Sendable {
    let syncToken: String
    let fullSync: Bool?
    let items: [TodoistItemDTO]?
    let projects: [TodoistProjectDTO]?
    let sections: [TodoistSectionDTO]?

    enum CodingKeys: String, CodingKey {
        case syncToken = "sync_token"
        case fullSync = "full_sync"
        case items, projects, sections
    }
}

struct TodoistItemDTO: Codable, Sendable {
    let id: String
    var projectID: String?
    var sectionID: String?
    var content: String?
    var description: String?
    var priority: Int?
    var checked: FlexibleBool?
    var isDeleted: FlexibleBool?
    var due: TodoistDueDTO?

    enum CodingKeys: String, CodingKey {
        case id, content, description, priority, checked, due
        case projectID = "project_id"
        case sectionID = "section_id"
        case isDeleted = "is_deleted"
    }
}

struct TodoistDueDTO: Codable, Sendable {
    let date: String?
    let datetime: String?
    let timezone: String?
    let isRecurring: Bool?

    enum CodingKeys: String, CodingKey {
        case date, datetime, timezone
        case isRecurring = "is_recurring"
    }
}

struct TodoistProjectDTO: Codable, Sendable {
    let id: String
    var name: String?
    var color: FlexibleString?
    var isDeleted: FlexibleBool?
    var isArchived: FlexibleBool?
    var inboxProject: FlexibleBool?

    enum CodingKeys: String, CodingKey {
        case id, name, color
        case isDeleted = "is_deleted"
        case isArchived = "is_archived"
        case inboxProject = "inbox_project"
    }
}

struct TodoistSectionDTO: Codable, Sendable {
    let id: String
    var projectID: String?
    var name: String?
    var isDeleted: FlexibleBool?
    var isArchived: FlexibleBool?

    enum CodingKeys: String, CodingKey {
        case id, name
        case projectID = "project_id"
        case isDeleted = "is_deleted"
        case isArchived = "is_archived"
    }
}

struct FlexibleBool: Codable, Equatable, Sendable {
    let value: Bool

    init(_ value: Bool) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int != 0
        } else if let string = try? container.decode(String.self) {
            value = string == "1" || string.lowercased() == "true"
        } else {
            value = false
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct FlexibleString: Codable, Equatable, Sendable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else {
            value = "charcoal"
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

// MARK: - Provider and offline cache

private struct TodoistCacheEnvelope: Codable {
    let version: Int
    var syncToken: String?
    var lastSync: Date?
    var items: [TodoistItemDTO]
    var projects: [TodoistProjectDTO]
    var sections: [TodoistSectionDTO]
}

actor TodoistProvider: TaskProvider {
    nonisolated let supportsEditing = true
    private let client: any TodoistClientProtocol
    private let credentials: any TodoistCredentialStoring
    private let cacheURL: URL
    private var itemCache: [String: TodoistItemDTO] = [:]
    private var projectCache: [String: TodoistProjectDTO] = [:]
    private var sectionCache: [String: TodoistSectionDTO] = [:]
    private var pendingCompletedIDs: Set<String> = []
    private var syncToken: String?
    private var lastSync: Date?
    private var didLoadCache = false
    private var refreshTask: Task<Void, Error>?
    private let staleAfter: TimeInterval = 60
    private let fractionalISOFormatter: ISO8601DateFormatter
    private let isoFormatter: ISO8601DateFormatter
    private let dayFormatter: DateFormatter

    init(
        client: any TodoistClientProtocol = TodoistClient(),
        credentials: any TodoistCredentialStoring = TodoistKeychainStore(),
        cacheURL: URL? = nil
    ) {
        self.client = client
        self.credentials = credentials
        let fractionalISOFormatter = ISO8601DateFormatter()
        fractionalISOFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.fractionalISOFormatter = fractionalISOFormatter
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        self.isoFormatter = isoFormatter
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = .current
        dayFormatter.dateFormat = "yyyy-MM-dd"
        self.dayFormatter = dayFormatter
        if let cacheURL {
            self.cacheURL = cacheURL
        } else {
            let fileManager = FileManager.default
            let support = try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = (support ?? fileManager.temporaryDirectory)
                .appendingPathComponent("boringNotch", isDirectory: true)
                .appendingPathComponent("Todoist", isDirectory: true)
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            self.cacheURL = directory.appendingPathComponent("sync-cache.json")
        }
    }

    func connect(token: String) async throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw TodoistClientError.invalidToken }

        let fullSync = try await client.sync(token: token, syncToken: "*")
        resetLocalState()
        apply(fullSync)
        let incremental = try await client.sync(
            token: token,
            syncToken: syncToken ?? fullSync.syncToken
        )
        apply(incremental)
        try credentials.saveToken(token)
        persistCache()
    }

    func disconnect() throws {
        refreshTask?.cancel()
        refreshTask = nil
        try credentials.deleteToken()
        resetLocalState()
        didLoadCache = true
        try? FileManager.default.removeItem(at: cacheURL)
    }

    func isConnected() -> Bool {
        (try? credentials.readToken()) != nil
    }

    func lastSuccessfulSync() -> Date? {
        loadCacheIfNeeded()
        return lastSync
    }

    func refresh(force: Bool = false) async throws {
        loadCacheIfNeeded()
        guard let token = try credentials.readToken() else { return }
        if !force,
           let lastSync,
           Date().timeIntervalSince(lastSync) < staleAfter {
            return
        }

        if let refreshTask {
            try await refreshTask.value
            return
        }

        let currentSyncToken = syncToken ?? "*"
        let task = Task { [client] in
            let response = try await client.sync(token: token, syncToken: currentSyncToken)
            try Task.checkCancellation()
            self.apply(response)
            self.persistCache()
        }
        refreshTask = task
        do {
            try await task.value
            refreshTask = nil
        } catch {
            refreshTask = nil
            throw error
        }
    }

    func cachedTasks() -> [TaskItem] {
        loadCacheIfNeeded()
        return itemCache.values.compactMap(makeTaskItem)
    }

    func containers() -> [TaskContainer] {
        loadCacheIfNeeded()
        return projectCache.values.compactMap { project in
            guard project.isDeleted?.value != true,
                  project.isArchived?.value != true else { return nil }
            return TaskContainer(
                id: project.id,
                source: .todoist,
                name: project.name ?? "Project",
                color: Self.projectColor(project.color?.value)
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func setCompleted(taskID: String, completed: Bool) async throws {
        loadCacheIfNeeded()
        guard let token = try credentials.readToken() else {
            throw TodoistClientError.invalidToken
        }
        try await client.setCompleted(taskID: taskID, completed: completed, token: token)
        guard try credentials.readToken() == token else { return }

        if var item = itemCache[taskID] {
            item.checked = FlexibleBool(completed)
            itemCache[taskID] = item
        }
        if completed {
            pendingCompletedIDs.insert(taskID)
        } else {
            pendingCompletedIDs.remove(taskID)
        }
        persistCache()
        // The write already succeeded. A failed follow-up refresh must not roll it back.
        try? await refresh(force: true)
    }

    func create(_ draft: TaskDraft) async throws {
        if let refreshTask { try await refreshTask.value }
        loadCacheIfNeeded()
        guard let token = try credentials.readToken() else { throw TodoistClientError.invalidToken }
        guard projectCache[draft.containerID] != nil else { throw TaskEditingError.invalidDestination }
        let item = try await client.create(draft, token: token)
        // Disconnect may have occurred while the request was in flight.
        guard try credentials.readToken() == token else { return }
        itemCache[item.id] = item
        persistCache()
    }

    func update(taskID: String, change: TaskChange) async throws {
        if let refreshTask { try await refreshTask.value }
        loadCacheIfNeeded()
        guard let token = try credentials.readToken() else { throw TodoistClientError.invalidToken }
        var item = try await client.update(taskID: taskID, change: change, token: token)
        guard try credentials.readToken() == token else { return }
        // REST task responses can omit Sync's `checked` field.
        if item.checked == nil { item.checked = itemCache[taskID]?.checked }
        itemCache[item.id] = item
        persistCache()
    }

    func delete(taskID: String) async throws {
        if let refreshTask { try await refreshTask.value }
        guard let token = try credentials.readToken() else { throw TodoistClientError.invalidToken }
        try await client.delete(taskID: taskID, token: token)
        guard try credentials.readToken() == token else { return }
        itemCache[taskID] = nil
        pendingCompletedIDs.remove(taskID)
        persistCache()
    }

    private func apply(_ response: TodoistSyncResponse) {
        if response.fullSync == true {
            itemCache.removeAll(keepingCapacity: true)
            projectCache.removeAll(keepingCapacity: true)
            sectionCache.removeAll(keepingCapacity: true)
        }

        for item in response.items ?? [] {
            if item.isDeleted?.value == true {
                if pendingCompletedIDs.remove(item.id) != nil, var completed = itemCache[item.id] {
                    completed.checked = FlexibleBool(true)
                    completed.isDeleted = FlexibleBool(false)
                    itemCache[item.id] = completed
                } else {
                    itemCache[item.id] = nil
                }
            } else {
                itemCache[item.id] = item
                if item.checked?.value == false {
                    pendingCompletedIDs.remove(item.id)
                }
            }
        }
        for project in response.projects ?? [] {
            if project.isDeleted?.value == true || project.isArchived?.value == true {
                projectCache[project.id] = nil
            } else {
                projectCache[project.id] = project
            }
        }
        for section in response.sections ?? [] {
            if section.isDeleted?.value == true || section.isArchived?.value == true {
                sectionCache[section.id] = nil
            } else {
                sectionCache[section.id] = section
            }
        }

        syncToken = response.syncToken
        lastSync = Date()
    }

    private func makeTaskItem(_ item: TodoistItemDTO) -> TaskItem? {
        guard item.isDeleted?.value != true else { return nil }
        let project = item.projectID.flatMap { projectCache[$0] }
        if item.projectID != nil, project == nil {
            // Archived and deleted projects are removed during incremental sync;
            // their remaining item deltas must not leak back into the UI.
            return nil
        }
        let due = parseDue(item.due)
        let taskURL = URL(string: "https://app.todoist.com/app/task/\(item.id)")

        return TaskItem(
            providerID: item.id,
            source: .todoist,
            title: item.content ?? "",
            notes: item.description,
            due: due,
            isAllDay: item.due?.datetime == nil && item.due?.date?.contains("T") != true,
            isCompleted: item.checked?.value ?? false,
            priority: Self.priority(from: item.priority),
            containerID: item.projectID,
            containerName: project?.name,
            color: Self.projectColor(project?.color?.value),
            deepLink: taskURL,
            isRecurring: item.due?.isRecurring ?? false
        )
    }

    private func loadCacheIfNeeded() {
        guard !didLoadCache else { return }
        didLoadCache = true
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(TodoistCacheEnvelope.self, from: data),
              cache.version == 1 else { return }
        syncToken = cache.syncToken
        lastSync = cache.lastSync
        itemCache = Dictionary(uniqueKeysWithValues: cache.items.map { ($0.id, $0) })
        projectCache = Dictionary(uniqueKeysWithValues: cache.projects.map { ($0.id, $0) })
        sectionCache = Dictionary(uniqueKeysWithValues: cache.sections.map { ($0.id, $0) })
    }

    private func persistCache() {
        let cache = TodoistCacheEnvelope(
            version: 1,
            syncToken: syncToken,
            lastSync: lastSync,
            items: Array(itemCache.values),
            projects: Array(projectCache.values),
            sections: Array(sectionCache.values)
        )
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func resetLocalState() {
        itemCache.removeAll(keepingCapacity: false)
        projectCache.removeAll(keepingCapacity: false)
        sectionCache.removeAll(keepingCapacity: false)
        pendingCompletedIDs.removeAll(keepingCapacity: false)
        syncToken = nil
        lastSync = nil
    }

    private static func priority(from value: Int?) -> TaskPriority? {
        guard let value else { return nil }
        switch value {
        case 1: return .low
        case 2: return .normal
        case 3: return .high
        case 4: return .urgent
        default: return nil
        }
    }

    private func parseDue(_ due: TodoistDueDTO?) -> Date? {
        guard let due else { return nil }
        if let datetime = due.datetime {
            if let date = fractionalISOFormatter.date(from: datetime) {
                return date
            }
            return isoFormatter.date(from: datetime)
        }
        guard let value = due.date else { return nil }
        if value.contains("T") {
            if let date = fractionalISOFormatter.date(from: value) ?? isoFormatter.date(from: value) { return date }
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = due.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return formatter.date(from: value)
        }
        return dayFormatter.date(from: String(value.prefix(10)))
    }

    private static func projectColor(_ value: String?) -> TaskColor {
        switch value?.lowercased() {
        case "berry_red", "30": return TaskColor(red: 0.72, green: 0.08, blue: 0.20)
        case "red", "31": return TaskColor(red: 0.86, green: 0.18, blue: 0.18)
        case "orange", "32": return TaskColor(red: 1.0, green: 0.60, blue: 0.0)
        case "yellow", "33": return TaskColor(red: 0.98, green: 0.76, blue: 0.05)
        case "olive_green", "34": return TaskColor(red: 0.69, green: 0.68, blue: 0.13)
        case "lime_green", "35": return TaskColor(red: 0.49, green: 0.74, blue: 0.13)
        case "green", "36": return TaskColor(red: 0.18, green: 0.64, blue: 0.36)
        case "mint_green", "37": return TaskColor(red: 0.09, green: 0.72, blue: 0.58)
        case "teal", "38": return TaskColor(red: 0.10, green: 0.62, blue: 0.65)
        case "sky_blue", "39": return TaskColor(red: 0.13, green: 0.65, blue: 0.86)
        case "light_blue", "40": return TaskColor(red: 0.20, green: 0.52, blue: 0.85)
        case "blue", "41": return TaskColor(red: 0.25, green: 0.35, blue: 0.82)
        case "grape", "42": return TaskColor(red: 0.55, green: 0.24, blue: 0.78)
        case "violet", "43": return TaskColor(red: 0.68, green: 0.27, blue: 0.78)
        case "lavender", "44": return TaskColor(red: 0.88, green: 0.42, blue: 0.84)
        case "magenta", "45": return TaskColor(red: 0.89, green: 0.20, blue: 0.55)
        case "salmon", "46": return TaskColor(red: 1.0, green: 0.48, blue: 0.47)
        default: return .todoistRed
        }
    }
}
