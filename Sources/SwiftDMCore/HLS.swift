import CommonCrypto
import Foundation

// MARK: - Playlist model

public struct HLSVariant: Sendable, Hashable, Identifiable {
    public var id: URL { url }
    public var url: URL
    public var bandwidth: Int
    public var resolution: String?
    public var codecs: String?
    public var audioGroup: String?

    public var label: String {
        var parts: [String] = []
        if let resolution, let height = resolution.split(separator: "x").last { parts.append("\(height)p") }
        if bandwidth > 0 { parts.append(String(format: "%.1f Mbps", Double(bandwidth) / 1_000_000)) }
        return parts.isEmpty ? url.lastPathComponent : parts.joined(separator: " · ")
    }
}

public struct HLSRendition: Sendable, Hashable {
    public var type: String
    public var groupID: String
    public var name: String?
    public var language: String?
    public var url: URL?
    public var isDefault: Bool
}

public struct HLSKey: Sendable, Hashable {
    public var method: String
    public var url: URL?
    public var iv: Data?
    public var keyFormat: String?
}

public struct HLSMediaSegment: Sendable, Hashable {
    public var url: URL
    public var duration: Double
    public var sequence: Int
    public var key: HLSKey?
    public var byteRange: ClosedRange<Int64>?
}

public struct HLSMediaPlaylist: Sendable {
    public var segments: [HLSMediaSegment]
    public var initSegment: HLSMediaSegment?
    public var isComplete: Bool
    public var duration: Double { segments.reduce(0) { $0 + $1.duration } }
}

public struct HLSMasterPlaylist: Sendable {
    public var variants: [HLSVariant]
    public var renditions: [HLSRendition]

    /// Separate audio track that goes with `variant`, if the stream keeps audio apart from video.
    public func audio(for variant: HLSVariant) -> URL? {
        guard let group = variant.audioGroup else { return nil }
        let matches = renditions.filter { $0.type == "AUDIO" && $0.groupID == group && $0.url != nil }
        return (matches.first(where: \.isDefault) ?? matches.first)?.url
    }
}

public enum HLSPlaylist: Sendable {
    case master(HLSMasterPlaylist)
    case media(HLSMediaPlaylist)
}

// MARK: - Parser

public enum HLSParser {
    public static func parse(_ text: String, baseURL: URL) throws -> HLSPlaylist {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.first?.hasPrefix("#EXTM3U") == true else {
            throw DownloadError.unsupported("This address isn't an HLS playlist.")
        }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            return .master(parseMaster(lines, baseURL: baseURL))
        }
        return .media(parseMedia(lines, baseURL: baseURL))
    }

    private static func parseMaster(_ lines: [String], baseURL: URL) -> HLSMasterPlaylist {
        var variants: [HLSVariant] = []
        var renditions: [HLSRendition] = []
        var pending: [String: String]?
        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributes(line.dropFirst("#EXT-X-STREAM-INF:".count))
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let attrs = attributes(line.dropFirst("#EXT-X-MEDIA:".count))
                renditions.append(HLSRendition(type: attrs["TYPE"] ?? "", groupID: attrs["GROUP-ID"] ?? "", name: attrs["NAME"],
                                               language: attrs["LANGUAGE"], url: attrs["URI"].flatMap { resolve($0, baseURL) },
                                               isDefault: attrs["DEFAULT"] == "YES"))
            } else if !line.hasPrefix("#"), let attrs = pending {
                if let url = resolve(line, baseURL) {
                    variants.append(HLSVariant(url: url, bandwidth: Int(attrs["BANDWIDTH"] ?? "") ?? 0, resolution: attrs["RESOLUTION"],
                                               codecs: attrs["CODECS"], audioGroup: attrs["AUDIO"]))
                }
                pending = nil
            }
        }
        return HLSMasterPlaylist(variants: variants, renditions: renditions)
    }

    private static func parseMedia(_ lines: [String], baseURL: URL) -> HLSMediaPlaylist {
        var segments: [HLSMediaSegment] = []
        var initSegment: HLSMediaSegment?
        var sequence = 0
        var key: HLSKey?
        var duration = 0.0
        var range: ClosedRange<Int64>?
        var nextOffset: Int64 = 0
        var complete = false

        for line in lines {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1).first ?? ""
                duration = Double(value) ?? 0
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                range = byteRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count)), defaultOffset: nextOffset)
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let attrs = attributes(line.dropFirst("#EXT-X-KEY:".count))
                let method = attrs["METHOD"]?.uppercased() ?? "NONE"
                key = method == "NONE" ? nil : HLSKey(method: method, url: attrs["URI"].flatMap { resolve($0, baseURL) },
                                                     iv: attrs["IV"].flatMap(hexData), keyFormat: attrs["KEYFORMAT"])
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = attributes(line.dropFirst("#EXT-X-MAP:".count))
                if let url = attrs["URI"].flatMap({ resolve($0, baseURL) }) {
                    initSegment = HLSMediaSegment(url: url, duration: 0, sequence: -1, key: nil,
                                                  byteRange: attrs["BYTERANGE"].flatMap { byteRange($0, defaultOffset: 0) })
                }
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                complete = true
            } else if !line.hasPrefix("#"), let url = resolve(line, baseURL) {
                segments.append(HLSMediaSegment(url: url, duration: duration, sequence: sequence, key: key, byteRange: range))
                if let range { nextOffset = range.upperBound + 1 }
                sequence += 1
                duration = 0
                range = nil
            }
        }
        return HLSMediaPlaylist(segments: segments, initSegment: initSegment, isComplete: complete)
    }

    /// Parses `KEY=VALUE,KEY="quoted, value"` attribute lists.
    public static func attributes(_ text: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var index = text.startIndex
        while index < text.endIndex {
            guard let equals = text[index...].firstIndex(of: "=") else { break }
            let name = text[index..<equals].trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            var cursor = text.index(after: equals)
            let value: String
            if cursor < text.endIndex, text[cursor] == "\"" {
                let start = text.index(after: cursor)
                let close = text[start...].firstIndex(of: "\"") ?? text.endIndex
                value = String(text[start..<close])
                cursor = close < text.endIndex ? text.index(after: close) : close
                cursor = text[cursor...].firstIndex(of: ",").map { text.index(after: $0) } ?? text.endIndex
            } else {
                let comma = text[cursor...].firstIndex(of: ",") ?? text.endIndex
                value = text[cursor..<comma].trimmingCharacters(in: .whitespaces)
                cursor = comma < text.endIndex ? text.index(after: comma) : comma
            }
            result[name.uppercased()] = value
            index = cursor
        }
        return result
    }

    private static func resolve(_ reference: String, _ base: URL) -> URL? {
        URL(string: reference, relativeTo: base)?.absoluteURL
    }

    private static func byteRange(_ text: String, defaultOffset: Int64) -> ClosedRange<Int64>? {
        let parts = text.split(separator: "@")
        guard let length = Int64(parts[0]), length > 0 else { return nil }
        let offset = parts.count > 1 ? Int64(parts[1]) ?? defaultOffset : defaultOffset
        return offset...(offset + length - 1)
    }

    static func hexData(_ text: String) -> Data? {
        var hex = text.lowercased()
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

// MARK: - Downloader

public struct HLSJob: Sendable {
    public var playlistURL: URL
    public var variantURL: URL?
    public var audioURL: URL?
    public var headers: [String: String]
    public var workDirectory: URL
    public var concurrency: Int
    public var maxRetries: Int
    public var timeout: TimeInterval
    public var proxy: ProxySettings
    /// When set, finished tracks are remuxed (and audio/video merged) into an .mp4.
    public var ffmpegPath: String?

    public init(playlistURL: URL, variantURL: URL? = nil, audioURL: URL? = nil, headers: [String: String] = [:],
                workDirectory: URL, concurrency: Int = 6, maxRetries: Int = 6, timeout: TimeInterval = 30,
                proxy: ProxySettings = .system, ffmpegPath: String? = nil) {
        self.playlistURL = playlistURL
        self.variantURL = variantURL
        self.audioURL = audioURL
        self.headers = headers
        self.workDirectory = workDirectory
        self.concurrency = concurrency
        self.maxRetries = maxRetries
        self.timeout = timeout
        self.proxy = proxy
        self.ffmpegPath = ffmpegPath
    }
}

/// Downloads an on-demand HLS stream (plain or AES-128) segment by segment, resumable at segment granularity.
public final class HLSDownloader: DownloadRunner, @unchecked Sendable {
    private struct Track {
        let name: String
        let playlist: HLSMediaPlaylist
        let directory: URL
        let fileExtension: String

        var parts: [HLSMediaSegment] { (playlist.initSegment.map { [$0] } ?? []) + playlist.segments }
    }

    private let job: HLSJob
    private let limiters: [RateLimiter]
    private let onEvent: @Sendable (RunnerEvent) -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var bytes: Int64 = 0
    private var partsDone = 0
    private var partsTotal = 0
    private var inFlight = 0
    private var finished = false
    private var keys: [URL: Data] = [:]

    public init(job: HLSJob, limiters: [RateLimiter], onEvent: @escaping @Sendable (RunnerEvent) -> Void) {
        self.job = job
        self.limiters = limiters
        self.onEvent = onEvent
    }

    public func start() {
        task = Task.detached { [self] in await run() }
    }

    public func stop() {
        task?.cancel()
    }

    private func run() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = job.timeout
        configuration.httpMaximumConnectionsPerHost = max(2, job.concurrency)
        job.proxy.apply(to: configuration)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                self.onEvent(.progress(self.snapshot()))
            }
        }
        defer { ticker.cancel() }

        do {
            try FileManager.default.createDirectory(at: job.workDirectory, withIntermediateDirectories: true)
            let tracks = try await resolveTracks(session)
            lock.withLock { partsTotal = tracks.reduce(0) { $0 + $1.parts.count } }
            for track in tracks { try await download(track, session: session) }
            try Task.checkCancellation()
            ticker.cancel()
            onEvent(.processing)
            let outputs = try assemble(tracks)
            finish(.completed(outputs: outputs))
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
                finish(.stopped)
            } else {
                finish(.failed(describe(error)))
            }
        }
    }

    private func finish(_ result: RunnerResult) {
        let alreadyFinished = lock.withLock { () -> Bool in
            defer { finished = true }
            return finished
        }
        guard !alreadyFinished else { return }
        onEvent(.finished(result, snapshot()))
    }

    private func snapshot() -> DownloadProgress {
        lock.withLock {
            let estimate = partsDone > 0 ? bytes * Int64(partsTotal) / Int64(partsDone) : -1
            let total = partsDone == partsTotal && partsTotal > 0 ? bytes : estimate
            return DownloadProgress(receivedBytes: bytes, totalBytes: total, segments: nil,
                                    activeSegments: Array(0..<inFlight), resumable: true,
                                    partsDone: partsDone, partsTotal: partsTotal)
        }
    }

    // MARK: Playlists

    private func resolveTracks(_ session: URLSession) async throws -> [Track] {
        var mediaURL = job.variantURL ?? job.playlistURL
        var audioURL = job.audioURL
        var playlist = try await fetchPlaylist(mediaURL, session)
        if case .master(let master) = playlist {
            guard let best = master.variants.max(by: { $0.bandwidth < $1.bandwidth }) else {
                throw DownloadError.unsupported("The playlist doesn't list any video streams.")
            }
            mediaURL = best.url
            if audioURL == nil { audioURL = master.audio(for: best) }
            playlist = try await fetchPlaylist(mediaURL, session)
        }
        guard case .media(let video) = playlist else { throw DownloadError.unsupported("Unexpected nested HLS playlist.") }
        var tracks = [try makeTrack("video", video)]
        if let audioURL, audioURL != mediaURL, case .media(let audio) = try await fetchPlaylist(audioURL, session) {
            tracks.append(try makeTrack("audio", audio))
        }
        return tracks
    }

    private func makeTrack(_ name: String, _ playlist: HLSMediaPlaylist) throws -> Track {
        guard playlist.isComplete else {
            throw DownloadError.unsupported("This is a live stream. Only on-demand videos can be downloaded.")
        }
        guard !playlist.segments.isEmpty else { throw DownloadError.unsupported("The stream has no segments.") }
        for key in Set(playlist.segments.compactMap(\.key)) {
            let plainAES = key.method == "AES-128" && (key.keyFormat == nil || key.keyFormat == "identity")
            if !plainAES { throw DownloadError.unsupported("This stream is DRM-protected and can't be downloaded.") }
        }
        let ext: String
        if playlist.initSegment != nil {
            ext = name == "audio" ? "m4a" : "mp4"
        } else {
            switch playlist.segments[0].url.pathExtension.lowercased() {
            case "aac": ext = "aac"
            case "mp4", "m4s", "m4v": ext = "mp4"
            case "m4a": ext = "m4a"
            default: ext = "ts"
            }
        }
        return Track(name: name, playlist: playlist, directory: job.workDirectory.appendingPathComponent(name, isDirectory: true),
                     fileExtension: ext)
    }

    private func fetchPlaylist(_ url: URL, _ session: URLSession) async throws -> HLSPlaylist {
        let (data, response) = try await session.data(for: request(url))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw DownloadError.http(http.statusCode) }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return try HLSParser.parse(text, baseURL: response.url ?? url)
    }

    private func request(_ url: URL, range: ClosedRange<Int64>? = nil) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: job.timeout)
        for (name, value) in job.headers { request.setValue(value, forHTTPHeaderField: name) }
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
        return request
    }

    // MARK: Segments

    private func partURL(_ track: Track, _ index: Int) -> URL {
        track.directory.appendingPathComponent(String(format: "%06d.seg", index))
    }

    private func download(_ track: Track, session: URLSession) async throws {
        try FileManager.default.createDirectory(at: track.directory, withIntermediateDirectories: true)
        let parts = Array(track.parts.enumerated())
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = parts.makeIterator()
            func addNext() {
                guard let (index, part) = iterator.next() else { return }
                group.addTask { try await self.fetch(part, to: self.partURL(track, index), session: session) }
            }
            for _ in 0..<max(1, job.concurrency) { addNext() }
            while try await group.next() != nil { addNext() }
        }
    }

    private func fetch(_ part: HLSMediaSegment, to destination: URL, session: URLSession) async throws {
        if let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 {
            lock.withLock {
                bytes += Int64(size)
                partsDone += 1
            }
            return
        }
        lock.withLock { inFlight += 1 }
        defer { lock.withLock { inFlight -= 1 } }

        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request(part.url, range: part.byteRange))
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw DownloadError.http(http.statusCode)
                }
                var payload = data
                if let key = part.key, key.method == "AES-128", let keyURL = key.url {
                    let keyData = try await self.key(keyURL, session: session)
                    payload = try Self.decryptAES128(data, key: keyData, iv: key.iv ?? Self.iv(for: part.sequence))
                }
                let temporary = destination.appendingPathExtension("tmp")
                try payload.write(to: temporary)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                lock.withLock {
                    bytes += Int64(payload.count)
                    partsDone += 1
                }
                let delay = limiters.map { $0.consume(data.count) }.max() ?? 0
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                return
            } catch {
                attempt += 1
                guard isRetryable(error), attempt <= job.maxRetries, !Task.isCancelled else { throw error }
                try await Task.sleep(for: .seconds(min(20, pow(2, Double(attempt - 1)))))
            }
        }
    }

    private func key(_ url: URL, session: URLSession) async throws -> Data {
        if let cached = lock.withLock({ keys[url] }) { return cached }
        let (data, response) = try await session.data(for: request(url))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw DownloadError.http(http.statusCode) }
        guard data.count == 16 else { throw DownloadError.unsupported("The stream's decryption key is invalid.") }
        lock.withLock { keys[url] = data }
        return data
    }

    static func iv(for sequence: Int) -> Data {
        var data = Data(count: 16)
        var value = UInt64(max(0, sequence)).bigEndian
        withUnsafeBytes(of: &value) { data.replaceSubrange(8..<16, with: $0) }
        return data
    }

    static func decryptAES128(_ data: Data, key: Data, iv: Data) throws -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress, input.baseAddress, data.count,
                                out.baseAddress, outputCapacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw DownloadError.unsupported("Couldn't decrypt a stream segment.") }
        output.count = moved
        return output
    }

    // MARK: Assembly

    private func assemble(_ tracks: [Track]) throws -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        for track in tracks {
            let output = job.workDirectory.appendingPathComponent("\(track.name).\(track.fileExtension)")
            fm.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            for index in track.parts.indices {
                try handle.write(contentsOf: try Data(contentsOf: partURL(track, index), options: .mappedIfSafe))
            }
            files.append(output)
        }

        if let ffmpeg = job.ffmpegPath {
            let merged = job.workDirectory.appendingPathComponent("merged.mp4")
            var arguments = ["-y", "-loglevel", "error"]
            for file in files { arguments += ["-i", file.path] }
            if files.count > 1 { arguments += ["-map", "0:v:0", "-map", "1:a:0"] }
            arguments += ["-c", "copy", "-movflags", "+faststart", merged.path]
            if Self.run(ffmpeg, arguments) == 0, fm.fileExists(atPath: merged.path) {
                for file in files { try? fm.removeItem(at: file) }
                files = [merged]
            }
        }
        for track in tracks { try? fm.removeItem(at: track.directory) }
        return files
    }

    private static func run(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
