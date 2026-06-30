import OSLog

private let podsLogger = Logger(subsystem: "dev.mcgiv.pods", category: "app")

func PodsLog(_ message: String) {
    podsLogger.notice("\(message, privacy: .public)")
}
