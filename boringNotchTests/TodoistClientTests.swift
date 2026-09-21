import Foundation
import XCTest
@testable import boringNotch

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    struct Stub {
        let statusCode: Int
        let headers: [String: String]
        let data: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestHandler: ((URLRequest) throws -> Stub)?

    static func setHandler(_ handler: @escaping (URLRequest) throws -> Stub) {
        lock.withLock { requestHandler = handler }
    }

    static func reset() {
        lock.withLock { requestHandler = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.lock.withLock({ Self.requestHandler }) else {
                throw TestError.noResponse
            }
            let stub = try handler(request)
            guard let url = request.url else { throw TestError.noResponse }
            let response = HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class TodoistClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        URLProtocolStub.reset()
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    func testSyncUsesPostBearerAndExactResourceSet() async throws {
        let observed = LockedRequestBox()
        URLProtocolStub.setHandler { request in
            observed.request = request
            return .init(
                statusCode: 200,
                headers: [:],
                data: Data(
                    #"{"sync_token":"next","full_sync":false,"items":[],"projects":[],"sections":[]}"#.utf8
                )
            )
        }
        let client = TodoistClient(
            baseURL: URL(string: "https://todoist.test/api/v1")!,
            session: session
        )

        let response = try await client.sync(token: "private", syncToken: "previous")

        XCTAssertEqual(response.syncToken, "next")
        let request = try XCTUnwrap(observed.request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://todoist.test/api/v1/sync")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer private")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded; charset=utf-8"
        )

        let body = try XCTUnwrap(requestBodyData(request))
        let form = try XCTUnwrap(String(data: body, encoding: .utf8))
        let components = URLComponents(string: "?\(form)")
        let fields = Dictionary(
            uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) }
        )
        XCTAssertEqual(fields["sync_token"]!, "previous")
        let resourceJSON = try XCTUnwrap(fields["resource_types"]!)
        let resources = try JSONDecoder().decode([String].self, from: Data(resourceJSON.utf8))
        XCTAssertEqual(Set(resources), Set(["items", "projects", "sections"]))
    }

    func testCloseAndReopenUseCurrentV1Paths() async throws {
        let observed = LockedRequestsBox()
        URLProtocolStub.setHandler { request in
            observed.append(request)
            return .init(statusCode: 204, headers: [:], data: Data())
        }
        let client = TodoistClient(
            baseURL: URL(string: "https://todoist.test/api/v1")!,
            session: session
        )

        try await client.setCompleted(taskID: "123", completed: true, token: "private")
        try await client.setCompleted(taskID: "123", completed: false, token: "private")

        let requests = observed.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST"])
        XCTAssertEqual(
            requests.compactMap { $0.url?.path },
            ["/api/v1/tasks/123/close", "/api/v1/tasks/123/reopen"]
        )
        XCTAssertTrue(
            requests.allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization") == "Bearer private"
            }
        )
    }

    func testUnauthorizedResponseBecomesInvalidToken() async throws {
        URLProtocolStub.setHandler { _ in
            .init(statusCode: 401, headers: [:], data: Data())
        }
        let client = TodoistClient(
            baseURL: URL(string: "https://todoist.test/api/v1")!,
            session: session
        )

        do {
            _ = try await client.sync(token: "rejected", syncToken: "*")
            XCTFail("Expected invalid-token error")
        } catch TodoistClientError.invalidToken {
            // Expected typed authentication failure.
        }
    }

    func testForbiddenResponseBecomesInvalidToken() async throws {
        URLProtocolStub.setHandler { _ in
            .init(statusCode: 403, headers: [:], data: Data())
        }
        let client = makeClient()

        do {
            _ = try await client.sync(token: "rejected", syncToken: "*")
            XCTFail("Expected invalid-token error")
        } catch TodoistClientError.invalidToken {
            // Expected typed authentication failure.
        }
    }

    func testMalformedJSONBecomesInvalidResponse() async throws {
        URLProtocolStub.setHandler { _ in
            .init(statusCode: 200, headers: [:], data: Data("not-json".utf8))
        }
        let client = makeClient()

        do {
            _ = try await client.sync(token: "token", syncToken: "*")
            XCTFail("Expected invalid-response error")
        } catch TodoistClientError.invalidResponse {
            // Expected decoding failure.
        }
    }

    func testServerAndNotFoundStatusesRemainTyped() async throws {
        let statuses = LockedStatusQueue([404, 500])
        URLProtocolStub.setHandler { _ in
            .init(statusCode: statuses.removeFirst(), headers: [:], data: Data())
        }
        let client = makeClient()

        for expected in [404, 500] {
            do {
                _ = try await client.sync(token: "token", syncToken: "*")
                XCTFail("Expected HTTP status error")
            } catch TodoistClientError.httpStatus(let actual) {
                XCTAssertEqual(actual, expected)
            }
        }
    }

    func testRateLimitStopsAfterConfiguredRetryBudget() async throws {
        URLProtocolStub.setHandler { _ in
            .init(statusCode: 429, headers: ["Retry-After": "60"], data: Data())
        }
        let client = TodoistClient(
            baseURL: URL(string: "https://todoist.test/api/v1")!,
            session: session,
            maximumRateLimitRetries: 0
        )

        do {
            _ = try await client.sync(token: "token", syncToken: "*")
            XCTFail("Expected rate-limit error")
        } catch TodoistClientError.rateLimited {
            // The test configuration intentionally disables retries.
        }
    }

    private func makeClient() -> TodoistClient {
        TodoistClient(
            baseURL: URL(string: "https://todoist.test/api/v1")!,
            session: session
        )
    }
}

private func requestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }

    stream.open()
    defer { stream.close() }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else { return nil }
        if count == 0 { break }
        body.append(buffer, count: count)
    }
    return body
}

private final class LockedRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: URLRequest?

    var request: URLRequest? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class LockedRequestsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { storage } }

    func append(_ request: URLRequest) {
        lock.withLock { storage.append(request) }
    }
}

private final class LockedStatusQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [Int]

    init(_ statuses: [Int]) {
        self.statuses = statuses
    }

    func removeFirst() -> Int {
        lock.withLock { statuses.removeFirst() }
    }
}
