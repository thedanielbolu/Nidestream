import CryptoKit
import Foundation
import Testing
@testable import SwiftDMCore

/// Runs against `scripts/test-server.py` (range support, 2 MB/s per connection).
/// Start it, then: `SWIFTDM_TEST_SERVER=http://127.0.0.1:8765 swift test`
private let server = ProcessInfo.processInfo.environment["SWIFTDM_TEST_SERVER"]

@Suite(.enabled(if: server != nil), .serialized)
struct IntegrationTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("swiftdm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(_ path: String) -> URL { URL(string: server! + path)! }

    private func sha256(_ file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
    }

    /// Runs a downloader until it finishes; optionally stops it after `stopAfter` seconds.
    private func run(_ job: HTTPJob, limiters: [RateLimiter] = [], stopAfter: TimeInterval? = nil) async -> (RunnerResult, DownloadProgress) {
        let box = LockedBox()
        let runner = SegmentedDownloader(job: job, limiters: limiters) { event in
            if case .finished(let result, let progress) = event { box.finish(result, progress) }
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
        let part = directory.appendingPathComponent("big.bin.sdmpart")
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

    private func expectedHash(_ name: String) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: url("/sha256/" + name))
        return String(decoding: data, as: UTF8.self)
    }

    @Test func resumeAddsConnectionsBySplitting() async throws {
        let source = url("/big.bin")
        let probe = try await Prober.probe(url: source, headers: [:])
        let part = directory.appendingPathComponent("split.sdmpart")
        // A single-connection run that gets paused, then resumed with more connections allowed.
        var job = HTTPJob(url: source, partURL: part, totalBytes: probe.totalBytes, resumable: true, maxConnections: 1, validator: probe.validator)
        let (stopped, progress) = await run(job, stopAfter: 1.5)
        #expect(stopped == .stopped)
        #expect((progress.segments ?? []).count == 1)

        job.segments = progress.segments ?? []
        job.maxConnections = 6
        let (result, final) = await run(job)
        #expect(result == .completed(outputs: []))
        #expect((final.segments ?? []).count >= 6)
        #expect(final.receivedBytes == probe.totalBytes)
        #expect(try sha256(part) == (try await expectedHash("big.bin")))
    }

    @Test func changedFileRestartsAsSingleStream() async throws {
        let source = url("/disposition.bin")
        let probe = try await Prober.probe(url: source, headers: [:])
        let part = directory.appendingPathComponent("changed.sdmpart")
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

    @Test func speedLimiterHoldsTheRate() async throws {
        let source = url("/big.bin") // 40 MB at ~16 MB/s unthrottled with 8 connections
        let probe = try await Prober.probe(url: source, headers: [:])
        let job = HTTPJob(url: source, partURL: directory.appendingPathComponent("limited.sdmpart"), totalBytes: probe.totalBytes,
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

    @Test func notFoundFailsWithoutRetrying() async throws {
        await #expect(throws: DownloadError.http(404)) {
            try await Prober.probe(url: url("/missing.bin"), headers: [:])
        }
    }
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
