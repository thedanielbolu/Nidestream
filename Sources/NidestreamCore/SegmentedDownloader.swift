import Foundation

public struct HTTPJob: Sendable {
    public var url: URL
    public var headers: [String: String]
    public var partURL: URL
    public var totalBytes: Int64
    public var resumable: Bool
    public var segments: [Segment]
    public var maxConnections: Int
    public var validator: String?
    public var credential: URLCredential?
    public var maxRetries: Int
    public var timeout: TimeInterval
    public var proxy: ProxySettings
    public var minSegmentSize: Int64
    /// Connections to open at first; more are added while they make the download faster.
    public var initialConnections: Int
    /// How long each speed measurement for adding or dropping connections lasts.
    public var adaptiveWindow: TimeInterval

    public init(url: URL, headers: [String: String] = [:], partURL: URL, totalBytes: Int64, resumable: Bool,
                segments: [Segment] = [], maxConnections: Int = 8, validator: String? = nil, credential: URLCredential? = nil,
                maxRetries: Int = 8, timeout: TimeInterval = 30, proxy: ProxySettings = .system,
                minSegmentSize: Int64 = SegmentPlanner.minimumSegmentSize, initialConnections: Int = 4,
                adaptiveWindow: TimeInterval = 2) {
        self.url = url
        self.headers = headers
        self.partURL = partURL
        self.totalBytes = totalBytes
        self.resumable = resumable
        self.segments = segments
        self.maxConnections = maxConnections
        self.validator = validator
        self.credential = credential
        self.maxRetries = maxRetries
        self.timeout = timeout
        self.proxy = proxy
        self.minSegmentSize = minSegmentSize
        self.initialConnections = initialConnections
        self.adaptiveWindow = adaptiveWindow
    }
}

/// Multi-connection HTTP downloader with dynamic segmentation, resume and throttling.
///
/// Every connection slot owns its own `URLSession`, so each range really travels over its own
/// TCP connection (one shared session would multiplex them onto a single HTTP/2 connection).
/// All mutable state is confined to `queue`; URLSession delegate callbacks run on it too.
///
/// The number of connections adapts: it starts at `initialConnections` and grows only while extra
/// connections make the download faster. Many servers throttle each connection, so more is faster,
/// but some slow every connection down when there are many, so more would be slower.
///
/// Speed limiting paces requests rather than suspending tasks: URLSession keeps delivering
/// data to a suspended task, so while a limit is set each connection asks for about a second's
/// worth of bytes at a time and waits for the limiter before asking for the next slice.
public final class SegmentedDownloader: NSObject, DownloadRunner, URLSessionDataDelegate, @unchecked Sendable {
    private enum State { case idle, running, done }

    private struct Connection {
        /// Nil while a paced request waits for its turn.
        var task: URLSessionDataTask?
        let slot: Int
        /// Inclusive end of the byte range this request asked for (-1: to the end of the stream).
        let requestEnd: Int64
        let paced: Bool
        let token: UUID
        let launchedAt: TimeInterval
    }

    private let job: HTTPJob
    private let limiters: [RateLimiter]
    private let onEvent: @Sendable (RunnerEvent) -> Void
    private let queue: DispatchQueue
    private let delegateQueue: OperationQueue

    private var state = State.idle
    private var segments: [Segment]
    private var totalBytes: Int64
    private var resumable: Bool
    private var connectionLimit: Int
    /// Most connections allowed: the job's maximum, lowered if the server pushes back.
    private var ceiling: Int
    private var windowStart: TimeInterval = 0
    /// Bytes received when the current measurement started; -1 while waiting for connections to warm up.
    private var windowReceived: Int64 = -1
    /// Connections added on trial: kept only if the next measurement is clearly faster.
    private var trial: (previousLimit: Int, baseline: Double)?
    private var holdUntil: TimeInterval = 0
    private var sessions: [URLSession] = []
    private var idleSlots: [Int] = []
    private var connections: [Int: Connection] = [:]
    private var segmentForTask: [ObjectIdentifier: Int] = [:]
    private var failures: [Int: Int] = [:]
    private var coolingUntil: [Int: TimeInterval] = [:]
    /// Single-stream downloads (no ranges) can't be paced, so they fall back to suspending.
    private var suspendedUntil: [ObjectIdentifier: TimeInterval] = [:]
    private var fd: Int32 = -1
    private var timer: DispatchSourceTimer?
    private let started = ProcessInfo.processInfo.systemUptime
    /// Set NIDESTREAM_DEBUG=1 to trace connections on stderr.
    private static let debugging = ProcessInfo.processInfo.environment["NIDESTREAM_DEBUG"] != nil

    private func trace(_ message: @autoclosure () -> String) {
        guard Self.debugging else { return }
        let line = String(format: "[%6.2f] ", ProcessInfo.processInfo.systemUptime - started) + message() + "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    public init(job: HTTPJob, limiters: [RateLimiter], onEvent: @escaping @Sendable (RunnerEvent) -> Void) {
        self.job = job
        self.limiters = limiters
        self.onEvent = onEvent
        let queue = DispatchQueue(label: "nidestream.download", qos: .utility)
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        self.queue = queue
        self.delegateQueue = delegateQueue
        segments = job.segments
        totalBytes = job.totalBytes
        resumable = job.resumable && job.totalBytes > 0
        ceiling = max(1, job.maxConnections)
        connectionLimit = min(ceiling, max(1, job.initialConnections))
        super.init()
    }

    public func start() {
        queue.async { self.begin() }
    }

    public func stop() {
        queue.async {
            guard self.state != .done else { return }
            self.state = .done
            self.teardown()
            self.onEvent(.finished(.stopped, self.snapshot()))
        }
    }

    // MARK: - Scheduling

    private func begin() {
        guard state == .idle else { return }
        state = .running
        fd = open(job.partURL.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            return fail(DownloadError.io("Can't write \(job.partURL.lastPathComponent): \(String(cString: strerror(errno)))"))
        }
        var info = stat()
        let fileSize = fstat(fd, &info) == 0 ? Int64(info.st_size) : 0
        // Partial data only counts if the preallocated file is still there.
        let hasProgress = segments.contains { $0.received > 0 } && fileSize >= totalBytes
        if segments.isEmpty || !resumable || !hasProgress {
            segments = SegmentPlanner.initialSegments(totalBytes: totalBytes, connections: resumable ? connectionLimit : 1,
                                                      minSize: job.minSegmentSize)
            // Sparse preallocation for ranged downloads; a plain stream just grows the file.
            _ = ftruncate(fd, off_t(resumable ? totalBytes : 0))
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self, self.state == .running else { return }
            self.adapt()
            self.onEvent(.progress(self.snapshot()))
        }
        timer.resume()
        self.timer = timer
        windowStart = ProcessInfo.processInfo.systemUptime + warmup
        schedule()
    }

    private var limiting: Bool { limiters.contains { $0.bytesPerSecond > 0 } }

    /// About one second of data per connection at the current limit.
    private var sliceSize: Int64 {
        let rate = limiters.map(\.bytesPerSecond).filter { $0 > 0 }.min() ?? 0
        return min(4 << 20, max(64 << 10, Int64(rate) / Int64(max(1, connectionLimit))))
    }

    private func schedule() {
        guard state == .running else { return }
        if segments.allSatisfy(\.isComplete) { return complete() }

        let now = ProcessInfo.processInfo.systemUptime
        let cooling = Set(coolingUntil.filter { $0.value > now }.keys)
        let limit = resumable ? connectionLimit : 1
        while connections.count < limit {
            if let index = SegmentPlanner.nextIdle(segments, active: Set(connections.keys), excluding: cooling) {
                launch(index)
                continue
            }
            // Don't open more connections while some are failing.
            if resumable, cooling.isEmpty,
               let index = SegmentPlanner.split(&segments, active: Set(connections.keys), minSize: job.minSegmentSize) {
                launch(index)
                continue
            }
            break
        }
    }

    private func launch(_ index: Int) {
        trace("launch segment \(index) \(segments[index].position)-\(segments[index].end), \(connections.count + 1) connections")
        let slot = idleSlots.popLast() ?? makeSlot()
        if !resumable { segments[index].received = 0 }
        let segment = segments[index]
        let paced = resumable && limiting
        var requestEnd = segment.end
        var wait: TimeInterval = 0
        if paced {
            requestEnd = min(segment.end, segment.position + sliceSize - 1)
            wait = limiters.map { $0.consume(Int(requestEnd - segment.position + 1)) }.max() ?? 0
        }
        let token = UUID()
        connections[index] = Connection(task: nil, slot: slot, requestEnd: requestEnd, paced: paced, token: token,
                                        launchedAt: ProcessInfo.processInfo.systemUptime)
        if wait > 0.001 {
            queue.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self, self.state == .running, self.connections[index]?.token == token else { return }
                self.send(index)
            }
        } else {
            send(index)
        }
    }

    private func send(_ index: Int) {
        guard var connection = connections[index] else { return }
        let segment = segments[index]
        var request = URLRequest(url: job.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: job.timeout)
        for (name, value) in job.headers { request.setValue(value, forHTTPHeaderField: name) }
        // Byte offsets must refer to the file itself, never to a compressed transfer encoding.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if resumable {
            let end = min(connection.requestEnd, segment.end)
            request.setValue(end >= 0 ? "bytes=\(segment.position)-\(end)" : "bytes=\(segment.position)-", forHTTPHeaderField: "Range")
            if let validator = job.validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
        }
        let task = sessions[connection.slot].dataTask(with: request)
        connection.task = task
        connections[index] = connection
        segmentForTask[ObjectIdentifier(task)] = index
        task.resume()
    }

    private func makeSlot() -> Int {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = job.timeout
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        configuration.httpMaximumConnectionsPerHost = 2
        job.proxy.apply(to: configuration)
        sessions.append(URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue))
        return sessions.count - 1
    }

    /// Detaches a connection from its segment. Callbacks for its task are ignored from then on.
    @discardableResult
    private func release(_ index: Int) -> Connection? {
        guard let connection = connections.removeValue(forKey: index) else { return nil }
        if let task = connection.task {
            segmentForTask[ObjectIdentifier(task)] = nil
            suspendedUntil[ObjectIdentifier(task)] = nil
        }
        idleSlots.append(connection.slot)
        return connection
    }

    // MARK: - Completion

    private func complete() {
        guard state == .running else { return }
        if totalBytes >= 0 { _ = ftruncate(fd, off_t(totalBytes)) }
        _ = fsync(fd)
        state = .done
        teardown()
        onEvent(.finished(.completed(outputs: []), snapshot()))
    }

    private func fail(_ error: Error) {
        guard state == .running else { return }
        state = .done
        teardown()
        onEvent(.finished(.failed(describe(error)), snapshot()))
    }

    private func teardown() {
        timer?.cancel()
        timer = nil
        for connection in connections.values { connection.task?.cancel() }
        connections.removeAll()
        segmentForTask.removeAll()
        for session in sessions { session.invalidateAndCancel() }
        sessions.removeAll()
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    private func snapshot() -> DownloadProgress {
        let received = segments.isEmpty ? max(0, totalBytes) : segments.reduce(0) { $0 + $1.received }
        return DownloadProgress(receivedBytes: received, totalBytes: totalBytes, segments: segments,
                                activeSegments: connections.keys.sorted(), resumable: resumable)
    }

    // MARK: - Adaptive connections

    private func adapt() {
        guard resumable, !limiting, ceiling > 1 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let received = segments.reduce(0) { $0 + $1.received }
        if windowReceived < 0 {
            // Start measuring once the current connections have had a moment to get going.
            if now >= windowStart {
                windowStart = now
                windowReceived = received
            }
            return
        }
        let elapsed = now - windowStart
        guard elapsed >= job.adaptiveWindow else { return }
        let rate = Double(received - windowReceived) / elapsed
        windowStart = now
        windowReceived = received

        if let pending = trial {
            trial = nil
            if rate < pending.baseline * 1.1 {
                trace("\(connectionLimit) connections weren't faster (\(Int(rate)) vs \(Int(pending.baseline)) B/s): back to \(pending.previousLimit)")
                connectionLimit = pending.previousLimit
                shedExtraConnections()
                holdUntil = now + 20
                windowStart = now + warmup
                windowReceived = -1
                return
            }
            trace("keeping \(connectionLimit) connections (\(Int(rate)) vs \(Int(pending.baseline)) B/s)")
        }

        let remaining = totalBytes - received
        let allBusy = connections.count >= connectionLimit
        guard allBusy, connectionLimit < ceiling, now >= holdUntil,
              remaining > Int64(connectionLimit * 2) * job.minSegmentSize * 4 else { return }
        trial = (connectionLimit, rate)
        connectionLimit = min(ceiling, connectionLimit + max(2, connectionLimit / 2))
        trace("trying \(connectionLimit) connections (at \(Int(rate)) B/s)")
        schedule()
        // Give the new connections a moment to start before judging them.
        windowStart = now + warmup
        windowReceived = -1
    }

    /// Time for new connections to get going before measuring.
    private var warmup: TimeInterval { min(1, job.adaptiveWindow) }

    /// Closes the newest connections beyond the limit; their ranges continue later.
    private func shedExtraConnections() {
        let extra = connections.count - connectionLimit
        guard extra > 0 else { return }
        for (index, connection) in connections.sorted(by: { $0.value.launchedAt > $1.value.launchedAt }).prefix(extra) {
            release(index)
            connection.task?.cancel()
        }
    }

    // MARK: - Failures

    private func failSegment(_ index: Int, _ error: Error) {
        trace("segment \(index) failed: \(describe(error)) [\((error as NSError).code)] at \(segments[index].position)")
        release(index)?.task?.cancel()
        guard state == .running else { return }
        guard isRetryable(error) else { return fail(error) }
        let count = (failures[index] ?? 0) + 1
        failures[index] = count
        if count > job.maxRetries { return fail(DownloadError.tooManyRetries(describe(error))) }
        let delay = min(30, pow(2, Double(count - 1)))
        coolingUntil[index] = ProcessInfo.processInfo.systemUptime + delay
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.schedule() }
        schedule()
    }

    private func handleBadStatus(_ index: Int, status: Int) {
        trace("segment \(index) got HTTP \(status) with \(connections.count) connections")
        if [403, 429, 503].contains(status), connections.count > 1 {
            // The server limits parallel connections: settle for what it tolerates.
            release(index)?.task?.cancel()
            ceiling = max(1, connections.count)
            connectionLimit = min(connectionLimit, ceiling)
            trial = nil
            coolingUntil[index] = ProcessInfo.processInfo.systemUptime + 2
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.schedule() }
            return
        }
        failSegment(index, DownloadError.http(status))
    }

    /// The server ignored our Range header (or If-Range found a changed file) and is sending the
    /// whole file. Keep this connection and continue as a single stream from byte 0.
    private func continueAsSingleStream(_ task: URLSessionDataTask, index: Int, contentLength: Int64) {
        guard let kept = connections[index] else { return }
        for (other, connection) in connections where other != index {
            release(other)
            connection.task?.cancel()
        }
        totalBytes = contentLength > 0 ? contentLength : -1
        segments = [Segment(id: 0, start: 0, end: totalBytes > 0 ? totalBytes - 1 : -1)]
        resumable = false
        connections = [0: Connection(task: task, slot: kept.slot, requestEnd: -1, paced: false, token: kept.token, launchedAt: kept.launchedAt)]
        segmentForTask = [ObjectIdentifier(task): 0]
        failures.removeAll()
        coolingUntil.removeAll()
        _ = ftruncate(fd, 0)
    }

    // MARK: - URLSessionDataDelegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard state == .running, let index = segmentForTask[ObjectIdentifier(dataTask)] else {
            return completionHandler(.cancel)
        }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return failSegment(index, DownloadError.invalidResponse)
        }
        let segment = segments[index]
        switch http.statusCode {
        case 206:
            if let range = http.value(forHTTPHeaderField: "Content-Range").flatMap(HTTPHeaderParsing.contentRange) {
                if let total = range.total, totalBytes > 0, total != totalBytes {
                    completionHandler(.cancel)
                    return fail(DownloadError.fileChanged)
                }
                if range.start != segment.position {
                    completionHandler(.cancel)
                    return failSegment(index, DownloadError.invalidResponse)
                }
            }
            completionHandler(.allow)
        case 200..<300:
            if segment.position == 0 && segments.count == 1 && !resumable {
                if totalBytes < 0, http.expectedContentLength > 0 {
                    totalBytes = http.expectedContentLength
                    segments[index].end = totalBytes - 1
                }
            } else {
                continueAsSingleStream(dataTask, index: index, contentLength: http.expectedContentLength)
            }
            completionHandler(.allow)
        default:
            completionHandler(.cancel)
            handleBadStatus(index, status: http.statusCode)
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let key = ObjectIdentifier(dataTask)
        guard state == .running, let index = segmentForTask[key], let connection = connections[index] else { return }
        let segment = segments[index]
        // A split may have moved this segment's end below what the request asked for.
        var allowed = Int64(data.count)
        if segment.end >= 0 { allowed = min(allowed, segment.remaining) }
        if connection.requestEnd >= 0 { allowed = min(allowed, connection.requestEnd - segment.position + 1) }
        let count = Int(max(0, allowed))
        if count > 0 {
            do {
                try write(data, count: count, at: segment.position)
            } catch {
                return fail(error)
            }
            segments[index].received += Int64(count)
            failures[index] = nil
        }
        if segments[index].isComplete {
            release(index)
            dataTask.cancel()
            return schedule()
        }
        guard !connection.paced, limiting else { return }
        if resumable {
            // The limiter was switched on mid-request: continue with paced slices.
            if segments[index].remaining > sliceSize {
                release(index)
                dataTask.cancel()
                schedule()
            }
            return
        }
        throttleBySuspending(dataTask, bytes: count)
    }

    private func throttleBySuspending(_ task: URLSessionDataTask, bytes: Int) {
        let delay = limiters.map { $0.consume(bytes) }.max() ?? 0
        guard delay > 0.005 else { return }
        let key = ObjectIdentifier(task)
        let until = ProcessInfo.processInfo.systemUptime + delay
        if let current = suspendedUntil[key] {
            suspendedUntil[key] = max(current, until)
            return
        }
        suspendedUntil[key] = until
        task.suspend()
        resumeWhenAllowed(task)
    }

    private func resumeWhenAllowed(_ task: URLSessionDataTask) {
        let key = ObjectIdentifier(task)
        guard let until = suspendedUntil[key] else { return }
        queue.asyncAfter(deadline: .now() + max(0, until - ProcessInfo.processInfo.systemUptime)) { [weak self] in
            guard let self, let until = self.suspendedUntil[key] else { return }
            if until > ProcessInfo.processInfo.systemUptime + 0.001 { return self.resumeWhenAllowed(task) }
            self.suspendedUntil[key] = nil
            guard self.state == .running, self.segmentForTask[key] != nil else { return }
            task.resume()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard state == .running, let index = segmentForTask[ObjectIdentifier(task)] else { return }
        if let error { return failSegment(index, error) }
        guard let connection = release(index) else { return }
        if segments[index].end < 0 {
            // A stream of unknown length ended cleanly: what arrived is the whole file.
            let received = segments[index].received
            totalBytes = received
            segments = received > 0 ? [Segment(id: 0, start: 0, end: received - 1, received: received)] : []
        } else if !segments[index].isComplete {
            let sliceDone = connection.paced && segments[index].position > connection.requestEnd
            if !sliceDone { return failSegment(index, DownloadError.incomplete) }
        }
        schedule()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let credential = job.credential, CredentialDelegate.acceptsPassword(challenge), challenge.previousFailureCount == 0 {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: - Disk

    private func write(_ data: Data, count: Int, at offset: Int64) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < count {
                let result = pwrite(fd, base + written, count - written, off_t(offset) + off_t(written))
                if result < 0 {
                    if errno == EINTR { continue }
                    throw DownloadError.io(String(cString: strerror(errno)))
                }
                written += result
            }
        }
    }
}
