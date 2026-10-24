import Foundation

public struct ProbeResult: Sendable, Equatable {
    public var finalURL: URL
    public var statusCode: Int
    /// -1 when the server didn't say.
    public var totalBytes: Int64
    public var acceptsRanges: Bool
    public var fileName: String
    public var mimeType: String?
    public var etag: String?
    public var lastModified: String?
    public var isHLS: Bool

    public var isWebPage: Bool {
        guard let mimeType else { return false }
        return mimeType.hasPrefix("text/html") || mimeType.hasPrefix("application/xhtml")
    }

    public var validator: String? {
        if let etag, !etag.hasPrefix("W/") { return etag }
        return lastModified
    }
}

/// Asks the server about a file before downloading it: size, name, type and whether byte ranges work.
public enum Prober {
    public static func probe(url: URL, headers: [String: String], credential: URLCredential? = nil,
                             proxy: ProxySettings = .system, timeout: TimeInterval = 20) async throws -> ProbeResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        proxy.apply(to: configuration)
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let delegate = credential.map(CredentialDelegate.init(credential:))
        let ranged = try await request(url: url, headers: headers, range: true, session: session, delegate: delegate, timeout: timeout)
        if ranged.statusCode == 416 {
            // Some servers reject a range on tiny or empty files; ask again for the whole thing.
            return try await request(url: url, headers: headers, range: false, session: session, delegate: delegate, timeout: timeout)
        }
        return ranged
    }

    private static func request(url: URL, headers: [String: String], range: Bool, session: URLSession,
                                delegate: CredentialDelegate?, timeout: TimeInterval) async throws -> ProbeResult {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if range { request.setValue("bytes=0-0", forHTTPHeaderField: "Range") }

        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        bytes.task.cancel()
        guard let http = response as? HTTPURLResponse else { throw DownloadError.invalidResponse }
        if http.statusCode == 416 && range {
            return ProbeResult(finalURL: url, statusCode: 416, totalBytes: -1, acceptsRanges: false, fileName: "",
                               mimeType: nil, etag: nil, lastModified: nil, isHLS: false)
        }
        guard (200..<300).contains(http.statusCode) else { throw DownloadError.http(http.statusCode) }

        var total: Int64 = -1
        var acceptsRanges = false
        if http.statusCode == 206, let contentRange = http.value(forHTTPHeaderField: "Content-Range").flatMap(HTTPHeaderParsing.contentRange) {
            acceptsRanges = true
            total = contentRange.total ?? -1
        } else if http.expectedContentLength >= 0 {
            total = http.expectedContentLength
        }

        let finalURL = http.url ?? url
        let mime = http.mimeType?.lowercased()
        let fileName = HTTPHeaderParsing.suggestedFileName(url: finalURL,
                                                           contentDisposition: http.value(forHTTPHeaderField: "Content-Disposition"),
                                                           mimeType: mime)
        let isHLS = (mime?.contains("mpegurl") ?? false) || finalURL.pathExtension.lowercased() == "m3u8"
        return ProbeResult(finalURL: finalURL, statusCode: http.statusCode, totalBytes: total, acceptsRanges: acceptsRanges,
                           fileName: fileName, mimeType: mime, etag: http.value(forHTTPHeaderField: "ETag"),
                           lastModified: http.value(forHTTPHeaderField: "Last-Modified"), isHLS: isHLS)
    }
}
