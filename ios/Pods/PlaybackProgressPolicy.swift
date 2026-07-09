import Foundation

/// Pure rules for when cast/local playback position should hit SQLite.
///
/// Cast progress historically failed in two ways:
/// 1. Phone suspended while Mac played (no local audio → iOS suspends despite `audio` background mode).
/// 2. Mac stop / pre-seek clocks reported `0`/`NaN`, which force-wrote over real progress.
enum PlaybackProgressPolicy {
    /// Whether a candidate position should be persisted for the current episode.
    static func shouldPersist(
        position: Double,
        lastRecordedPosition: Double?,
        force: Bool,
        allowRegress: Bool,
        strideSeconds: Double
    ) -> Bool {
        guard position.isFinite, position >= 0 else {
            return false
        }
        if let last = lastRecordedPosition, last.isFinite {
            // Automatic transport must never wipe progress with glitch zeros or brief rewinds.
            if !allowRegress, position + 1 < last {
                return false
            }
            if !force, abs(position - last) < strideSeconds {
                return false
            }
        }
        return true
    }

    /// Keep a silent local audio session alive while Mac is the chosen sink so iOS does not suspend
    /// the process (which would stop receiving cast timeupdates and stop writing progress).
    static func shouldRunCastKeepAlive(preferredOutputIsMac: Bool) -> Bool {
        preferredOutputIsMac
    }

    /// Prefer a known-good position over invalid / zero clocks when we already advanced.
    static func resolvedTransportPosition(candidate: Double, lastKnown: Double) -> Double {
        let known = lastKnown.isFinite ? max(0, lastKnown) : 0
        guard candidate.isFinite else {
            return known
        }
        let safe = max(0, candidate)
        // Treat a sudden drop to ~0 as a teardown glitch when we already have real progress.
        if safe < 1, known > 1 {
            return known
        }
        return safe
    }

    /// Tiny looping silent PCM WAV used only to hold the audio background mode while casting.
    static func silentKeepAliveWavData(sampleRate: Int = 8_000, durationSeconds: Double = 1) -> Data {
        let rate = max(8_000, sampleRate)
        let frames = max(rate / 10, Int(Double(rate) * durationSeconds))
        let dataSize = frames * 2 // 16-bit mono
        let riffSize = 36 + dataSize
        var data = Data()
        data.reserveCapacity(44 + dataSize)

        func appendASCII(_ s: String) {
            data.append(contentsOf: s.utf8)
        }
        func appendUInt16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendUInt32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendUInt32(UInt32(riffSize))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16) // PCM chunk size
        appendUInt16(1) // PCM format
        appendUInt16(1) // mono
        appendUInt32(UInt32(rate))
        appendUInt32(UInt32(rate * 2)) // byte rate
        appendUInt16(2) // block align
        appendUInt16(16) // bits per sample
        appendASCII("data")
        appendUInt32(UInt32(dataSize))
        data.append(Data(count: dataSize)) // silence
        return data
    }
}
