import Foundation

public enum DownloadStatus: String, Codable, Sendable, CaseIterable {
    /// Waiting for a free slot (either "start now" or the main queue).
    case queued
    case connecting
    case downloading
    case paused
    /// Merging or remuxing after the transfer finished (video streams).
    case processing
    case completed
    case failed

    public var isRunning: Bool {
        switch self {
        case .connecting, .downloading, .processing: return true
        default: return false
        }
    }
}

public enum DownloadKind: String, Codable, Sendable {
    case http
    case hls
}

/// A byte range of the target file fetched by one connection.
public struct Segment: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var start: Int64
    /// Inclusive end offset, or -1 while the length of the stream is unknown.
    public var end: Int64
    public var received: Int64

    public init(id: Int, start: Int64, end: Int64, received: Int64 = 0) {
        self.id = id
        self.start = start
        self.end = end
        self.received = received
    }

    public var position: Int64 { start + received }
    public var length: Int64? { end >= 0 ? end - start + 1 : nil }
    public var remaining: Int64 { end >= 0 ? max(0, end - start + 1 - received) : .max }
    public var isComplete: Bool { end >= 0 && received >= end - start + 1 }
}

/// Everything about a download that is persisted between launches.
public struct DownloadRecord: Codable, Sendable, Identifiable, Equatable {
    public var id = UUID()
    public var url: URL
    public var kind: DownloadKind = .http
    public var fileName: String
    /// True while the name was derived from the URL and may be replaced by the server's suggestion.
    public var autoName = false
    public var directory: URL
    public var category = FileCategory.generalID
    public var status: DownloadStatus = .paused
    public var totalBytes: Int64 = -1
    public var receivedBytes: Int64 = 0
    public var segments: [Segment] = []
    public var resumable = false
    public var maxConnections = 8
    public var etag: String?
    public var lastModified: String?
    public var mimeType: String?
    public var referrer: String?
    public var cookies: String?
    public var userAgent: String?
    /// The password for this user lives in the Keychain.
    public var username: String?
    public var speedLimitKBps: Int?
    public var hlsVariantURL: URL?
    public var hlsAudioURL: URL?
    /// "Start now" items run as soon as a slot is free; plain queued items wait for the queue.
    public var startWhenPossible = false
    public var queuePosition = 0
    public var dateAdded = Date()
    public var dateCompleted: Date?
    public var lastError: String?
    /// Page title or link text the download came from.
    public var note: String?

    public init(url: URL, fileName: String, directory: URL) {
        self.url = url
        self.fileName = fileName
        self.directory = directory
    }

    public var fileURL: URL { directory.appendingPathComponent(fileName) }
    public var partURL: URL { directory.appendingPathComponent(fileName + FileUtils.partSuffix) }
    public var hlsWorkDirectory: URL { directory.appendingPathComponent("." + fileName + ".sdmhls", isDirectory: true) }

    /// Value for `If-Range` so a resumed download notices when the file changed on the server.
    public var validator: String? {
        if let etag, !etag.hasPrefix("W/") { return etag }
        return lastModified
    }
}

public struct FileCategory: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var symbol: String
    public var extensions: [String]
    /// Custom save folder; nil means the default download folder.
    public var folder: String?

    public init(id: String, name: String, symbol: String, extensions: [String], folder: String? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.extensions = extensions
        self.folder = folder
    }

    public static let generalID = "general"

    public static let defaults: [FileCategory] = [
        FileCategory(id: "compressed", name: "Compressed", symbol: "doc.zipper",
                     extensions: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "lz", "lzh", "arj", "z", "sit", "sitx", "sea", "ace", "cab"]),
        FileCategory(id: "documents", name: "Documents", symbol: "doc.richtext",
                     extensions: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pps", "odt", "ods", "odp", "rtf", "txt", "csv", "epub", "pages", "numbers", "key"]),
        FileCategory(id: "music", name: "Music", symbol: "music.note",
                     extensions: ["mp3", "m4a", "aac", "wav", "flac", "ogg", "oga", "opus", "wma", "aif", "aiff", "mpa", "ra"]),
        FileCategory(id: "programs", name: "Programs", symbol: "app.badge",
                     extensions: ["dmg", "pkg", "mpkg", "iso", "img", "bin", "exe", "msi", "apk", "deb", "rpm", "appimage", "jar"]),
        FileCategory(id: "video", name: "Video", symbol: "film",
                     extensions: ["mp4", "m4v", "mkv", "mov", "avi", "wmv", "webm", "flv", "3gp", "mpg", "mpeg", "mpe", "ogv", "ts", "m3u8", "rm", "rmvb", "asf", "qt"]),
        FileCategory(id: generalID, name: "General", symbol: "doc", extensions: []),
    ]

    public static func detect(fileName: String, in categories: [FileCategory]) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return generalID }
        return categories.first { $0.extensions.contains(ext) }?.id ?? generalID
    }
}

/// Default list of extensions the browser extension and clipboard monitor hand to the app.
public let defaultCaptureExtensions: [String] = [
    "3gp", "7z", "aac", "ace", "aif", "aiff", "apk", "arj", "asf", "avi", "bin", "bz2", "dmg", "epub", "exe", "flac",
    "flv", "gz", "gzip", "img", "iso", "jar", "lzh", "m4a", "m4v", "mkv", "mov", "mp3", "mp4", "mpa", "mpe", "mpeg",
    "mpg", "msi", "msu", "ogg", "ogv", "opus", "pkg", "mpkg", "qt", "ra", "rar", "rm", "rmvb", "sea", "sit", "sitx",
    "tar", "tgz", "tif", "tiff", "wav", "webm", "wma", "wmv", "xz", "z", "zip", "zst",
]

public enum DownloadError: Error, LocalizedError, Equatable, Sendable {
    case http(Int)
    case invalidResponse
    case incomplete
    case fileChanged
    case io(String)
    case unsupported(String)
    case tooManyRetries(String)
    case notEnoughSpace

    public var errorDescription: String? {
        switch self {
        case .http(let code):
            let reason = HTTPURLResponse.localizedString(forStatusCode: code).capitalized
            return "The server responded with HTTP \(code) (\(reason))."
        case .invalidResponse: return "The server sent an unexpected response."
        case .incomplete: return "The connection closed before all data arrived."
        case .fileChanged: return "The file changed on the server. Restart the download."
        case .io(let message): return "Disk error: \(message)"
        case .unsupported(let message): return message
        case .tooManyRetries(let message): return "Gave up after repeated errors. \(message)"
        case .notEnoughSpace: return "There isn't enough free disk space for this file."
        }
    }
}
