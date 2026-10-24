import Foundation
import UniformTypeIdentifiers

public enum HTTPHeaderParsing {
    public struct ContentRange: Equatable, Sendable {
        public var start: Int64
        public var end: Int64
        public var total: Int64?
    }

    /// Parses `bytes 0-499/1234` and `bytes 0-499/*`.
    public static func contentRange(_ value: String) -> ContentRange? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes") else { return nil }
        let rest = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        let parts = rest.split(separator: "/", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        let bounds = parts[0].split(separator: "-", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), end >= start else { return nil }
        return ContentRange(start: start, end: end, total: Int64(parts[1]))
    }

    /// Extracts the file name from a `Content-Disposition` header, preferring the RFC 5987 `filename*` form.
    public static func fileName(fromContentDisposition header: String) -> String? {
        if let match = firstMatch(#"filename\*\s*=\s*([\w!#$%&+^`{}~.-]*)'[^']*'([^;\s]+)"#, in: header) {
            let charset = match[0].lowercased()
            let raw = match[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if let decoded = percentDecode(raw, encoding: charset == "iso-8859-1" ? .isoLatin1 : .utf8), !decoded.isEmpty {
                return decoded
            }
        }
        if let match = firstMatch(#"filename\s*=\s*"((?:\\.|[^"\\])*)""#, in: header) {
            let unescaped = match[0].replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
            return repairMojibake(unescaped)
        }
        if let match = firstMatch(#"filename\s*=\s*([^;]+)"#, in: header) {
            let value = match[0].trimmingCharacters(in: .whitespaces)
            if value.contains("%"), let decoded = percentDecode(value, encoding: .utf8) { return decoded }
            return repairMojibake(value)
        }
        return nil
    }

    /// Makes a server- or user-supplied name safe to use as a single path component.
    public static func sanitizeFileName(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) {
            scalars.append(scalar == "/" || scalar == ":" ? "_" : scalar)
        }
        var result = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix(".") { result.removeFirst() }
        if result.isEmpty { return "download" }
        if result.utf8.count > 240 {
            let ext = (result as NSString).pathExtension
            var base = (result as NSString).deletingPathExtension
            while base.utf8.count + ext.utf8.count + 1 > 240, !base.isEmpty { base.removeLast() }
            result = ext.isEmpty ? base : base + "." + ext
        }
        return result
    }

    private static let scriptExtensions: Set<String> = ["php", "asp", "aspx", "jsp", "cgi", "pl", "do", "action", "ashx"]

    public static func suggestedFileName(url: URL, contentDisposition: String?, mimeType: String?) -> String {
        var name = contentDisposition.flatMap(fileName(fromContentDisposition:))
        if name?.isEmpty ?? true {
            let last = url.lastPathComponent
            if !last.isEmpty && last != "/" { name = last }
        }
        var result = sanitizeFileName(name ?? "download")
        let mime = mimeType?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let ext = (result as NSString).pathExtension.lowercased()
        if let mime, mime != "application/octet-stream", mime != "text/html",
           ext.isEmpty || scriptExtensions.contains(ext),
           let preferred = UTType(mimeType: mime)?.preferredFilenameExtension {
            if !ext.isEmpty { result = (result as NSString).deletingPathExtension }
            result += "." + preferred
        }
        return result
    }

    // MARK: - Helpers

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
    }

    static func percentDecode(_ text: String, encoding: String.Encoding) -> String? {
        var bytes: [UInt8] = []
        var iterator = Array(text.utf8).makeIterator()
        while let byte = iterator.next() {
            if byte == UInt8(ascii: "%"), let high = iterator.next(), let low = iterator.next(),
               let value = UInt8(String(bytes: [high, low], encoding: .ascii) ?? "", radix: 16) {
                bytes.append(value)
            } else {
                bytes.append(byte)
            }
        }
        return String(bytes: bytes, encoding: encoding)
    }

    /// Servers often send raw UTF-8 in `filename=`, which arrives decoded as Latin-1.
    static func repairMojibake(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard scalars.allSatisfy({ $0.value <= 0xFF }), scalars.contains(where: { $0.value >= 0x80 }) else { return text }
        let bytes = scalars.map { UInt8($0.value) }
        return String(bytes: bytes, encoding: .utf8) ?? text
    }
}
