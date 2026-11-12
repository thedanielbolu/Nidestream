import Foundation
import Testing
@testable import NidestreamCore

/// Runs HLSDownloader end to end on a stream served from file:// URLs, so no server is needed.
/// The video track has 3 segments of 20,000 bytes, the audio track 2 of 5,000.
@Suite final class HLSDownloaderTests {
    let root: URL
    let work: URL
    let video: [Data]
    let audio: [Data]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nidestream-hls-\(UUID().uuidString)", isDirectory: true)
        work = root.appendingPathComponent("work", isDirectory: true)
        video = (0..<3).map { _ in Self.random(20_000) }
        audio = (0..<2).map { _ in Self.random(5_000) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("stream"), withIntermediateDirectories: true)
        try writeTrack(video, prefix: "v", fileExtension: "ts", playlist: "video.m3u8")
        try writeTrack(audio, prefix: "a", fileExtension: "aac", playlist: "audio.m3u8")
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private var notEnoughSpace: RunnerResult { .failed(DownloadError.notEnoughSpace.errorDescription!) }

    // MARK: Disk errors

    @Test func segmentWriteErrorsFailWithoutRetrying() async throws {
        let segments = work.appendingPathComponent("video", isDirectory: true)
        try FileManager.default.createDirectory(at: segments, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: segments.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: segments.path) }

        let started = Date()
        let result = await run(job(maxRetries: 3)) // retrying would back off for 1 + 2 + 4 s
        #expect(result == .failed(DownloadError.io("Permission denied").errorDescription!))
        #expect(Date().timeIntervalSince(started) < 2, "the write was retried")
    }

    @Test func diskErrorsBecomeErrorsThatArentRetried() {
        func posix(_ code: Int32) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        func cocoa(_ code: CocoaError.Code, _ underlying: NSError) -> NSError {
            NSError(domain: NSCocoaErrorDomain, code: code.rawValue, userInfo: [NSUnderlyingErrorKey: underlying])
        }
        let cases: [(Error, DownloadError)] = [
            (CocoaError(.fileWriteOutOfSpace), .notEnoughSpace),
            (posix(ENOSPC), .notEnoughSpace),
            (cocoa(.fileWriteUnknown, posix(ENOSPC)), .notEnoughSpace),
            (cocoa(.fileWriteVolumeReadOnly, posix(EROFS)), .io("Read-only file system")),
            (cocoa(.fileWriteNoPermission, posix(EACCES)), .io("Permission denied")),
        ]
        for (error, expected) in cases {
            let mapped = HLSDownloader.diskError(error)
            #expect(mapped == expected, "\(error)")
            #expect(!isRetryable(mapped))
        }
    }

    // MARK: Assembly

    @Test func joiningNeedsRoomForTheLargestTrack() async throws {
        let videoBytes = Int64(video.reduce(0) { $0 + $1.count })
        #expect(await run(job(audio: true), freeSpace: videoBytes - 1) == notEnoughSpace)
        // Nothing was joined or deleted, so freeing up space and resuming carries on from here.
        #expect(try contents(of: work) == ["audio", "video"])
        #expect(try contents(of: work.appendingPathComponent("video")).count == video.count)

        let result = await run(job(audio: true), freeSpace: videoBytes)
        guard case .completed(let outputs) = result else { Issue.record("\(result)"); return }
        #expect(outputs.map(\.lastPathComponent) == ["video.ts", "audio.aac"])
        #expect(try Data(contentsOf: outputs[0]) == video.reduce(Data(), +))
        #expect(try Data(contentsOf: outputs[1]) == audio.reduce(Data(), +))
        #expect(try contents(of: work) == ["audio.aac", "video.ts"])
    }

    @Test func remuxNeedsRoomForEveryTrackAndRunsOnceSegmentsAreDeleted() async throws {
        let (ffmpeg, log) = try fakeFFmpeg()
        let total = Int64((video + audio).reduce(0) { $0 + $1.count })
        #expect(await run(job(audio: true, ffmpeg: ffmpeg), freeSpace: total - 1) == notEnoughSpace)
        #expect(try contents(of: work) == ["audio", "video"])
        #expect(!FileManager.default.fileExists(atPath: log.path), "ffmpeg ran")

        let result = await run(job(audio: true, ffmpeg: ffmpeg), freeSpace: total)
        guard case .completed(let outputs) = result else { Issue.record("\(result)"); return }
        #expect(outputs.map(\.lastPathComponent) == ["merged.mp4"])
        // When ffmpeg ran, only the joined tracks were left: their segment folders were already gone.
        #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").sorted() == ["audio.aac", "video.ts"])
        #expect(try Data(contentsOf: outputs[0]) == (video + audio).reduce(Data(), +))
        #expect(try contents(of: work) == ["merged.mp4"])
    }

    /// Like quitting while ffmpeg runs, then resuming: the joined tracks are used as they are,
    /// although their segments are gone.
    @Test func resumeUsesTracksThatWereJoined() async throws {
        let first = await run(job(audio: true))
        guard case .completed = first else { Issue.record("\(first)"); return }
        // Fetching the video segments again would now fail.
        for index in video.indices { try FileManager.default.removeItem(at: stream("v\(index).ts")) }

        let (ffmpeg, _) = try fakeFFmpeg()
        let result = await run(job(audio: true, ffmpeg: ffmpeg))
        guard case .completed(let outputs) = result else { Issue.record("\(result)"); return }
        #expect(outputs.map(\.lastPathComponent) == ["merged.mp4"])
        #expect(try Data(contentsOf: outputs[0]) == (video + audio).reduce(Data(), +))
    }

    // MARK: Helpers

    private func stream(_ name: String) -> URL { root.appendingPathComponent("stream").appendingPathComponent(name) }

    private func job(audio: Bool = false, ffmpeg: URL? = nil, maxRetries: Int = 6) -> HLSJob {
        HLSJob(playlistURL: stream("video.m3u8"), audioURL: audio ? stream("audio.m3u8") : nil, workDirectory: work,
               maxRetries: maxRetries, ffmpegPath: ffmpeg?.path)
    }

    /// Runs a download to the end. `freeSpace` stands in for the drive's free space.
    private func run(_ job: HLSJob, freeSpace: Int64? = nil) async -> RunnerResult {
        let box = ResultBox()
        let downloader = HLSDownloader(job: job, limiters: []) { event in
            if case .finished(let result, _) = event { box.finish(result) }
        }
        if let freeSpace { downloader.availableCapacity = { _ in freeSpace } }
        return await withCheckedContinuation { continuation in
            box.continuation = continuation
            downloader.start()
        }
    }

    private func contents(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func writeTrack(_ segments: [Data], prefix: String, fileExtension: String, playlist: String) throws {
        var text = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n"
        for (index, segment) in segments.enumerated() {
            let name = "\(prefix)\(index).\(fileExtension)"
            try segment.write(to: stream(name))
            text += "#EXTINF:4.0,\n\(name)\n"
        }
        try (text + "#EXT-X-ENDLIST\n").write(to: stream(playlist), atomically: true, encoding: .utf8)
    }

    /// A stand-in for ffmpeg that lists what's in the work folder into `log`, then writes its
    /// inputs one after the other into its output.
    private func fakeFFmpeg() throws -> (executable: URL, log: URL) {
        let executable = root.appendingPathComponent("ffmpeg")
        let log = root.appendingPathComponent("ffmpeg.log")
        let script = """
        #!/bin/sh
        inputs=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "-i" ]; then shift; inputs="$inputs $1"; fi
          output="$1"
          shift
        done
        ls -1 "$(dirname "$output")" > '\(log.path)'
        cat $inputs > "$output"
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (executable, log)
    }

    private static func random(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<RunnerResult, Never>?

    func finish(_ result: RunnerResult) {
        let continuation = lock.withLock { () -> CheckedContinuation<RunnerResult, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: result)
    }
}
