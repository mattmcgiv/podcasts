import Foundation
import Network

struct AdRemovalHTTPRequest: Equatable {
    let method: String
    let target: String
    let headers: [String: String]
}

struct AdRemovalStreamAuthorization: Equatable {
    let episodeID: Int64
    let fileURL: URL
    let byteCount: Int64
    let token: String
    let playbackSessionID: String
}

struct AdRemovalRangeResponsePlan: Equatable {
    let statusCode: Int
    let reason: String
    let headers: [String: String]
    let bodyRange: Range<Int64>?
}

enum AdRemovalRangeRequestPlanner {
    static func plan(
        request: AdRemovalHTTPRequest,
        authorization: AdRemovalStreamAuthorization?
    ) -> AdRemovalRangeResponsePlan {
        guard let authorization else {
            return response(status: 401, reason: "Unauthorized")
        }
        guard let components = URLComponents(string: "http://pods.invalid\(request.target)"),
              let suppliedToken = components.queryItems?.first(where: { $0.name == "token" })?.value,
              secureEqual(suppliedToken, authorization.token) else {
            return response(status: 401, reason: "Unauthorized")
        }
        guard components.path == "/episode/\(authorization.episodeID)" else {
            return response(status: 404, reason: "Not Found")
        }

        let method = request.method.uppercased()
        guard method == "GET" || method == "HEAD" else {
            return response(
                status: 405,
                reason: "Method Not Allowed",
                headers: ["Allow": "GET, HEAD"]
            )
        }

        let byteCount = max(0, authorization.byteCount)
        var headers = [
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
            "Content-Type": contentType(for: authorization.fileURL)
        ]
        guard let rangeHeader = header(named: "Range", in: request.headers) else {
            headers["Content-Length"] = String(byteCount)
            return AdRemovalRangeResponsePlan(
                statusCode: 200,
                reason: "OK",
                headers: headers,
                bodyRange: method == "GET" && byteCount > 0 ? 0..<byteCount : nil
            )
        }

        guard let range = parseRange(rangeHeader, byteCount: byteCount) else {
            headers["Content-Range"] = "bytes */\(byteCount)"
            headers["Content-Length"] = "0"
            return AdRemovalRangeResponsePlan(
                statusCode: 416,
                reason: "Range Not Satisfiable",
                headers: headers,
                bodyRange: nil
            )
        }
        headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(byteCount)"
        headers["Content-Length"] = String(range.count)
        return AdRemovalRangeResponsePlan(
            statusCode: 206,
            reason: "Partial Content",
            headers: headers,
            bodyRange: method == "GET" ? range : nil
        )
    }

    private static func parseRange(_ value: String, byteCount: Int64) -> Range<Int64>? {
        guard byteCount > 0,
              value.hasPrefix("bytes="),
              !value.contains(",") else {
            return nil
        }
        let specification = String(value.dropFirst("bytes=".count))
        let pieces = specification.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }

        if pieces[0].isEmpty {
            guard let suffixLength = Int64(pieces[1]), suffixLength > 0 else { return nil }
            let start = max(0, byteCount - suffixLength)
            return start..<byteCount
        }

        guard let start = Int64(pieces[0]), start >= 0, start < byteCount else { return nil }
        if pieces[1].isEmpty {
            return start..<byteCount
        }
        guard let requestedEnd = Int64(pieces[1]), requestedEnd >= start else { return nil }
        let end = min(requestedEnd, byteCount - 1)
        return start..<(end + 1)
    }

    private static func header(named name: String, in headers: [String: String]) -> String? {
        headers.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value
    }

    private static func response(
        status: Int,
        reason: String,
        headers: [String: String] = [:]
    ) -> AdRemovalRangeResponsePlan {
        var resolved = headers
        resolved["Content-Length"] = resolved["Content-Length"] ?? "0"
        resolved["Cache-Control"] = resolved["Cache-Control"] ?? "no-store"
        return .init(statusCode: status, reason: reason, headers: resolved, bodyRange: nil)
    }

    private static func secureEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        let count = max(left.count, right.count)
        var difference = UInt64(left.count ^ right.count)
        for index in 0..<count {
            difference |= UInt64((index < left.count ? left[index] : 0) ^ (index < right.count ? right[index] : 0))
        }
        return difference == 0
    }

    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3": "audio/mpeg"
        case "m4a", "mp4": "audio/mp4"
        case "aac": "audio/aac"
        case "wav": "audio/wav"
        case "ogg", "oga": "audio/ogg"
        case "flac": "audio/flac"
        default: "application/octet-stream"
        }
    }
}

protocol AdRemovalRangeServing: AnyObject {
    func start()
    func authorize(fileURL: URL, episodeID: Int64, playbackSessionID: String) -> URL?
    func revoke()
}

final class AdRemovalRangeServer: AdRemovalRangeServing {
    private let queue = DispatchQueue(label: "dev.mcgiv.pods.ad-removal.range-server")
    private let diagnostics: AdRemovalDiagnostics?
    private let hostAddress: () -> String?
    private var listener: NWListener?
    private var port: NWEndpoint.Port?
    private var authorization: AdRemovalStreamAuthorization?

    init(
        diagnostics: AdRemovalDiagnostics? = nil,
        hostAddress: @escaping () -> String? = AdRemovalLANAddress.best
    ) {
        self.diagnostics = diagnostics
        self.hostAddress = hostAddress
    }

    func start() {
        queue.async { [weak self] in
            self?.startLocked()
        }
    }

    func authorize(fileURL: URL, episodeID: Int64, playbackSessionID: String) -> URL? {
        queue.sync {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize > 0 else {
                authorization = nil
                return nil
            }
            let token = UUID().uuidString.lowercased() + UUID().uuidString.lowercased()
            let next = AdRemovalStreamAuthorization(
                episodeID: episodeID,
                fileURL: fileURL,
                byteCount: Int64(fileSize),
                token: token,
                playbackSessionID: playbackSessionID
            )
            authorization = next
            guard let url = authorizedURL(for: next) else { return nil }
            record(
                eventName: "lan_episode_authorized",
                severity: .notice,
                authorization: next,
                fields: ["authorized_file": "episode/\(episodeID)", "bytes": String(fileSize)]
            )
            return url
        }
    }

    func revoke() {
        queue.async { [weak self] in
            guard let self else { return }
            if let authorization = self.authorization {
                self.record(
                    eventName: "lan_episode_revoked",
                    severity: .info,
                    authorization: authorization
                )
            }
            self.authorization = nil
        }
    }

    private func startLocked() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters, on: .any)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                switch state {
                case .ready:
                    self.port = listener.port
                    self.record(eventName: "lan_range_listener_ready", severity: .notice)
                case .failed(let error):
                    self.record(
                        eventName: "lan_range_listener_failed",
                        severity: .error,
                        fields: ["error": error.localizedDescription]
                    )
                    listener.cancel()
                    if self.listener === listener {
                        self.listener = nil
                        self.port = nil
                    }
                case .cancelled:
                    self.record(eventName: "lan_range_listener_stopped", severity: .info)
                    if self.listener === listener {
                        self.listener = nil
                        self.port = nil
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
            record(eventName: "lan_range_listener_start", severity: .notice)
        } catch {
            record(
                eventName: "lan_range_listener_failed",
                severity: .error,
                fields: ["error": error.localizedDescription]
            )
        }
    }

    private func authorizedURL(for authorization: AdRemovalStreamAuthorization) -> URL? {
        guard let port, let host = hostAddress() else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port.rawValue)
        components.path = "/episode/\(authorization.episodeID)"
        components.queryItems = [URLQueryItem(name: "token", value: authorization.token)]
        return components.url
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.receiveHeader(from: connection, buffer: Data())
            case .failed(let error):
                self.record(
                    eventName: "lan_stream_disconnect",
                    severity: .warning,
                    fields: ["error": error.localizedDescription]
                )
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveHeader(from connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1_024) { [weak self] data, _, complete, error in
            guard let self else { return }
            var next = buffer
            if let data { next.append(data) }
            if next.count > 32 * 1_024 {
                self.sendSimple(status: 431, reason: "Request Header Fields Too Large", to: connection)
                return
            }
            if let end = next.range(of: Data("\r\n\r\n".utf8)) {
                self.handleHeader(next.subdata(in: next.startIndex..<end.upperBound), connection: connection)
                return
            }
            if complete || error != nil {
                connection.cancel()
                return
            }
            self.receiveHeader(from: connection, buffer: next)
        }
    }

    private func handleHeader(_ data: Data, connection: NWConnection) {
        guard let request = parseRequest(data) else {
            sendSimple(status: 400, reason: "Bad Request", to: connection)
            return
        }
        let authorization = self.authorization
        let plan = AdRemovalRangeRequestPlanner.plan(request: request, authorization: authorization)
        let responseBytes = plan.bodyRange?.count ?? 0
        record(
            eventName: "lan_range_request",
            severity: plan.statusCode < 400 ? .debug : .warning,
            authorization: authorization,
            fields: [
                "method": request.method,
                "range": request.headers.first(where: { $0.key.caseInsensitiveCompare("Range") == .orderedSame })?.value ?? "full",
                "status": String(plan.statusCode),
                "response_bytes": String(responseBytes)
            ]
        )
        let header = responseHeader(for: plan)
        guard let bodyRange = plan.bodyRange, let authorization else {
            connection.send(content: header, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        do {
            let file = try FileHandle(forReadingFrom: authorization.fileURL)
            try file.seek(toOffset: UInt64(bodyRange.lowerBound))
            connection.send(content: header, isComplete: false, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                guard error == nil else {
                    try? file.close()
                    connection.cancel()
                    return
                }
                self.sendFile(file, remaining: Int64(bodyRange.count), connection: connection, authorization: authorization)
            })
        } catch {
            connection.cancel()
            record(
                eventName: "lan_stream_file_error",
                severity: .error,
                authorization: authorization,
                fields: ["error": error.localizedDescription]
            )
        }
    }

    private func sendFile(
        _ file: FileHandle,
        remaining: Int64,
        connection: NWConnection,
        authorization: AdRemovalStreamAuthorization
    ) {
        guard remaining > 0 else {
            try? file.close()
            connection.cancel()
            return
        }
        do {
            let chunk = try file.read(upToCount: Int(min(64 * 1_024, remaining))) ?? Data()
            guard !chunk.isEmpty else {
                try? file.close()
                connection.cancel()
                record(eventName: "lan_stream_stall", severity: .warning, authorization: authorization)
                return
            }
            let nextRemaining = remaining - Int64(chunk.count)
            connection.send(content: chunk, isComplete: nextRemaining == 0, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    try? file.close()
                    connection.cancel()
                    self.record(
                        eventName: "lan_stream_disconnect",
                        severity: .warning,
                        authorization: authorization,
                        fields: ["error": error.localizedDescription]
                    )
                } else if nextRemaining == 0 {
                    try? file.close()
                    connection.cancel()
                } else {
                    self.sendFile(file, remaining: nextRemaining, connection: connection, authorization: authorization)
                }
            })
        } catch {
            try? file.close()
            connection.cancel()
            record(
                eventName: "lan_stream_file_error",
                severity: .error,
                authorization: authorization,
                fields: ["error": error.localizedDescription]
            )
        }
    }

    private func parseRequest(_ data: Data) -> AdRemovalHTTPRequest? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return .init(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers)
    }

    private func responseHeader(for plan: AdRemovalRangeResponsePlan) -> Data {
        var lines = ["HTTP/1.1 \(plan.statusCode) \(plan.reason)"]
        for key in plan.headers.keys.sorted() {
            lines.append("\(key): \(plan.headers[key]!)")
        }
        lines.append("Connection: close")
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private func sendSimple(status: Int, reason: String, to connection: NWConnection) {
        let plan = AdRemovalRangeResponsePlan(
            statusCode: status,
            reason: reason,
            headers: ["Content-Length": "0", "Cache-Control": "no-store"],
            bodyRange: nil
        )
        connection.send(content: responseHeader(for: plan), isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func record(
        eventName: String,
        severity: AdRemovalDiagnosticSeverity,
        authorization: AdRemovalStreamAuthorization? = nil,
        fields: [String: String] = [:]
    ) {
        try? diagnostics?.record(
            eventName: eventName,
            severity: severity,
            context: .init(
                episodeID: authorization?.episodeID,
                playbackSessionID: authorization?.playbackSessionID
            ),
            fields: fields
        )
    }
}

private enum AdRemovalLANAddress {
    static func best() -> String? {
        var addresses: [(preferred: Bool, address: String)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            let name = String(cString: item.pointee.ifa_name)
            guard name != "lo0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(address.pointee.sa_len)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            addresses.append((preferred: name == "en0", address: String(cString: host)))
        }
        return addresses.sorted { $0.preferred && !$1.preferred }.first?.address
    }
}
