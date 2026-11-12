import CryptoKit
import Foundation
import Testing
@testable import NidestreamCore

/// Runs against `scripts/test-server.py` (range support, 2 MB/s per connection).
/// Start it, then: `NIDESTREAM_TEST_SERVER=http://127.0.0.1:8765 swift test`
private let server = ProcessInfo.processInfo.environment["NIDESTREAM_TEST_SERVER"]

@Suite(.enabled(if: server != nil), .serialized)
struct IntegrationTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("nidestream-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(_ path: String) -> URL { URL(string: server! + path)! }

    private func sha256(_ file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
    }

    /// Runs a downloader until it finishes; optionally stops it after `stopAfter` seconds.
    private func run(_ job: HTTPJob, limiters: [RateLimiter] = [], stopAfter: TimeInterval? = nil,
                     onPreparing: @escaping @Sendable (Bool) -> Void = { _ in },
                     onProgress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }) async -> (RunnerResult, DownloadProgress) {
        let box = LockedBox()
        let runner = SegmentedDownloader(job: job, limiters: limiters) { event in
            switch event {
            case .progress(let progress): onProgress(progress)
            case .preparing(let active): onPreparing(active)
            case .finished(let result, let progress): box.finish(result, progress)
            case .processing: break
            }
        }
        return await withCheckedContinuation { continuation in
            box.continuation = continuation
            runner.start()
            if let stopAfter {
                DispatchQueue.global().asyncAfter(deadline: .now() + stopAfter) { runner.stop() }
            }
        }
    }

    @Test func pauseAndResumeProducesIdenticalFile() async throws {
        let source = url("/big.bin")
        let probe = try await Prober.probe(url: source, headers: [:])
        #expect(probe.acceptsRanges)
        let part = directory.appendingPathComponent("big.bin.nidestream")
        var job = HTTPJob(url: source, partURL: part, totalBytes: probe.totalBytes, resumable: true, maxConnections: 8, validator: probe.validator)

        let (first, paused) = await run(job, stopAfter: 1.0)
        #expect(first == .stopped)
        let segments = try #require(paused.segments)
        #expect(paused.receivedBytes > 0 && paused.receivedBytes < probe.totalBytes)

        job.segments = segments
        let (second, done) = await run(job)
        #expect(second == .completed(outputs: []))
        #expect(done.receivedBytes == probe.totalBytes)
        #expect(try sha256(part) == (try await expectedHash("big.bin")))
    }

    /// Progress counts as saved only once it's on the disk, so a USB drive pulled out without
    /// ejecting can't leave holes that a resume would skip.
    @Test func savedProgressTrailsWhatIsWritten() async throws {
        let source = url("/big.bin")
        let probe = try await Prober.probe(url: source, headers: [:])
        let part = directory.appendingPathComponent("saved.nidestream")
        let job = HTTPJob(url: source, partURL: part, totalBytes: probe.totalBytes, resumable: true, maxConnections: 2, validator: probe.validator)
        let samples = LockedPairs()
        let (result, stopped) = await run(job, stopAfter: 4.5) { progress in
            samples.add(saved: progress.savedSegments?.reduce(0) { $0 + $1.received } ?? 0, live: progress.receivedBytes)
        }
        #expect(result == .stopped)
        #expect(samples.values.allSatisfy { $0.saved <= $0.live })
        #expect(samples.values.contains { $0.saved > 0 }, "no checkpoint within 4.5 s")
        // Stopping pushes everything to the disk first, so all of it counts.
        #expect(stopped.savedSegments == stopped.segments)
    }

    private func expectedHash(_ name: String) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: url("/sha256/" + name))
        return String(decoding: data, as: UTF8.self)
    }

    @Test func resumeAddsConnectionsBySplitting() async throws {
        let source = url("/big.bin")
        let probe = try await Prober.probe(url: source, headers: [:])
        let part = directory.appendingPathComponent("split.nidestream")
        // A single-connection run that gets paused, then resumed with more connections allowed.
        var job = HTTPJob(url: source, partURL: part, totalBytes: probe.totalBytes, resumable: true, maxConnections: 1, validator: probe.validator)
        let (stopped, progress) = await run(job, stopAfter: 1.5)
        #expect(stopped == .stopped)
        #expect((progress.segments ?? []).count == 1)

        job.segments = progress.segments ?? []
        job.maxConnections = 6
        let (result, final) = await run(job)
        #expect(result == .completed(outputs: []))
        #expect((final.segments ?? []).count >= 4)
        #expect(final.receivedBytes == probe.totalBytes)
        #expect(try sha256(part) == (try await expectedHash("big.bin")))
    }

    @Test func changedFileRestartsAsSingleStream() async throws {
        let source = url("/disposition.bin")
        let probe = try await Prober.probe(url: source, headers: [:])
        let part = directory.appendingPathComponent("changed.nidestream")
        var job = HTTPJob(url: source, partURL: part, totalBytes: probe.totalBytes, resumable: true, maxConnections: 2, validator: probe.validator)
        let (stopped, paused) = await run(job, stopAfter: 0.5)
        #expect(stopped == .stopped)
        job.segments = paused.segments ?? []
        job.validator = "\"stale-etag\""
        let (result, final) = await run(job)
        #expect(result == .completed(outputs: []))
        #expect(final.resumable == false)
        #expect(final.receivedBytes == probe.totalBytes)
        #expect(try sha256(part) == (try await expectedHash("disposition.bin")))
    }

    /// IDM's "refresh download address": pause on one link, finish from another server that serves
    /// the same file. Using the new server's ETag keeps the progress; the old one would force a restart.
    @Test func continuesFromNewerLinkOnAnotherServer() async throws {
        let original = url("/big.bin")
        let probe = try await Prober.probe(url: original, headers: [:])
        let part = directory.appendingPathComponent("moved.nidestream")
        var job = HTTPJob(url: original, partURL: part, totalBytes: probe.totalBytes, resumable: true, maxConnections: 8, validator: probe.validator)
        let (stopped, paused) = await run(job, stopAfter: 1.0)
        #expect(stopped == .stopped)
        let before = paused.receivedBytes
        #expect(before > 0 && before < probe.totalBytes)

        let newer = url("/mirror/big.bin")
        let newProbe = try await Prober.probe(url: newer, headers: [:])
        #expect(newProbe.etag != probe.etag)
        var record = DownloadRecord(url: original, fileName: "big.bin", directory: directory)
        record.totalBytes = probe.totalBytes
        record.receivedBytes = before
        record.status = .failed
        record.segments = paused.segments ?? []
        record.etag = probe.etag
        #expect(LinkRefresh.isSameFile(record, as: newProbe))
        let refreshed = LinkRefresh.refreshed(record, with: newProbe, url: newer)

        job.url = refreshed.url
        job.validator = refreshed.validator
        job.segments = refreshed.segments
        let reached = LockedTime()
        let box = LockedBox()
        let runner = SegmentedDownloader(job: job, limiters: []) { event in
            switch event {
            case .progress(let progress) where progress.receivedBytes < before:
                reached.setOnce(0) // progress went backwards: the download restarted
            case .finished(let result, let progress):
                box.finish(result, progress)
            default:
                break
            }
        }
        let (result, final) = await withCheckedContinuation { continuation in
            box.continuation = continuation
            runner.start()
        }
        #expect(result == .completed(outputs: []))
        #expect(final.resumable, "the download fell back to starting over")
        #expect(reached.value == nil, "progress went backwards")
        #expect(try sha256(part) == (try await expectedHash("big.bin")))
    }

    /// The server caps each connection (2 MB/s here), like most file hosts: connections get added.
    @Test func addsConnectionsWhileTheyHelp() async throws {
        let source = url("/huge.bin") // 96 MB: long enough for more than one step
        let probe = try await Prober.probe(url: source, headers: [:])
        let job = HTTPJob(url: source, partURL: directory.appendingPathComponent("ramp.nidestream"), totalBytes: probe.totalBytes,
                          resumable: true, maxConnections: 12, validator: probe.validator, initialConnections: 4, adaptiveWindow: 0.5)
        let counts = LockedCounts()
        let (result, _) = await run(job, onProgress: { counts.add($0.connections) })
        #expect(result == .completed(outputs: []))
        #expect(counts.maximum >= 8, "never went past \(counts.maximum) connections")
    }

    /// The server shares one cap across connections: extra connections are tried, then given back.
    @Test func dropsConnectionsThatDontHelp() async throws {
        let source = url("/shared/big.bin") // 8 MB/s in total, 2 MB/s per connection
        let probe = try await Prober.probe(url: source, headers: [:])
        let job = HTTPJob(url: source, partURL: directory.appendingPathComponent("shared.nidestream"), totalBytes: probe.totalBytes,
                          resumable: true, maxConnections: 12, validator: probe.validator, initialConnections: 4, adaptiveWindow: 0.5)
        let counts = LockedCounts()
        let (result, _) = await run(job, onProgress: { counts.add($0.connections) })
        #expect(result == .completed(outputs: []))
        // After the first trial (about 2 s in) it should be back to 4 connections and stay there.
        let settled = counts.values.dropFirst(5).dropLast(2)
        #expect(!settled.isEmpty && settled.allSatisfy { $0 <= 4 }, "connections over time: \(counts.values)")
    }

    @Test func speedLimiterHoldsTheRate() async throws {
        let source = url("/big.bin") // 40 MB at ~16 MB/s unthrottled with 8 connections
        let probe = try await Prober.probe(url: source, headers: [:])
        let job = HTTPJob(url: source, partURL: directory.appendingPathComponent("limited.nidestream"), totalBytes: probe.totalBytes,
                          resumable: true, maxConnections: 8, validator: probe.validator)
        let started = Date()
        let reached16 = LockedTime()
        let reached32 = LockedTime()
        let box = LockedBox()
        let runner = SegmentedDownloader(job: job, limiters: [RateLimiter(bytesPerSecond: 8 << 20)]) { event in
            switch event {
            case .progress(let progress):
                if progress.receivedBytes >= 16 << 20 { reached16.setOnce(Date().timeIntervalSince(started)) }
                if progress.receivedBytes >= 32 << 20 { reached32.setOnce(Date().timeIntervalSince(started)) }
            case .finished(let result, let progress):
                box.finish(result, progress)
            default:
                break
            }
        }
        let (result, _) = await withCheckedContinuation { continuation in
            box.continuation = continuation
            runner.start()
        }
        #expect(result == .completed(outputs: []))
        // Socket buffers let roughly 1 MB per connection through at the start, so measure the steady state:
        // 16 MB at 8 MB/s ≈ 2 s (unthrottled: ≈ 1 s).
        let elapsed = try #require(reached32.value) - (try #require(reached16.value))
        #expect(elapsed > 1.6 && elapsed < 2.6, "16 → 32 MB took \(elapsed) s")
    }

    /// USB drives are usually FAT32 or exFAT, which macOS reports differently from APFS: no
    /// "important usage" free space, a 4 GB file limit (FAT32), and space reserved up front.
    @Test func downloadsToAFAT32Drive() async throws {
        let drive = try FAT32Image(in: directory)
        defer { drive.detach() }
        let free = try #require(FileUtils.availableCapacity(at: drive.mount))
        #expect(free > 60_000_000, "free space on an empty 96 MB FAT32 drive: \(free)")
        #expect(FileUtils.maximumFileSize(at: drive.mount) == 4_294_967_295)

        let source = url("/big.bin")
        let probe = try await Prober.probe(url: source, headers: [:])
        let part = drive.mount.appendingPathComponent("big.bin.nidestream")
        var job = HTTPJob(url: source, partURL: part, totalBytes: probe.totalBytes, resumable: true, maxConnections: 4, validator: probe.validator)
        let preparing = LockedFlags()
        let (first, paused) = await run(job, stopAfter: 1.0, onPreparing: { preparing.add($0) })
        #expect(first == .stopped)
        #expect(preparing.values == [true, false])
        #expect(paused.receivedBytes < probe.totalBytes)
        // The paused file already holds its whole size, so resuming needs no more space.
        #expect(FileUtils.spaceNeeded(totalBytes: probe.totalBytes, receivedBytes: paused.receivedBytes, partFile: part) == 0)
        #expect(paused.savedSegments == paused.segments)

        job.segments = try #require(paused.savedSegments)
        let (second, done) = await run(job)
        #expect(second == .completed(outputs: []))
        #expect(done.receivedBytes == probe.totalBytes)
        #expect(try sha256(part) == (try await expectedHash("big.bin")))
    }

    @Test func notFoundFailsWithoutRetrying() async throws {
        await #expect(throws: DownloadError.http(404)) {
            try await Prober.probe(url: url("/missing.bin"), headers: [:])
        }
    }
}

/// A small FAT32 disk image, mounted for one test (no administrator rights needed).
private struct FAT32Image {
    let image: URL
    let mount: URL

    init(in directory: URL) throws {
        image = directory.appendingPathComponent("fat32.sparseimage")
        mount = directory.appendingPathComponent("fat32-mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try Self.hdiutil(["create", "-quiet", "-size", "96m", "-fs", "MS-DOS FAT32", "-volname", "NSTEST", "-type", "SPARSE", image.path])
        try Self.hdiutil(["attach", "-quiet", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path])
    }

    func detach() {
        try? Self.hdiutil(["detach", "-quiet", "-force", mount.path])
        try? FileManager.default.removeItem(at: image)
    }

    private static func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DownloadError.io("hdiutil \(arguments[0]) failed") }
    }
}

private final class LockedPairs: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(saved: Int64, live: Int64)] = []

    var values: [(saved: Int64, live: Int64)] { lock.withLock { stored } }

    func add(saved: Int64, live: Int64) { lock.withLock { stored.append((saved, live)) } }
}

private final class LockedFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Bool] = []

    var values: [Bool] { lock.withLock { stored } }

    func add(_ value: Bool) { lock.withLock { stored.append(value) } }
}

private final class LockedCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []

    var values: [Int] { lock.withLock { stored } }
    var maximum: Int { values.max() ?? 0 }

    func add(_ value: Int) { lock.withLock { stored.append(value) } }
}

private final class LockedTime: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TimeInterval?

    var value: TimeInterval? { lock.withLock { stored } }

    func setOnce(_ time: TimeInterval) {
        lock.withLock { if stored == nil { stored = time } }
    }
}

private final class LockedBox: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<(RunnerResult, DownloadProgress), Never>?

    func finish(_ result: RunnerResult, _ progress: DownloadProgress) {
        let continuation = lock.withLock { () -> CheckedContinuation<(RunnerResult, DownloadProgress), Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: (result, progress))
    }
}
