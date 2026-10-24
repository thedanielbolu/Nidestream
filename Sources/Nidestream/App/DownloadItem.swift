import Foundation
import Observation
import NidestreamCore

/// Observable wrapper around a persisted record plus live transfer state.
@MainActor @Observable
final class DownloadItem: Identifiable {
    let id: UUID
    var record: DownloadRecord
    /// Smoothed bytes per second.
    var speed: Double = 0
    var activeSegments: [Int] = []
    var parts: (done: Int, total: Int)?

    @ObservationIgnored var lastTick: (time: TimeInterval, bytes: Int64)?

    init(record: DownloadRecord) {
        id = record.id
        self.record = record
    }

    var status: DownloadStatus { record.status }

    var progress: Double {
        if record.status == .completed { return 1 }
        if let parts, parts.total > 0 { return Double(parts.done) / Double(parts.total) }
        guard record.totalBytes > 0 else { return 0 }
        return min(1, Double(record.receivedBytes) / Double(record.totalBytes))
    }

    var eta: TimeInterval? {
        guard record.status == .downloading, speed > 1, record.totalBytes > 0 else { return nil }
        return Double(max(0, record.totalBytes - record.receivedBytes)) / speed
    }

    /// Sort keys for the table.
    var statusRank: Int { DownloadStatus.allCases.firstIndex(of: record.status) ?? 0 }
    var etaRank: Double { eta ?? .greatestFiniteMagnitude }

    var statusText: String {
        switch record.status {
        case .queued: return record.startWhenPossible ? "Waiting" : "Queued"
        case .connecting: return "Connecting…"
        case .downloading:
            if let parts { return "Downloading \(parts.done)/\(parts.total)" }
            return "Downloading"
        case .paused: return "Paused"
        case .processing: return "Merging…"
        case .completed: return "Complete"
        case .failed: return "Error"
        }
    }

    var sizeText: String {
        if record.totalBytes < 0 { return record.receivedBytes > 0 ? Fmt.bytes(record.receivedBytes) : "—" }
        let size = Fmt.bytes(record.totalBytes)
        return record.kind == .hls && record.status != .completed ? "~" + size : size
    }
}

enum Fmt {
    static func bytes(_ count: Int64) -> String {
        count < 0 ? "—" : ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 1 ? "" : ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        return formatter
    }()

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds < 60 * 60 * 24 * 30 else { return "∞" }
        return durationFormatter.string(from: max(1, seconds)) ?? ""
    }
}
