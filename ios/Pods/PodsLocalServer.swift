import Foundation
import Network

final class PodsLocalServer {
    private let backend: PodsBackend
    private let staticAssets: PodsStaticAssets?
    private let port: UInt16
    private let queue = DispatchQueue(label: "dev.mcgiv.pods.local-server")
    private var listener: NWListener?

    init(backend: PodsBackend, staticAssets: PodsStaticAssets? = .bundled(), port: UInt16 = 18180) {
        self.backend = backend
        self.staticAssets = staticAssets
        self.port = port
    }

    func start() throws {
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
        listener.stateUpdateHandler = { [port] state in
            switch state {
            case .ready:
                PodsLog("Pods local server ready at http://127.0.0.1:\(port)")
            case .failed(let error):
                PodsLog("Pods local server failed: \(error)")
            case .cancelled:
                PodsLog("Pods local server cancelled")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
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
            if let request = Self.parseRequest(nextBuffer) {
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
                    self.send(response, on: connection)
                }
            } else if nextBuffer.count > 5_000_000 {
                PodsLog("Pods local server rejected oversized request")
                self.send(.error(.invalid("request too large")), on: connection)
            } else {
                self.readRequest(from: connection, buffer: nextBuffer)
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        let data = Self.serialize(response)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func parseRequest(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        let headerData = data[..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else {
            return nil
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

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count >= bodyStart + contentLength else {
            return nil
        }
        let body = data[bodyStart..<(bodyStart + contentLength)]
        return HTTPRequest(method: requestParts[0], target: requestParts[1], headers: headers, body: Data(body))
    }

    private static func serialize(_ response: HTTPResponse) -> Data {
        var headers = response.headers
        headers["access-control-allow-origin"] = "*"
        headers["access-control-allow-methods"] = "GET, POST, PUT, DELETE, OPTIONS"
        headers["access-control-allow-headers"] = "content-type"
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
        case 200:
            return "OK"
        case 201:
            return "Created"
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
