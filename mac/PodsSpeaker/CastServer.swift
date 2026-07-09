import AppKit
import Foundation
import Network
import UserNotifications

/// Bonjour-advertised TCP control server. Accepts one active phone connection at a time.
///
/// Network I/O runs on `queue`. UI + `SpeakerPlayer` work always hops to the main actor.
final class CastServer: ObservableObject {
    @Published private(set) var statusText: String = "Starting…"
    @Published private(set) var clientLabel: String = "No phone connected"
    @Published private(set) var isListening = false

    private let player: SpeakerPlayer
    private let queue = DispatchQueue(label: "dev.mcgiv.pods.speaker.server")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var readBuffer = Data()
    private var connectionAuthorized = false
    private var deviceName: String {
        Host.current().localizedName ?? "Mac"
    }

    init(player: SpeakerPlayer) {
        self.player = player
    }

    /// Wire player → phone event delivery. Call from the main actor after construction.
    @MainActor
    func attachPlayerEvents() {
        player.onEvent = { [weak self] event in
            // Player events arrive on the main actor; hop sends onto the network queue so we
            // never race `connection` mutations against NWConnection callbacks.
            self?.queue.async {
                guard let self else { return }
                guard self.connectionAuthorized, let connection = self.connection else { return }
                self.send(event, to: connection)
            }
        }
    }

    func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(name: "Pods Speaker (\(deviceName))", type: CastProtocol.bonjourType)
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isListening = true
                        self.statusText = "Listening as \(self.deviceName)"
                    case .failed(let error):
                        self.isListening = false
                        self.statusText = "Listener failed: \(error.localizedDescription)"
                    case .cancelled:
                        self.isListening = false
                        self.statusText = "Stopped"
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
            requestNotificationPermission()
        } catch {
            statusText = "Could not start: \(error.localizedDescription)"
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.connection?.cancel()
            self.connection = nil
            self.connectionAuthorized = false
            self.readBuffer = Data()
            self.listener?.cancel()
            self.listener = nil
            DispatchQueue.main.async {
                self.isListening = false
                self.statusText = "Stopped"
                self.clientLabel = "No phone connected"
                Task { @MainActor in
                    self.player.handle(command: ["cmd": "stop"])
                }
            }
        }
    }

    func disconnectClient() {
        queue.async { [weak self] in
            guard let self else { return }
            let connection = self.connection
            self.connectionAuthorized = false
            self.connection = nil
            self.readBuffer = Data()
            // Prefer an orderly pause with the real position before cancelling the socket.
            // Never send position 0 here — that wiped phone SQLite progress on disconnect.
            DispatchQueue.main.async {
                let position = self.player.currentPositionSeconds
                self.queue.async {
                    if let connection, let data = CastProtocol.encodeLine([
                        "v": CastProtocol.version,
                        "type": "pause",
                        "position": position,
                        "paused": true,
                    ]) {
                        connection.send(content: data, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    } else {
                        connection?.cancel()
                    }
                }
                self.clientLabel = "No phone connected"
                Task { @MainActor in
                    self.player.handle(command: ["cmd": "stop"])
                }
            }
        }
    }

    // MARK: - Connections

    private func handleNewConnection(_ newConnection: NWConnection) {
        // Replace any existing client — personal use, one phone.
        if let existing = connection {
            existing.cancel()
        }
        connection = newConnection
        connectionAuthorized = false
        readBuffer = Data()
        newConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async {
                    self.clientLabel = "Phone connecting…"
                }
                self.sendHello(to: newConnection)
                self.receive(on: newConnection)
            case .failed, .cancelled:
                self.handleConnectionEnded(newConnection, reason: "\(state)")
            default:
                break
            }
        }
        newConnection.start(queue: queue)
    }

    private func handleConnectionEnded(_ ended: NWConnection, reason: String) {
        // Only clear if this is still the active connection (ignore stale cancels).
        guard connection === ended else { return }
        connection = nil
        connectionAuthorized = false
        readBuffer = Data()
        DispatchQueue.main.async {
            self.clientLabel = "No phone connected"
            // Exclusive sink: never keep Mac audio going without a phone controller.
            Task { @MainActor in
                self.player.handle(command: ["cmd": "stop"])
            }
        }
        _ = reason
    }

    private func sendHello(to connection: NWConnection) {
        let tokens = allowedTokens()
        send([
            "v": CastProtocol.version,
            "type": "hello",
            "name": deviceName,
            "tokenRequired": !tokens.isEmpty,
        ], to: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            // Ignore receives for superseded connections.
            guard self.connection === connection else { return }

            if let data, !data.isEmpty {
                self.readBuffer.append(data)
                let messages = CastProtocol.parseLines(from: &self.readBuffer)
                for message in messages {
                    self.handleMessage(message, from: connection)
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                self.handleConnectionEnded(connection, reason: isComplete ? "closed" : "error")
                return
            }
            self.receive(on: connection)
        }
    }

    private func handleMessage(_ body: [String: Any], from connection: NWConnection) {
        if let cmd = body["cmd"] as? String {
            switch cmd {
            case "auth":
                handleAuth(body, from: connection)
            case "load", "play", "pause", "seek", "rate", "stop", "ping":
                guard isAuthorized(connection: connection, body: body) else {
                    promptAndPair(connection: connection)
                    return
                }
                DispatchQueue.main.async {
                    self.clientLabel = "Phone connected"
                    Task { @MainActor in
                        self.player.handle(command: body)
                    }
                }
            default:
                break
            }
            return
        }
    }

    private func handleAuth(_ body: [String: Any], from connection: NWConnection) {
        let token = body["token"] as? String ?? ""
        let allowed = allowedTokens()
        if allowed.isEmpty {
            // First-time: accept and register this token (or mint one).
            let finalToken = token.isEmpty ? UUID().uuidString : token
            completePairing(token: finalToken, connection: connection, label: "Phone paired")
            notify(title: "Pods Speaker", body: "iPhone paired. Ready to play.")
            return
        }
        if allowed.contains(token) {
            completePairing(token: token, connection: connection, label: "Phone connected")
            return
        }
        // Unknown token — ask user to allow (re-pair).
        promptAndPair(connection: connection, suggestedToken: token.isEmpty ? UUID().uuidString : token)
    }

    private func isAuthorized(connection: NWConnection, body: [String: Any]) -> Bool {
        if connectionAuthorized, connection === self.connection {
            return true
        }
        let allowed = allowedTokens()
        if let token = body["token"] as? String, allowed.contains(token) {
            connectionAuthorized = true
            return true
        }
        return false
    }

    private func completePairing(token: String, connection: NWConnection, label: String) {
        addAllowedToken(token)
        // Only authorize if this connection is still current.
        if self.connection === connection {
            connectionAuthorized = true
        }
        send([
            "v": CastProtocol.version,
            "type": "paired",
            "token": token,
            "name": deviceName,
        ], to: connection)
        DispatchQueue.main.async {
            self.clientLabel = label
        }
    }

    private func promptAndPair(connection: NWConnection, suggestedToken: String = UUID().uuidString) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Allow Pods on iPhone?"
            alert.informativeText = "A phone wants to play podcasts through this Mac. Only allow if this is your device."
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Deny")
            let response = alert.runModal()
            self.queue.async {
                if response == .alertFirstButtonReturn {
                    self.completePairing(token: suggestedToken, connection: connection, label: "Phone paired")
                    self.notify(title: "Pods Speaker", body: "iPhone paired. Ready to play.")
                } else {
                    self.send([
                        "v": CastProtocol.version,
                        "type": "error",
                        "message": "pairing denied",
                    ], to: connection)
                    connection.cancel()
                }
            }
        }
    }

    // MARK: - Persistence

    private func allowedTokens() -> Set<String> {
        let arr = UserDefaults.standard.stringArray(forKey: CastProtocol.allowedTokensDefaultsKey) ?? []
        return Set(arr)
    }

    private func addAllowedToken(_ token: String) {
        var set = allowedTokens()
        set.insert(token)
        UserDefaults.standard.set(Array(set), forKey: CastProtocol.allowedTokensDefaultsKey)
    }

    // MARK: - Send / notify

    private func send(_ object: [String: Any], to connection: NWConnection?) {
        guard let connection, let data = CastProtocol.encodeLine(object) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
