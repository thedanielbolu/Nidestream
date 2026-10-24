import Foundation
import NidestreamCore

/// Headless downloads for scripts:
/// `Nidestream --download <url> [--out <folder>] [--connections <n>] [--limit <KB/s>]`
enum CommandLineDownload {
    static func run(_ arguments: [String]) -> Int32 {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        guard let address = value("--download"), let url = URL(string: address), url.scheme != nil else {
            FileHandle.standardError.write(Data("usage: Nidestream --download <url> [--out <folder>] [--connections <n>] [--limit <KB/s>]\n".utf8))
            return 64
        }
        let directory = URL(fileURLWithPath: (value("--out") ?? FileManager.default.currentDirectoryPath) as NSString as String)
        let connections = Int(value("--connections") ?? "") ?? 8
        let limiter = RateLimiter(bytesPerSecond: (Int(value("--limit") ?? "") ?? 0) * 1024)
        let headers = ["User-Agent": Preferences.safariUserAgent, "Accept": "*/*"]

        let finished = DispatchSemaphore(value: 0)
        let status = LockedValue<Int32>(1)
        Task.detached {
            do {
                let probe = try await Prober.probe(url: url, headers: headers)
                let name = FileUtils.uniqueName(probe.isHLS ? (probe.fileName as NSString).deletingPathExtension + ".mp4" : probe.fileName,
                                                in: directory)
                if probe.isHLS {
                    print("Saving video stream as \((name as NSString).deletingPathExtension)")
                } else {
                    let size = probe.totalBytes >= 0 ? ByteCountFormatter.string(fromByteCount: probe.totalBytes, countStyle: .file) : "unknown size"
                    print("Saving \(name) (\(size), \(probe.acceptsRanges ? "resumable, up to \(connections) connections" : "single connection"))")
                }
                let workDirectory = directory.appendingPathComponent("." + name + ".nidestream-hls", isDirectory: true)
                let started = Date()
                let done = LockedValue<CheckedContinuation<Void, Never>?>(nil)
                let sink: @Sendable (RunnerEvent) -> Void = { event in
                    switch event {
                    case .progress(let progress):
                        let percent = progress.totalBytes > 0 ? Double(progress.receivedBytes) * 100 / Double(progress.totalBytes) : 0
                        let rate = Double(progress.receivedBytes) / max(0.1, Date().timeIntervalSince(started))
                        print(String(format: "\r%5.1f%%  %@  %@/s  %d connections   ", percent,
                                     ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file),
                                     ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file), progress.connections),
                              terminator: "")
                        fflush(stdout)
                    case .processing:
                        print("\nMerging…")
                    case .finished(let result, let progress):
                        print("")
                        switch result {
                        case .completed(let outputs):
                            // A stream comes out as .mp4 with FFmpeg, otherwise as .ts.
                            let source = outputs.first ?? directory.appendingPathComponent(name + FileUtils.partSuffix)
                            let finalName = outputs.isEmpty ? name : FileUtils.uniqueName(
                                (name as NSString).deletingPathExtension + "." + source.pathExtension, in: directory)
                            let destination = directory.appendingPathComponent(finalName)
                            try? FileManager.default.moveItem(at: source, to: destination)
                            for extra in outputs.dropFirst() {
                                try? FileManager.default.moveItem(at: extra, to: directory.appendingPathComponent(
                                    FileUtils.uniqueName((name as NSString).deletingPathExtension + " (audio)." + extra.pathExtension, in: directory)))
                            }
                            try? FileManager.default.removeItem(at: workDirectory)
                            FileUtils.markAsDownloaded(destination, from: url, referrer: nil, agentName: "Nidestream")
                            let seconds = Date().timeIntervalSince(started)
                            print("Done: \(destination.path) — \(ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file)) in \(String(format: "%.1f", seconds)) s")
                            status.set(0)
                        case .stopped:
                            print("Stopped.")
                        case .failed(let message):
                            print("Failed: \(message)")
                        }
                        done.get()?.resume()
                    }
                }
                let runner: DownloadRunner
                if probe.isHLS {
                    runner = HLSDownloader(job: HLSJob(playlistURL: url, headers: headers, workDirectory: workDirectory, ffmpegPath: FFmpeg.path),
                                           limiters: [limiter], onEvent: sink)
                } else {
                    let job = HTTPJob(url: url, headers: headers, partURL: directory.appendingPathComponent(name + FileUtils.partSuffix),
                                      totalBytes: probe.totalBytes, resumable: probe.acceptsRanges, maxConnections: connections,
                                      validator: probe.validator)
                    runner = SegmentedDownloader(job: job, limiters: [limiter], onEvent: sink)
                }
                await withCheckedContinuation { continuation in
                    done.set(continuation)
                    runner.start()
                }
            } catch {
                print("Failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            }
            finished.signal()
        }
        finished.wait()
        return status.get()
    }
}

final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
}
