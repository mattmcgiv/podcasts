import Foundation

/// Uses the same authenticated speaker API as the browser player.
struct MacSpeaker {
    struct Status: Decodable {
        let available: Bool
        let connected: Bool
        let error: String?
        let episode_id: Int?
        let artifact_hash: String?
        let position: Double
        let duration: Double
        let rate: Double
        let paused: Bool
        let ended: Bool
        let session_id: String?
        let generation: UInt64

        func belongs(to session: String, episode: Episode) -> Bool {
            connected && session_id == session && episode_id == episode.id && artifact_hash == episode.manifest?.hash
        }
    }

    enum Command: String {
        case play, pause, seek, rate, disconnect
    }

    private struct Payload: Encodable {
        let session_id: String
        let generation: UInt64
        var episode_id: Int?
        var artifact_hash: String?
        var position: Double?
        var rate: Double?
        var seconds: Double?
    }

    private let client = MacClient.shared
    private let sessionID = UUID().uuidString

    func status() async throws -> Status {
        try await client.json(Status.self, "/speaker/status", timeout: 5)
    }

    func owns(_ status: Status, episode: Episode) -> Bool {
        status.belongs(to: sessionID, episode: episode)
    }

    func load(_ episode: Episode, generation: UInt64, position: Double, rate: Double) async throws -> Status {
        guard let hash = episode.manifest?.hash else {
            throw SyncError.message("This episode has no audio available on the Mac.")
        }
        // The API loads paused by default. A lost response cannot start competing audio.
        return try await send("load", Payload(session_id: sessionID, generation: generation,
                                              episode_id: episode.id, artifact_hash: hash, position: position, rate: rate))
    }

    func command(_ command: Command, generation: UInt64, value: Double? = nil) async throws -> Status {
        try await send(command.rawValue, Payload(session_id: sessionID, generation: generation,
                                                 rate: command == .rate ? value : nil,
                                                 seconds: command == .seek ? value : nil))
    }

    private func send(_ path: String, _ payload: Payload) async throws -> Status {
        try await client.json(Status.self, "/speaker/\(path)", method: "POST", body: JSONEncoder().encode(payload))
    }
}
