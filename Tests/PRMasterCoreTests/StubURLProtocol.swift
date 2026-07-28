import Foundation

enum StubOutcome {
    case response(status: Int, body: Data)
    case failure(URLError)
}

struct RecordedRequest {
    let url: URL?
    let headers: [String: String]
    let body: Data?
}

/// A stubbed URLSession scoped to one test.
///
/// State is keyed by a per-session header rather than held in a global, so
/// suites running in parallel cannot consume each other's queued responses.
final class StubSession: Sendable {
    let id: String
    let session: URLSession

    init(outcomes: [StubOutcome]) {
        let id = UUID().uuidString
        self.id = id

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        config.httpAdditionalHeaders = [StubURLProtocol.sessionHeader: id]
        self.session = URLSession(configuration: config)

        StubURLProtocol.register(id: id, outcomes: outcomes)
    }

    var requests: [RecordedRequest] { StubURLProtocol.requests(for: id) }

    deinit { StubURLProtocol.unregister(id: id) }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    static let sessionHeader = "X-PRMaster-Stub-Session"

    // Guarded by `lock`; the compiler cannot see that, hence nonisolated(unsafe).
    private static let lock = NSLock()
    nonisolated(unsafe) private static var outcomes: [String: [StubOutcome]] = [:]
    nonisolated(unsafe) private static var recorded: [String: [RecordedRequest]] = [:]

    static func register(id: String, outcomes new: [StubOutcome]) {
        lock.withLock {
            outcomes[id] = new
            recorded[id] = []
        }
    }

    static func unregister(id: String) {
        lock.withLock {
            outcomes[id] = nil
            recorded[id] = nil
        }
    }

    static func requests(for id: String) -> [RecordedRequest] {
        lock.withLock { recorded[id] ?? [] }
    }

    // URLProtocol replaces httpBody with a stream, so read it back.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let sessionID = request.value(forHTTPHeaderField: Self.sessionHeader) ?? ""

        let outcome: StubOutcome? = Self.lock.withLock {
            Self.recorded[sessionID, default: []].append(RecordedRequest(
                url: request.url,
                headers: request.allHTTPHeaderFields ?? [:],
                body: Self.body(of: request)
            ))
            guard var queued = Self.outcomes[sessionID], !queued.isEmpty else { return nil }
            let next = queued.removeFirst()
            Self.outcomes[sessionID] = queued
            return next
        }

        switch outcome {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .response(let status, let body):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case nil:
            // Ran out of queued outcomes: fail loudly rather than hang.
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
        }
    }

    override func stopLoading() {}
}
