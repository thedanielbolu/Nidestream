import Foundation
import Testing
@testable import NidestreamCore

@Suite struct HeaderParsingTests {
    @Test func contentRange() {
        #expect(HTTPHeaderParsing.contentRange("bytes 0-0/1234") == .init(start: 0, end: 0, total: 1234))
        #expect(HTTPHeaderParsing.contentRange("bytes 100-199/*") == .init(start: 100, end: 199, total: nil))
        #expect(HTTPHeaderParsing.contentRange("bytes */1234") == nil)
        #expect(HTTPHeaderParsing.contentRange("items 0-1/2") == nil)
    }

    @Test func contentDisposition() {
        #expect(HTTPHeaderParsing.fileName(fromContentDisposition: #"attachment; filename="report final.pdf""#) == "report final.pdf")
        #expect(HTTPHeaderParsing.fileName(fromContentDisposition: "attachment; filename=plain.zip") == "plain.zip")
        #expect(HTTPHeaderParsing.fileName(fromContentDisposition: #"attachment; filename="fallback.txt"; filename*=UTF-8''%E6%97%A5%E6%9C%AC.txt"#) == "日本.txt")
        #expect(HTTPHeaderParsing.fileName(fromContentDisposition: "inline") == nil)
    }

    @Test func repairsLatin1DecodedUTF8() {
        let mangled = String(bytes: Array("café.zip".utf8), encoding: .isoLatin1)!
        #expect(HTTPHeaderParsing.fileName(fromContentDisposition: "attachment; filename=\"\(mangled)\"") == "café.zip")
    }

    @Test func sanitize() {
        #expect(HTTPHeaderParsing.sanitizeFileName("a/b:c.txt") == "a_b_c.txt")
        #expect(HTTPHeaderParsing.sanitizeFileName("..hidden") == "hidden")
        #expect(HTTPHeaderParsing.sanitizeFileName("  ") == "download")
        let long = String(repeating: "x", count: 400) + ".zip"
        let trimmed = HTTPHeaderParsing.sanitizeFileName(long)
        #expect(trimmed.utf8.count <= 240 && trimmed.hasSuffix(".zip"))
    }

    @Test func suggestedName() {
        let url = URL(string: "https://example.com/files/My%20File.dmg?x=1")!
        #expect(HTTPHeaderParsing.suggestedFileName(url: url, contentDisposition: nil, mimeType: nil) == "My File.dmg")
        let script = URL(string: "https://example.com/download.php?id=4")!
        #expect(HTTPHeaderParsing.suggestedFileName(url: script, contentDisposition: nil, mimeType: "application/zip") == "download.zip")
    }
}

@Suite struct SegmentPlannerTests {
    @Test func initialSplitCoversWholeFile() {
        let total: Int64 = 10_000_003
        let segments = SegmentPlanner.initialSegments(totalBytes: total, connections: 8, minSize: 1000)
        #expect(segments.count == 8)
        #expect(segments.first?.start == 0)
        #expect(segments.last?.end == total - 1)
        for (a, b) in zip(segments, segments.dropFirst()) { #expect(a.end + 1 == b.start) }
    }

    @Test func smallFilesUseFewerConnections() {
        #expect(SegmentPlanner.initialSegments(totalBytes: 300_000, connections: 8).count == 1)
        #expect(SegmentPlanner.initialSegments(totalBytes: -1, connections: 8) == [Segment(id: 0, start: 0, end: -1)])
        #expect(SegmentPlanner.initialSegments(totalBytes: 0, connections: 8).isEmpty)
    }

    @Test func dynamicSplitTakesHalfOfLargestRemaining() {
        var segments = [Segment(id: 0, start: 0, end: 999, received: 1000),
                        Segment(id: 1, start: 1000, end: 9999, received: 1000)]
        let index = SegmentPlanner.split(&segments, active: [1], minSize: 100)
        #expect(index == 2)
        // Segment 1 is at 2000 with 8000 left: new boundary at 6000.
        #expect(segments[1].end == 5999)
        #expect(segments[2] == Segment(id: 2, start: 6000, end: 9999))
    }

    @Test func refusesTinySplits() {
        var segments = [Segment(id: 0, start: 0, end: 150)]
        #expect(SegmentPlanner.split(&segments, active: [0], minSize: 100) == nil)
    }
}

@Suite struct HLSTests {
    let base = URL(string: "https://cdn.example.com/video/master.m3u8")!

    @Test func master() throws {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",DEFAULT=YES,URI="audio/en.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2",AUDIO="aud"
        low/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,AUDIO="aud"
        https://other.example.com/high.m3u8
        """
        guard case .master(let master) = try HLSParser.parse(text, baseURL: base) else { Issue.record("expected master"); return }
        #expect(master.variants.count == 2)
        #expect(master.variants[0].url.absoluteString == "https://cdn.example.com/video/low/index.m3u8")
        #expect(master.variants[0].codecs == "avc1.4d401e,mp4a.40.2")
        #expect(master.variants[1].label == "1080p · 5.0 Mbps")
        #expect(master.audio(for: master.variants[1])?.absoluteString == "https://cdn.example.com/video/audio/en.m3u8")
    }

    @Test func media() throws {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:10
        #EXT-X-MEDIA-SEQUENCE:7
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x000102030405060708090a0b0c0d0e0f
        #EXTINF:9.5,
        seg7.ts
        #EXT-X-BYTERANGE:500@0
        #EXTINF:10.0,
        seg8.ts
        #EXT-X-BYTERANGE:300
        #EXTINF:10.0,
        seg8.ts
        #EXT-X-ENDLIST
        """
        guard case .media(let playlist) = try HLSParser.parse(text, baseURL: base) else { Issue.record("expected media"); return }
        #expect(playlist.isComplete)
        #expect(playlist.segments.map(\.sequence) == [7, 8, 9])
        #expect(playlist.segments[0].key?.url?.lastPathComponent == "key.bin")
        #expect(playlist.segments[0].key?.iv?.count == 16)
        #expect(playlist.segments[1].byteRange == 0...499)
        #expect(playlist.segments[2].byteRange == 500...799)
        #expect(abs(playlist.duration - 29.5) < 0.001)
    }

    @Test func quotedAttributesWithCommas() {
        let attrs = HLSParser.attributes(#"BANDWIDTH=1,CODECS="a,b",NAME=x"#)
        #expect(attrs == ["BANDWIDTH": "1", "CODECS": "a,b", "NAME": "x"])
    }

    @Test func aesRoundTrip() throws {
        let key = Data((0..<16).map { UInt8($0) })
        let iv = HLSDownloader.iv(for: 42)
        #expect(iv.last == 42)
        let plain = Data("segment payload that spans more than one block".utf8)
        var encrypted = Data(count: plain.count + 16)
        let capacity = encrypted.count
        var moved = 0
        _ = encrypted.withUnsafeMutableBytes { out in
            plain.withUnsafeBytes { input in key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
                CCCryptShim.encrypt(k.baseAddress!, v.baseAddress!, input.baseAddress!, plain.count, out.baseAddress!, capacity, &moved)
            } } }
        }
        encrypted.count = moved
        #expect(try HLSDownloader.decryptAES128(encrypted, key: key, iv: iv) == plain)
    }
}

import CommonCrypto

enum CCCryptShim {
    static func encrypt(_ key: UnsafeRawPointer, _ iv: UnsafeRawPointer, _ input: UnsafeRawPointer, _ length: Int,
                        _ output: UnsafeMutableRawPointer, _ capacity: Int, _ moved: inout Int) -> Int32 {
        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                key, 16, iv, input, length, output, capacity, &moved)
    }
}

@Suite struct LinkTests {
    @Test func extractsAnchorsAndSources() {
        let html = """
        <a href="/files/a.zip">Archive <b>A</b></a>
        <a href='https://x.com/b.pdf?x=1&amp;y=2#frag'>B</a>
        <a href="javascript:void(0)">nope</a>
        <img src="pic.jpg"><video src="//cdn.x.com/v.mp4"></video>
        """
        let links = LinkExtractor.links(inHTML: html, baseURL: URL(string: "https://site.com/page/index.html")!)
        let urls = links.map(\.url.absoluteString)
        #expect(urls == ["https://site.com/files/a.zip", "https://x.com/b.pdf?x=1&y=2",
                         "https://site.com/page/pic.jpg", "https://cdn.x.com/v.mp4"])
        #expect(links[0].text == "Archive A")
    }

    @Test func batchNumbersAndLetters() {
        #expect(BatchPattern.expand("http://x/img*.jpg", range: .numbers(from: 8, to: 10, width: 3))
            == ["http://x/img008.jpg", "http://x/img009.jpg", "http://x/img010.jpg"])
        #expect(BatchPattern.expand("http://x/*.txt", range: .letters(from: "a", to: "c")) == ["http://x/a.txt", "http://x/b.txt", "http://x/c.txt"])
        #expect(BatchPattern.expand("http://x/*", range: .numbers(from: 1, to: 1_000_000, width: 0), limit: 5).count == 5)
    }

    @Test func uniqueNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.zip").path, contents: nil)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a (1).zip.nidestream").path, contents: nil)
        #expect(FileUtils.uniqueName("a.zip", in: dir) == "a (2).zip")
        #expect(FileUtils.uniqueName("b.zip", in: dir, taken: ["b.zip"]) == "b (1).zip")
    }
}

@Suite struct HTTPRequestTests {
    @Test func parsesCompleteRequest() {
        let raw = "POST /add?x=1 HTTP/1.1\r\nHost: 127.0.0.1:51515\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
        guard case .complete(let request) = HTTPRequest.parse(Data(raw.utf8)) else { Issue.record("expected complete"); return }
        #expect(request.method == "POST")
        #expect(request.path == "/add")
        #expect(request.query == ["x": "1"])
        #expect(request.headers["content-type"] == "application/json")
        #expect(request.body == Data("{}".utf8))
    }

    @Test func waitsForBody() {
        let raw = "POST /add HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"a\""
        guard case .incomplete = HTTPRequest.parse(Data(raw.utf8)) else { Issue.record("expected incomplete"); return }
    }
}

@Suite struct RateLimiterTests {
    @Test func unlimitedNeverWaits() {
        #expect(RateLimiter().consume(10_000_000) == 0)
    }

    @Test func limitedAsksToWait() {
        let limiter = RateLimiter(bytesPerSecond: 100_000)
        let delay = limiter.consume(125_000)
        #expect(delay > 0.9 && delay < 1.1)
    }
}

@Suite struct LinkRefreshTests {
    private func record(_ name: String, total: Int64, received: Int64 = 1000) -> DownloadRecord {
        var record = DownloadRecord(url: URL(string: "https://old.example.com/a")!, fileName: name, directory: URL(fileURLWithPath: "/tmp"))
        record.totalBytes = total
        record.receivedBytes = received
        record.status = .failed
        record.etag = "\"old\""
        record.segments = [Segment(id: 0, start: 0, end: total - 1, received: received)]
        return record
    }

    private func probe(_ name: String, total: Int64, ranges: Bool = true) -> ProbeResult {
        ProbeResult(finalURL: URL(string: "https://cdn2.example.com/b")!, statusCode: 206, totalBytes: total, acceptsRanges: ranges,
                    fileName: name, mimeType: "application/zip", etag: "\"new\"", lastModified: nil, isHLS: false)
    }

    @Test func matchesSameNameAndSize() {
        #expect(LinkRefresh.isSameFile(record("setup.zip", total: 5000), as: probe("setup.zip", total: 5000)))
        #expect(LinkRefresh.isSameFile(record("Setup (1).zip", total: 5000), as: probe("setup.zip", total: 5000)))
    }

    @Test func rejectsDifferentFiles() {
        #expect(!LinkRefresh.isSameFile(record("setup.zip", total: 5000), as: probe("setup.zip", total: 5001)))
        #expect(!LinkRefresh.isSameFile(record("setup.zip", total: 5000), as: probe("other.zip", total: 5000)))
        #expect(!LinkRefresh.isSameFile(record("setup.zip", total: 5000), as: probe("setup.zip", total: 5000, ranges: false)))
        var done = record("setup.zip", total: 5000)
        done.status = .completed
        #expect(!LinkRefresh.isSameFile(done, as: probe("setup.zip", total: 5000)))
    }

    @Test func sameFileNameIgnoresCaseAndCopyNumber() {
        #expect(LinkRefresh.sameFileName("Movie (1).mkv", "movie.mkv"))
        #expect(LinkRefresh.sameFileName("README", "readme (2)"))
        #expect(!LinkRefresh.sameFileName("movie.mkv", "movie.mp4"))
        #expect(!LinkRefresh.sameFileName("movie 1.mkv", "movie.mkv"))
    }

    @Test func refreshKeepsProgressAndTakesNewFingerprint() {
        let old = record("setup.zip", total: 5000, received: 2500)
        let url = URL(string: "https://cdn2.example.com/b?token=fresh")!
        let updated = LinkRefresh.refreshed(old, with: probe("setup.zip", total: 5000), url: url)
        #expect(updated.url == url)
        #expect(updated.etag == "\"new\"")
        #expect(updated.validator == "\"new\"")
        #expect(updated.segments == old.segments)
        #expect(updated.receivedBytes == 2500)
        #expect(updated.lastError == nil)
    }
}
