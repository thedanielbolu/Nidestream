import AppKit
import Observation
import SwiftDMCore

/// What a new download starts from: the dialog, the browser extension, the clipboard, a batch…
struct NewDownload {
    var url: URL
    var fileName: String?
    var directory: URL?
    var category: String?
    var referrer: String?
    var cookies: String?
    var userAgent: String?
    var connections: Int?
    var username: String?
    var password: String?
    var speedLimitKBps: Int?
    var kind: DownloadKind = .http
    var hlsVariantURL: URL?
    var hlsAudioURL: URL?
    var note: String?
    var totalBytes: Int64?
    var mimeType: String?
}

@MainActor @Observable
final class DownloadManager {
    static let shared = DownloadManager()

    private(set) var items: [DownloadItem] = []
    private(set) var queueRunning = false

    @ObservationIgnored let limiter = RateLimiter()
    @ObservationIgnored var onQueueFinished: (() -> Void)?
    @ObservationIgnored private var runners: [UUID: DownloadRunner] = [:]
    @ObservationIgnored private var runIDs: [UUID: UUID] = [:]
    @ObservationIgnored private var launches: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var queueDidWork = false

    private var prefs: Preferences { SettingsStore.shared.prefs }

    var totalSpeed: Double { items.reduce(0) { $0 + $1.speed } }
    var runningCount: Int { items.filter { $0.record.status.isRunning }.count }

    func item(_ id: UUID) -> DownloadItem? { items.first { $0.id == id } }

    // MARK: - Lifecycle

    func load() {
        let resume = prefs.resumeOnLaunch
        items = Persistence.loadDownloads().map { stored in
            var record = stored
            if record.status.isRunning {
                record.status = resume ? .queued : .paused
                record.startWhenPossible = resume
            }
            return DownloadItem(record: record)
        }
        applySettings()
        pump()
    }

    func applySettings() {
        limiter.bytesPerSecond = prefs.speedLimitEnabled ? max(1, prefs.speedLimitKBps) * 1024 : 0
        pump()
    }

    /// Called on quit: running downloads become paused (or queued) and the list is written synchronously.
    func prepareForQuit() {
        for item in items where item.record.status.isRunning {
            runners[item.id]?.stop()
            item.record.status = prefs.resumeOnLaunch ? .queued : .paused
        }
        Persistence.saveDownloads(items.map(\.record), synchronously: true)
    }

    // MARK: - Adding

    @discardableResult
    func add(_ new: NewDownload, start: Bool) -> DownloadItem {
        var name = new.fileName.map(HTTPHeaderParsing.sanitizeFileName)
            ?? HTTPHeaderParsing.suggestedFileName(url: new.url, contentDisposition: nil, mimeType: new.mimeType)
        if new.kind == .hls, ["m3u8", ""].contains((name as NSString).pathExtension.lowercased()) {
            name = (name as NSString).deletingPathExtension + ".mp4"
        }
        let category = new.category ?? FileCategory.detect(fileName: name, in: prefs.categories)
        let directory = new.directory ?? folder(for: category)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        name = FileUtils.uniqueName(name, in: directory, taken: reservedNames(in: directory))

        var record = DownloadRecord(url: new.url, fileName: name, directory: directory)
        record.autoName = new.fileName == nil
        record.kind = new.kind
        record.category = category
        record.referrer = new.referrer
        record.cookies = new.cookies
        record.userAgent = new.userAgent
        record.maxConnections = min(32, max(1, new.connections ?? prefs.connectionsPerDownload))
        record.username = new.username?.isEmpty == false ? new.username : nil
        record.speedLimitKBps = new.speedLimitKBps
        record.hlsVariantURL = new.hlsVariantURL
        record.hlsAudioURL = new.hlsAudioURL
        record.note = new.note
        record.totalBytes = new.totalBytes ?? -1
        record.mimeType = new.mimeType
        record.status = .queued
        record.startWhenPossible = start
        record.queuePosition = (items.map(\.record.queuePosition).max() ?? 0) + 1
        if record.username != nil, let password = new.password, !password.isEmpty {
            Keychain.set(password, account: Keychain.downloadAccount(record.id))
        }

        let item = DownloadItem(record: record)
        items.append(item)
        pump()
        save()
        return item
    }

    func folder(for categoryID: String) -> URL {
        if let custom = prefs.categories.first(where: { $0.id == categoryID })?.folder, !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return URL(fileURLWithPath: (prefs.downloadFolder as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Names claimed by unfinished downloads in `directory`, lowercased.
    private func reservedNames(in directory: URL, excluding id: UUID? = nil) -> Set<String> {
        let target = directory.standardizedFileURL.path
        return Set(items.filter {
            $0.id != id && $0.record.status != .completed && $0.record.directory.standardizedFileURL.path == target
        }.map { $0.record.fileName.lowercased() })
    }

    func existingDownload(for url: URL) -> DownloadItem? {
        items.first { $0.record.url == url }
    }

    // MARK: - Controls

    func resume(_ targets: [DownloadItem]) {
        for item in targets where [.paused, .failed, .queued].contains(item.record.status) {
            item.record.status = .queued
            item.record.startWhenPossible = true
            item.record.lastError = nil
        }
        pump()
        save()
    }

    func pause(_ targets: [DownloadItem]) {
        for item in targets where item.record.status != .completed && item.record.status != .paused {
            let wasRunning = item.record.status.isRunning
            item.record.status = .paused
            item.record.startWhenPossible = false
            if wasRunning { stopRunner(item) }
        }
        pump()
        save()
    }

    func pauseAll() {
        queueRunning = false
        pause(items.filter { $0.record.status.isRunning || ($0.record.status == .queued && $0.record.startWhenPossible) })
    }

    func resumeAll() {
        resume(items.filter { $0.record.status == .paused || $0.record.status == .failed })
    }

    func restart(_ targets: [DownloadItem]) {
        for item in targets {
            stopRunner(item)
            runIDs[item.id] = nil
            removePartialData(item.record)
            if item.record.status == .completed {
                item.record.fileName = FileUtils.uniqueName(item.record.fileName, in: item.record.directory,
                                                            taken: reservedNames(in: item.record.directory, excluding: item.id))
            }
            item.record.segments = []
            item.record.receivedBytes = 0
            item.record.resumable = false
            item.record.etag = nil
            item.record.lastModified = nil
            item.record.lastError = nil
            item.record.dateCompleted = nil
            item.record.status = .queued
            item.record.startWhenPossible = true
            item.speed = 0
            item.parts = nil
        }
        pump()
        save()
    }

    func remove(_ targets: [DownloadItem], deleteFiles: Bool) {
        let ids = Set(targets.map(\.id))
        for item in targets {
            stopRunner(item)
            runIDs[item.id] = nil
            if item.record.status == .completed {
                if deleteFiles { try? FileManager.default.trashItem(at: item.record.fileURL, resultingItemURL: nil) }
            } else {
                removePartialData(item.record)
            }
            Keychain.delete(account: Keychain.downloadAccount(item.id))
        }
        items.removeAll { ids.contains($0.id) }
        pump()
        save()
    }

    func removeCompleted() {
        remove(items.filter { $0.record.status == .completed }, deleteFiles: false)
    }

    /// "Refresh download address": point an unfinished download at a new link without losing progress.
    func updateAddress(_ item: DownloadItem, to url: URL) {
        let wasRunning = item.record.status.isRunning
        if wasRunning { stopRunner(item) }
        item.record.url = url
        if wasRunning {
            item.record.status = .queued
            item.record.startWhenPossible = true
        }
        pump()
        save()
    }

    func setPassword(_ password: String?, username: String?, for item: DownloadItem) {
        item.record.username = username?.isEmpty == false ? username : nil
        if let password, !password.isEmpty, item.record.username != nil {
            Keychain.set(password, account: Keychain.downloadAccount(item.id))
        } else {
            Keychain.delete(account: Keychain.downloadAccount(item.id))
        }
        save()
    }

    private func stopRunner(_ item: DownloadItem) {
        launches.removeValue(forKey: item.id)?.cancel()
        runners[item.id]?.stop()
        item.speed = 0
        item.activeSegments = []
    }

    private func removePartialData(_ record: DownloadRecord) {
        try? FileManager.default.removeItem(at: record.partURL)
        try? FileManager.default.removeItem(at: record.hlsWorkDirectory)
    }

    // MARK: - Queue

    var queuedItems: [DownloadItem] {
        items.filter { $0.record.status == .queued }.sorted { $0.record.queuePosition < $1.record.queuePosition }
    }

    func startQueue() {
        queueRunning = true
        queueDidWork = false
        pump()
    }

    func stopQueue() {
        queueRunning = false
        for item in items where item.record.status.isRunning && !item.record.startWhenPossible {
            item.record.status = .queued
            stopRunner(item)
        }
        pump()
        save()
    }

    func addToQueue(_ targets: [DownloadItem]) {
        var position = (items.map(\.record.queuePosition).max() ?? 0) + 1
        for item in targets where item.record.status == .paused || item.record.status == .failed {
            item.record.status = .queued
            item.record.startWhenPossible = false
            item.record.queuePosition = position
            position += 1
        }
        pump()
        save()
    }

    func moveQueue(from source: IndexSet, to destination: Int) {
        var ordered = queuedItems
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, item) in ordered.enumerated() { item.record.queuePosition = index + 1 }
        save()
    }

    /// Starts waiting downloads while there are free slots.
    func pump() {
        var free = prefs.maxSimultaneous - runningCount
        if free > 0 {
            let waiting = items.filter { $0.record.status == .queued && ($0.record.startWhenPossible || queueRunning) }
                .sorted { ($0.record.startWhenPossible ? 0 : 1, $0.record.queuePosition) < ($1.record.startWhenPossible ? 0 : 1, $1.record.queuePosition) }
            for item in waiting where free > 0 {
                if !item.record.startWhenPossible { queueDidWork = true }
                launch(item)
                free -= 1
            }
        }
        updateActivity()
        if queueRunning, !items.contains(where: { $0.record.status == .queued || $0.record.status.isRunning }) {
            queueRunning = false
            if queueDidWork { onQueueFinished?() }
        }
    }

    // MARK: - Running

    private func requestHeaders(for record: DownloadRecord) -> [String: String] {
        var headers = ["User-Agent": record.userAgent ?? prefs.userAgent, "Accept": "*/*"]
        if let referrer = record.referrer, !referrer.isEmpty { headers["Referer"] = referrer }
        if let cookies = record.cookies, !cookies.isEmpty { headers["Cookie"] = cookies }
        return headers
    }

    func credential(for record: DownloadRecord) -> URLCredential? {
        if let username = record.username, let password = Keychain.get(account: Keychain.downloadAccount(record.id)) {
            return URLCredential(user: username, password: password, persistence: .forSession)
        }
        let host = record.url.host?.lowercased() ?? ""
        if let login = prefs.siteLogins.first(where: { host == $0.host.lowercased() || host.hasSuffix("." + $0.host.lowercased()) }),
           let password = Keychain.get(account: login.keychainAccount) {
            return URLCredential(user: login.username, password: password, persistence: .forSession)
        }
        return nil
    }

    private func launch(_ item: DownloadItem) {
        let id = item.id
        let runID = UUID()
        runIDs[id] = runID
        item.record.status = .connecting
        item.record.lastError = nil
        item.lastTick = nil
        item.parts = nil

        let record = item.record
        let headers = requestHeaders(for: record)
        let credential = credential(for: record)
        let proxy = prefs.proxy
        let timeout = TimeInterval(prefs.timeoutSeconds)

        launches[id] = Task { [weak self] in
            do {
                var probe: ProbeResult?
                if record.kind == .http && record.receivedBytes == 0 {
                    probe = try await Prober.probe(url: record.url, headers: headers, credential: credential, proxy: proxy, timeout: timeout)
                }
                try Task.checkCancellation()
                guard let self, self.runIDs[id] == runID, let item = self.item(id) else { return }
                self.launches[id] = nil
                if let probe { self.apply(probe, to: item) }
                try self.checkDiskSpace(item.record)
                let runner = self.makeRunner(for: item, runID: runID, headers: headers, credential: credential)
                self.runners[id] = runner
                runner.start()
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                guard let self, self.runIDs[id] == runID, let item = self.item(id) else { return }
                self.launches[id] = nil
                self.runIDs[id] = nil
                item.record.status = .failed
                item.record.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                Notifier.downloadFailed(item)
                self.pump()
                self.save()
            }
        }
    }

    private func apply(_ probe: ProbeResult, to item: DownloadItem) {
        if probe.isHLS {
            item.record.kind = .hls
            if item.record.autoName || (item.record.fileName as NSString).pathExtension.lowercased() == "m3u8" {
                rename(item, to: (item.record.fileName as NSString).deletingPathExtension + ".mp4")
            }
            return
        }
        item.record.totalBytes = probe.totalBytes
        item.record.resumable = probe.acceptsRanges && probe.totalBytes > 0
        item.record.etag = probe.etag
        item.record.lastModified = probe.lastModified
        item.record.mimeType = probe.mimeType
        item.record.segments = []
        if item.record.autoName, probe.fileName != item.record.fileName {
            let oldCategory = item.record.category
            let category = FileCategory.detect(fileName: probe.fileName, in: prefs.categories)
            if item.record.directory.standardizedFileURL == folder(for: oldCategory).standardizedFileURL {
                item.record.directory = folder(for: category)
                try? FileManager.default.createDirectory(at: item.record.directory, withIntermediateDirectories: true)
            }
            item.record.category = category
            rename(item, to: probe.fileName)
        }
        item.record.autoName = false
    }

    private func rename(_ item: DownloadItem, to name: String) {
        item.record.fileName = FileUtils.uniqueName(HTTPHeaderParsing.sanitizeFileName(name), in: item.record.directory,
                                                    taken: reservedNames(in: item.record.directory, excluding: item.id))
    }

    private func checkDiskSpace(_ record: DownloadRecord) throws {
        guard record.totalBytes > 0, let free = FileUtils.availableCapacity(at: record.directory) else { return }
        if record.totalBytes - record.receivedBytes > free { throw DownloadError.notEnoughSpace }
    }

    private func makeRunner(for item: DownloadItem, runID: UUID, headers: [String: String], credential: URLCredential?) -> DownloadRunner {
        let record = item.record
        let id = item.id
        var limiters = [limiter]
        if let perFile = record.speedLimitKBps, perFile > 0 { limiters.append(RateLimiter(bytesPerSecond: perFile * 1024)) }
        let sink: @Sendable (RunnerEvent) -> Void = { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event, id: id, runID: runID) }
            }
        }
        switch record.kind {
        case .http:
            let job = HTTPJob(url: record.url, headers: headers, partURL: record.partURL, totalBytes: record.totalBytes,
                              resumable: record.resumable, segments: record.segments, maxConnections: record.maxConnections,
                              validator: record.validator, credential: credential, maxRetries: prefs.maxRetries,
                              timeout: TimeInterval(prefs.timeoutSeconds), proxy: prefs.proxy)
            return SegmentedDownloader(job: job, limiters: limiters, onEvent: sink)
        case .hls:
            let job = HLSJob(playlistURL: record.url, variantURL: record.hlsVariantURL, audioURL: record.hlsAudioURL,
                             headers: headers, workDirectory: record.hlsWorkDirectory, concurrency: min(16, record.maxConnections),
                             maxRetries: prefs.maxRetries, timeout: TimeInterval(prefs.timeoutSeconds), proxy: prefs.proxy,
                             ffmpegPath: prefs.remuxToMP4 ? FFmpeg.path : nil)
            return HLSDownloader(job: job, limiters: limiters, onEvent: sink)
        }
    }

    private func handle(_ event: RunnerEvent, id: UUID, runID: UUID) {
        guard runIDs[id] == runID, let item = item(id) else { return }
        switch event {
        case .progress(let progress):
            apply(progress, to: item)
            if item.record.status == .connecting { item.record.status = .downloading }
            if Date().timeIntervalSince(lastSave) > 5 { save() }
        case .processing:
            item.record.status = .processing
            item.speed = 0
        case .finished(let result, let progress):
            apply(progress, to: item)
            runners[id] = nil
            runIDs[id] = nil
            item.speed = 0
            item.activeSegments = []
            switch result {
            case .completed(let outputs):
                finalize(item, outputs: outputs)
            case .stopped:
                if item.record.status.isRunning { item.record.status = .paused }
            case .failed(let message):
                item.record.status = .failed
                item.record.lastError = message
                Notifier.downloadFailed(item)
            }
            pump()
            save()
        }
    }

    private func apply(_ progress: DownloadProgress, to item: DownloadItem) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = item.lastTick {
            let elapsed = now - last.time
            if elapsed > 0.2 {
                let instant = max(0, Double(progress.receivedBytes - last.bytes) / elapsed)
                item.speed = item.speed == 0 ? instant : item.speed * 0.6 + instant * 0.4
                item.lastTick = (now, progress.receivedBytes)
            }
        } else {
            item.lastTick = (now, progress.receivedBytes)
        }
        item.record.receivedBytes = progress.receivedBytes
        if progress.totalBytes >= 0 { item.record.totalBytes = progress.totalBytes }
        if let segments = progress.segments { item.record.segments = segments }
        item.record.resumable = progress.resumable
        item.activeSegments = progress.activeSegments
        if let done = progress.partsDone, let total = progress.partsTotal, total > 0 { item.parts = (done, total) }
    }

    private func finalize(_ item: DownloadItem, outputs: [URL]) {
        let fm = FileManager.default
        var record = item.record
        let taken = reservedNames(in: record.directory, excluding: item.id)
        do {
            if outputs.isEmpty {
                let name = FileUtils.uniqueName(record.fileName, in: record.directory, taken: taken, checkPartFiles: false)
                try fm.moveItem(at: record.partURL, to: record.directory.appendingPathComponent(name))
                record.fileName = name
            } else {
                let base = (record.fileName as NSString).deletingPathExtension
                for (index, output) in outputs.enumerated() {
                    let desired = index == 0 ? "\(base).\(output.pathExtension)" : "\(base) (audio).\(output.pathExtension)"
                    let name = FileUtils.uniqueName(desired, in: record.directory, taken: taken, checkPartFiles: false)
                    try fm.moveItem(at: output, to: record.directory.appendingPathComponent(name))
                    if index == 0 { record.fileName = name }
                }
                try? fm.removeItem(at: item.record.hlsWorkDirectory)
            }
            FileUtils.markAsDownloaded(record.fileURL, from: record.url, referrer: record.referrer, agentName: "SwiftDM")
            if let size = (try? record.fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                record.totalBytes = Int64(size)
                record.receivedBytes = Int64(size)
            }
            record.status = .completed
            record.dateCompleted = Date()
            record.segments = []
            record.cookies = nil
            item.record = record
            item.parts = nil
            Notifier.downloadFinished(item)
        } catch {
            item.record.status = .failed
            item.record.lastError = "Couldn't save the file: \(error.localizedDescription)"
        }
    }

    /// Keeps the Mac (optionally) awake and the app out of App Nap while anything downloads.
    private func updateActivity() {
        let running = runningCount
        NSApp?.dockTile.badgeLabel = running > 0 ? String(running) : nil
        if running > 0, activity == nil {
            let options: ProcessInfo.ActivityOptions = prefs.preventSleep ? [.userInitiated, .idleSystemSleepDisabled] : [.userInitiatedAllowingIdleSystemSleep]
            activity = ProcessInfo.processInfo.beginActivity(options: options, reason: "Downloading files")
        } else if running == 0, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }

    func save() {
        lastSave = Date()
        Persistence.saveDownloads(items.map(\.record))
    }
}
