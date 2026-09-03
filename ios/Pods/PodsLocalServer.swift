import Foundation
import Network

private actor PodsLocalServerEnsureGate {
    private var current: Task<Bool, Error>?

    func run(_ operation: @escaping @Sendable () async throws -> Bool) async throws -> Bool {
        if let current {
            return try await current.value
        }
        let task = Task { try await operation() }
        current = task
        do {
            let result = try await task.value
            current = nil
            return result
        } catch {
            current = nil
            throw error
        }
    }
}

private enum PodsLocalServerLifecycleError: LocalizedError {
    case cancelled
    case probeFailed
    case startupTimedOut

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "local server startup was cancelled"
        case .probeFailed:
            return "local server became ready but did not answer its health probe"
        case .startupTimedOut:
            return "local server listener did not become ready before the startup deadline"
        }
    }
}

final class PodsLocalServer {
    enum RequestParseResult {
        case incomplete
        case invalid(String)
        case complete(HTTPRequest)
    }

    private static let identityHeader = "x-pods-local-server"
    private static let identityValue = "1"
    private static let restartStartupTimeout: DispatchTimeInterval = .seconds(3)
    private static let maximumRequestBytes = 5_000_000
    private let backend: PodsRequestHandling
    private let staticAssets: PodsStaticAssets?
    private let port: UInt16
    private let queue = DispatchQueue(label: "dev.mcgiv.pods.local-server")
    private let ensureGate = PodsLocalServerEnsureGate()
    private var listener: NWListener?
    private var pendingStartupCompletion: ((Result<Void, Error>) -> Void)?

    init(backend: PodsRequestHandling, staticAssets: PodsStaticAssets? = .bundled(), port: UInt16 = 18180) {
        self.backend = backend
        self.staticAssets = staticAssets
        self.port = port
    }

    func start() throws {
        var result: Result<Void, Error>!
        queue.sync {
            result = Result { try self.startOnQueue() }
        }
        try result.get()
    }

    /// Positively verifies the loopback endpoint and, when it is unavailable,
    /// replaces the listener and waits for both NWListener.ready and an HTTP response.
    /// Returns true when a listener restart was required.
    func ensureReady() async throws -> Bool {
        try await ensureGate.run { [weak self] in
            guard let self else {
                throw PodsLocalServerLifecycleError.cancelled
            }
            if await self.probe() {
                return false
            }

            PodsLog("Pods local server health probe failed; restarting loopback listener")
            try await self.restartAndWaitUntilReady()
            for _ in 0..<10 {
                if await self.probe() {
                    PodsLog("Pods local server recovery probe succeeded")
                    return true
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            self.stop()
            throw PodsLocalServerLifecycleError.probeFailed
        }
    }

    func stop() {
        queue.sync {
            stopOnQueue()
        }
    }

    private func startOnQueue(
        initialStateHandler: ((Result<Void, Error>) -> Void)? = nil
    ) throws {
        if listener != nil {
            PodsDebugLog("Local server start skipped; listener already exists")
            return
        }

        PodsDebugLog("Local server starting on 127.0.0.1:\(port)")
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if let address = IPv4Address("127.0.0.1"), let nwPort = NWEndpoint.Port(rawValue: port) {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(address), port: nwPort)
        } else {
            PodsDebugLog("Local server could not construct explicit 127.0.0.1 endpoint for port \(port)")
        }
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        pendingStartupCompletion = initialStateHandler
        listener.stateUpdateHandler = { [weak self, weak listener, port] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                PodsLog("Pods local server ready at http://127.0.0.1:\(port)")
                self.resolvePendingStartup(.success(()))
            case .failed(let error):
                PodsLog("Pods local server failed: \(error)")
                self.listener = nil
                self.resolvePendingStartup(.failure(error))
            case .waiting(let error):
                PodsLog("Pods local server waiting: \(error)")
                self.listener = nil
                listener.cancel()
                self.resolvePendingStartup(.failure(error))
            case .cancelled:
                PodsLog("Pods local server cancelled")
                self.listener = nil
                self.resolvePendingStartup(.failure(PodsLocalServerLifecycleError.cancelled))
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        if initialStateHandler != nil {
            queue.asyncAfter(deadline: .now() + Self.restartStartupTimeout) { [weak self, weak listener] in
                guard let self, let listener,
                      self.listener === listener,
                      self.pendingStartupCompletion != nil else { return }
                PodsLog("Pods local server startup timed out")
                self.listener = nil
                listener.cancel()
                self.resolvePendingStartup(.failure(PodsLocalServerLifecycleError.startupTimedOut))
            }
        }
    }

    private func stopOnQueue() {
        let current = listener
        listener = nil
        current?.cancel()
        resolvePendingStartup(.failure(PodsLocalServerLifecycleError.cancelled))
    }

    private func resolvePendingStartup(_ result: Result<Void, Error>) {
        let completion = pendingStartupCompletion
        pendingStartupCompletion = nil
        completion?(result)
    }

    private func restartAndWaitUntilReady() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.stopOnQueue()
                do {
                    try self.startOnQueue { result in
                        continuation.resume(with: result)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func probe() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else {
            return false
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 0.75
        )
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                return false
            }
            return response.statusCode == 200
                && response.value(forHTTPHeaderField: Self.identityHeader) == Self.identityValue
        } catch {
            return false
        }
    }

    private func handle(_ connection: NWConnection) {
        PodsDebugLog("Local server accepted connection from \(String(describing: connection.endpoint))")
        connection.start(queue: queue)
        readRequest(from: connection, buffer: Data())
    }

    private func readRequest(from connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }
            switch Self.parseRequest(nextBuffer) {
            case .complete(let request):
                Task {
                    let response: HTTPResponse
                    let route: String
                    if let staticResponse = self.staticAssets?.response(for: request) {
                        response = staticResponse
                        route = "static"
                    } else {
                        response = await self.backend.handle(request)
                        route = "api"
                    }
                    PodsLog("Pods local server \(request.method) \(request.target) -> \(response.statusCode) \(route)")
                    PodsDebugLog("Local server response method=\(request.method) target=\(request.target) host=\(request.headers["host"] ?? "none") status=\(response.statusCode) route=\(route) bodyBytes=\(request.body.count)")
                    self.send(response, for: request, on: connection)
                }
            case .invalid(let message):
                PodsLog("Pods local server rejected invalid request: \(message)")
                self.send(.error(message), on: connection)
            case .incomplete where nextBuffer.count > Self.maximumRequestBytes:
                PodsLog("Pods local server rejected oversized request")
                self.send(.error("request too large"), on: connection)
            case .incomplete:
                self.readRequest(from: connection, buffer: nextBuffer)
            }
        }
    }

    private func send(
        _ response: HTTPResponse,
        for request: HTTPRequest? = nil,
        on connection: NWConnection
    ) {
        let data = Self.serialize(response, for: request)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    static func parseRequest(_ data: Data) -> RequestParseResult {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return .incomplete
        }
        let headerData = data[..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .invalid("request headers are not UTF-8")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .invalid("request line is missing")
        }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else {
            return .invalid("request line is malformed")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let rawContentLength = headers["content-length"] ?? "0"
        guard let contentLength = Int(rawContentLength), contentLength >= 0 else {
            return .invalid("content-length is invalid")
        }
        let bodyStart = headerEnd.upperBound
        guard bodyStart <= Self.maximumRequestBytes,
              contentLength <= Self.maximumRequestBytes - bodyStart else {
            return .invalid("request too large")
        }
        let bodyEnd = bodyStart + contentLength
        guard data.count >= bodyEnd else {
            return .incomplete
        }
        let body = data[bodyStart..<bodyEnd]
        return .complete(
            HTTPRequest(method: requestParts[0], target: requestParts[1], headers: headers, body: Data(body))
        )
    }

    private static func serialize(_ response: HTTPResponse, for request: HTTPRequest?) -> Data {
        var headers = response.headers
        if request?.headers["origin"] == "http://127.0.0.1:18180" {
            headers["access-control-allow-origin"] = "http://127.0.0.1:18180"
            headers["vary"] = "Origin"
        }
        headers["access-control-allow-methods"] = "GET, POST, PUT, DELETE, OPTIONS"
        headers["access-control-allow-headers"] = "content-type"
        headers[Self.identityHeader] = Self.identityValue
        headers["content-length"] = "\(response.body.count)"
        headers["connection"] = "close"

        let statusLine = "HTTP/1.1 \(response.statusCode) \(reasonPhrase(response.statusCode))\r\n"
        var text = statusLine
        for (name, value) in headers {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(response.body)
        return data
    }

    private static func reasonPhrase(_ statusCode: Int) -> String {
        switch statusCode {
        case 403:
            return "Forbidden"
        case 200:
            return "OK"
        case 201:
            return "Created"
        case 202:
            return "Accepted"
        case 204:
            return "No Content"
        case 404:
            return "Not Found"
        case 409:
            return "Conflict"
        case 422:
            return "Unprocessable Entity"
        default:
            return "Internal Server Error"
        }
    }
}
