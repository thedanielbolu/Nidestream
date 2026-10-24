import Foundation

public struct ExtractedLink: Hashable, Sendable {
    public var url: URL
    public var text: String?

    public init(url: URL, text: String? = nil) {
        self.url = url
        self.text = text
    }
}

public enum LinkExtractor {
    private static let anchorRegex = try! NSRegularExpression(
        pattern: #"<a\b[^>]*?\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>(.*?)</a\s*>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let sourceRegex = try! NSRegularExpression(
        pattern: #"\b(?:src|data-src|href)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,
        options: [.caseInsensitive])
    private static let tagRegex = try! NSRegularExpression(pattern: "<[^>]+>")

    /// Finds every http(s) link and media source in an HTML document, anchors first (with their text).
    public static func links(inHTML html: String, baseURL: URL) -> [ExtractedLink] {
        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        var seen = Set<URL>()
        var result: [ExtractedLink] = []

        func add(_ raw: String, text: String?) {
            guard let url = resolve(raw, baseURL), seen.insert(url).inserted else { return }
            result.append(ExtractedLink(url: url, text: text))
        }

        for match in anchorRegex.matches(in: html, range: full) {
            let raw = (1...3).lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound }.map(ns.substring(with:)) ?? ""
            let inner = match.range(at: 4).location == NSNotFound ? "" : ns.substring(with: match.range(at: 4))
            let text = decodeEntities(tagRegex.stringByReplacingMatches(in: inner, range: NSRange(location: 0, length: (inner as NSString).length), withTemplate: ""))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            add(raw, text: text.isEmpty ? nil : text)
        }
        for match in sourceRegex.matches(in: html, range: full) {
            let raw = (1...3).lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound }.map(ns.substring(with:)) ?? ""
            add(raw, text: nil)
        }
        return result
    }

    static func resolve(_ raw: String, _ base: URL) -> URL? {
        let value = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("#") else { return nil }
        let lower = value.lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("mailto:") || lower.hasPrefix("data:") || lower.hasPrefix("tel:") { return nil }
        guard var components = URLComponents(url: URL(string: value, relativeTo: base)?.absoluteURL ?? base, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        components.fragment = nil
        return components.url
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    private static let pageExtensions: Set<String> = ["", "html", "htm", "xhtml", "php", "asp", "aspx", "jsp", "cgi", "shtml"]

    public static func looksLikePage(_ url: URL) -> Bool {
        pageExtensions.contains(url.pathExtension.lowercased())
    }
}

public struct CrawlOptions: Sendable {
    public var startURL: URL
    public var depth: Int
    public var sameHost: Bool
    /// Extensions of files to collect.
    public var extensions: Set<String>
    public var maxPages: Int
    public var headers: [String: String]

    public init(startURL: URL, depth: Int, sameHost: Bool, extensions: Set<String>, maxPages: Int = 300, headers: [String: String] = [:]) {
        self.startURL = startURL
        self.depth = depth
        self.sameHost = sameHost
        self.extensions = extensions
        self.maxPages = maxPages
        self.headers = headers
    }
}

/// Site grabber: walks pages breadth-first and collects links to files with the wanted extensions.
public enum SiteCrawler {
    public static func crawl(_ options: CrawlOptions, progress: @escaping @Sendable (_ pages: Int, _ files: Int) -> Void) async -> [ExtractedLink] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var pending: [(URL, Int)] = [(options.startURL, 0)]
        var visited = Set<URL>()
        var found: [ExtractedLink] = []
        var foundURLs = Set<URL>()
        var pages = 0

        while !pending.isEmpty, pages < options.maxPages, !Task.isCancelled {
            let (url, depth) = pending.removeFirst()
            guard visited.insert(url).inserted, let html = await fetchHTML(url, session: session, headers: options.headers) else { continue }
            pages += 1
            for link in LinkExtractor.links(inHTML: html, baseURL: url) {
                let ext = link.url.pathExtension.lowercased()
                if options.extensions.contains(ext) {
                    if foundURLs.insert(link.url).inserted { found.append(link) }
                } else if depth < options.depth, LinkExtractor.looksLikePage(link.url),
                          !options.sameHost || link.url.host?.lowercased() == options.startURL.host?.lowercased() {
                    pending.append((link.url, depth + 1))
                }
            }
            progress(pages, found.count)
        }
        return found
    }

    private static func fetchHTML(_ url: URL, session: URLSession, headers: [String: String]) async -> String? {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let mime = http.mimeType?.lowercased(), mime.contains("html"), data.count < 8_000_000 else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}

/// IDM-style batch download: `http://site/img*.jpg` with `*` replaced by a number or letter range.
public enum BatchPattern {
    public enum Range: Sendable, Equatable {
        case numbers(from: Int, to: Int, width: Int)
        case letters(from: Character, to: Character)
    }

    public static func expand(_ template: String, range: Range, limit: Int = 10_000) -> [String] {
        guard template.contains("*") else { return [template] }
        var values: [String] = []
        switch range {
        case let .numbers(from, to, width):
            for number in stride(from: from, through: to, by: from <= to ? 1 : -1) {
                let digits = String(abs(number))
                let padded = String(repeating: "0", count: max(0, width - digits.count)) + digits
                values.append(number < 0 ? "-" + padded : padded)
                if values.count >= limit { break }
            }
        case let .letters(from, to):
            guard let start = from.unicodeScalars.first?.value, let end = to.unicodeScalars.first?.value else { return [] }
            for value in stride(from: start, through: end, by: start <= end ? 1 : -1) {
                if let scalar = Unicode.Scalar(value) { values.append(String(Character(scalar))) }
                if values.count >= limit { break }
            }
        }
        return values.map { template.replacingOccurrences(of: "*", with: $0) }
    }
}
