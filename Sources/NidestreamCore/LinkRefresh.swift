import Foundation

/// Continuing a download from a newer link, like IDM's "refresh download address":
/// download links often expire, so the user grabs a fresh one and the download carries on
/// from where it stopped instead of starting over.
public enum LinkRefresh {
    /// Whether a freshly checked link serves the same file as an unfinished download, so that
    /// download can continue from it. The size must match exactly and the server must accept
    /// byte ranges; the name must match too, ignoring the " (1)" that duplicates get.
    public static func isSameFile(_ record: DownloadRecord, as probe: ProbeResult) -> Bool {
        guard record.status != .completed, record.kind == .http, !probe.isHLS else { return false }
        guard record.totalBytes > 0, probe.totalBytes == record.totalBytes, probe.acceptsRanges else { return false }
        return baseName(record.fileName) == baseName(probe.fileName)
    }

    /// The download pointed at the new link. Progress is kept; the old server's fingerprint
    /// (ETag / Last-Modified) is replaced, because a different server or CDN node reports its own
    /// and sending the old one in `If-Range` would make the server resend the whole file.
    public static func refreshed(_ record: DownloadRecord, with probe: ProbeResult, url: URL) -> DownloadRecord {
        var updated = record
        updated.url = url
        updated.etag = probe.etag
        updated.lastModified = probe.lastModified
        updated.mimeType = probe.mimeType ?? record.mimeType
        updated.resumable = true
        updated.lastError = nil
        return updated
    }

    /// Lowercased file name without a trailing " (n)" before the extension.
    static func baseName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        var base = (name as NSString).deletingPathExtension
        if let range = base.range(of: #" \(\d+\)$"#, options: .regularExpression) { base.removeSubrange(range) }
        return (ext.isEmpty ? base : base + "." + ext).lowercased()
    }
}
