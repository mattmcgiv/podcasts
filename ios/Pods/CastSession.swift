// DEPRECATED as of 1 October 2026. Do not review, extend, or append to this file.
// See ios/DEPRECATED.md.

import Foundation
import Network

/// Discovers Pods Speaker on the LAN and maintains the control channel.
final class CastSession {
    static let shared = CastSession()

    var onEvent: (([String: Any]) -> Void)?
    var onStatusChange: ((CastStatus) -> Void)?

    private let queue = DispatchQueue(label: "dev.mcgiv.pods.cast")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var readBuffer = Data()
    private var discovered: [(name: String, endpoint: NWEndpoint)] = []
    private var status = CastStatus()
    private var pairingToken: String? {
        get { UserDefaults.standard.string(forKey: CastProtocol.tokenDefaultsKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: CastProtocol.tokenDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: CastProtocol.tokenDefaultsKey)
            }
        }
    }

    private init() {}

    var currentStatus: CastStatus { status }

    func startBrowsing() {
        queue.async { [weak self] in
            self?.startBrowsingLocked()
        }
    }

    /// Restart discovery (e.g. after returning to foreground) so a Mac that appeared
    /// while the browser was wedged becomes visible again.
    func refreshBrowsing() {
        queue.async { [weak self] in
            guard let self else { return }
            if let browser = self.browser {
                browser.cancel()
                self.browser = nil
            }
            self.startBrowsingLocked()
        }
    }

    private func startBrowsingLocked() {
        guard browser == nil else { return }
        let descriptor = NWBrowser.Descriptor.bonjour(type: CastProtocol.bonjourType, domain: nil)
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: descriptor, using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                PodsLog("Pods cast browser failed: \(error)")
                self.publishStatus { status in
                    status.error = error.localizedDescription
                    status.available = false
                }
                // Drop failed browser so a later refresh can recreate it.
                browser.cancel()
                if self.browser === browser {
                    self.browser = nil
                }
            case .ready:
                PodsLog("Pods cast browser ready")
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleBrowseResults(results)
        }
        browser.start(queue: queue)
        self.browser = browser
        PodsLog("Pods cast browsing for \(CastProtocol.bonjourType)")
    }

    func connectToFirstAvailable() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.connection != nil, self.status.connected {
                return
            }
            guard let first = self.discovered.first else {
                self.publishStatus { status in
                    status.error = "No Mac speaker found. Open Pods Speaker on your Mac (same Wi‑Fi)."
                }
                return
            }
            self.openConnection(to: first.endpoint, name: first.name)
        }
    }

    func disconnect(sendStop: Bool = true) {
        queue.async { [weak self] in
            guard let self else { return }
            let connection = self.connection
            let finish: () -> Void = { [weak self] in
                guard let self else { return }
                connection?.cancel()
                if self.connection === connection {
                    self.connection = nil
                }
                self.readBuffer = Data()
                self.publishStatus { status in
                    status.connected = false
                    status.error = nil
                }
            }
            if sendStop, let connection, let data = CastProtocol.encodeLine([
                "v": CastProtocol.version,
                "cmd": "stop",
            ]) {
                // Deliver stop before tearing down the socket so Mac audio actually halts.
                connection.send(content: data, completion: .contentProcessed { _ in
                    finish()
                })
            } else {
                finish()
            }
        }
    }

    func sendCommand(_ body: [String: Any], completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else {
                Self.completeCommand(completion, succeeded: false)
                return
            }
            guard self.status.connected else {
                Self.completeCommand(completion, succeeded: false)
                return
            }
            var payload = body
            payload["v"] = CastProtocol.version
            if let pairingToken {
                payload["token"] = pairingToken
            }
            self.sendRaw(payload) { succeeded in
                Self.completeCommand(completion, succeeded: succeeded)
            }
        }
    }

    // MARK: - Browse

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        var next: [(name: String, endpoint: NWEndpoint)] = []
        for result in results {
            let name: String
            if case .service(let serviceName, _, _, _) = result.endpoint {
                name = serviceName
            } else {
                name = "Mac"
            }
            next.append((name: name, endpoint: result.endpoint))
        }
        discovered = next.sorted { $0.name < $1.name }
        let available = !discovered.isEmpty
        let preferredName = discovered.first?.name
        publishStatus { status in
            status.available = available
            if !status.connected {
                status.name = preferredName
            }
            if available {
                status.error = nil
            }
        }
        // Auto-reconnect if we were connected and the service reappeared.
        if status.connected == false, connection == nil, discovered.count == 1 {
            // Do not auto-connect until user chooses Mac output — discovery only.
        }
    }

    // MARK: - Connection

    private func openConnection(to endpoint: NWEndpoint, name: String) {
        connection?.cancel()
        readBuffer = Data()
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        publishStatus { status in
            status.name = name
            status.connected = false
            status.error = nil
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                PodsLog("Pods cast connected to \(name)")
                self.receive(on: connection)
                // Auth handshake
                var auth: [String: Any] = ["v": CastProtocol.version, "cmd": "auth"]
                if let pairingToken {
                    auth["token"] = pairingToken
                }
                self.sendRaw(auth)
            case .failed(let error):
                PodsLog("Pods cast connection failed: \(error)")
                self.connection = nil
                self.publishStatus { status in
                    status.connected = false
                    status.error = error.localizedDescription
                }
                self.onEvent?(["type": "castDisconnected", "reason": "failed"])
            case .cancelled:
                if self.connection === connection {
                    self.connection = nil
                    self.publishStatus { status in
                        status.connected = false
                    }
                    self.onEvent?(["type": "castDisconnected", "reason": "cancelled"])
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.readBuffer.append(data)
                let messages = CastProtocol.parseLines(from: &self.readBuffer)
                for message in messages {
                    self.handleMessage(message)
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                if self.connection === connection {
                    self.connection = nil
                    self.publishStatus { status in
                        status.connected = false
                    }
                    self.onEvent?(["type": "castDisconnected", "reason": isComplete ? "closed" : "error"])
                }
                return
            }
            self.receive(on: connection)
        }
    }

    private func handleMessage(_ body: [String: Any]) {
        let type = body["type"] as? String
        switch type {
        case "hello":
            // Auth already sent on ready; nothing required.
            if let name = body["name"] as? String {
                publishStatus { status in
                    status.name = name
                }
            }
        case "paired":
            if let token = body["token"] as? String, !token.isEmpty {
                pairingToken = token
            }
            let name = body["name"] as? String ?? status.name
            publishStatus { status in
                status.connected = true
                status.name = name
                status.error = nil
            }
            onEvent?(["type": "castConnected", "name": name as Any])
        case "error":
            let message = body["message"] as? String ?? "cast error"
            publishStatus { status in
                status.error = message
            }
            if message.contains("denied") {
                pairingToken = nil
            }
            onEvent?(body)
        case "timeupdate", "play", "pause", "loadedmetadata", "ended", "state":
            onEvent?(body)
        default:
            if type != nil {
                onEvent?(body)
            }
        }
    }

    private func sendRaw(_ object: [String: Any], completion: ((Bool) -> Void)? = nil) {
        guard let connection, let data = CastProtocol.encodeLine(object) else {
            completion?(false)
            return
        }
        connection.send(content: data, completion: .contentProcessed { error in
            completion?(error == nil)
        })
    }

    private static func completeCommand(_ completion: ((Bool) -> Void)?, succeeded: Bool) {
        guard let completion else { return }
        DispatchQueue.main.async {
            completion(succeeded)
        }
    }

    private func publishStatus(_ mutate: (inout CastStatus) -> Void) {
        var next = status
        mutate(&next)
        status = next
        let snapshot = next
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChange?(snapshot)
        }
    }
}
