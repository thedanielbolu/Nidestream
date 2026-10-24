import CoreServices
import Foundation

/// Token bucket shared by every connection it throttles. A rate of 0 means unlimited.
public final class RateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var rate: Double
    private var tokens: Double
    private var lastRefill: TimeInterval

    public init(bytesPerSecond: Int = 0) {
        rate = Double(max(0, bytesPerSecond))
        tokens = rate / 4
        lastRefill = ProcessInfo.processInfo.systemUptime
    }

    public var bytesPerSecond: Int {
        get { lock.withLock { Int(rate) } }
        set {
            lock.withLock {
                rate = Double(max(0, newValue))
                tokens = min(tokens, rate / 4)
            }
        }
    }

    /// Records `count` received bytes and returns how long the caller should pause reading.
    public func consume(_ count: Int) -> TimeInterval {
        lock.withLock {
            guard rate > 0 else { return 0 }
            let now = ProcessInfo.processInfo.systemUptime
            tokens = min(rate / 4, tokens + (now - lastRefill) * rate)
            lastRefill = now
            tokens -= Double(count)
            return tokens >= 0 ? 0 : -tokens / rate
        }
    }
}

public struct ProxySettings: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case system, none, http, socks
    }

    public var mode: Mode = .system
    public var host = ""
    public var port = 8080

    public init(mode: Mode = .system, host: String = "", port: Int = 8080) {
        self.mode = mode
        self.host = host
        self.port = port
    }

    public static let system = ProxySettings()

    public func apply(to configuration: URLSessionConfiguration) {
        switch mode {
        case .system:
            break
        case .none:
            configuration.connectionProxyDictionary = [:]
        case .http:
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: host,
                kCFNetworkProxiesHTTPSPort as String: port,
            ]
        case .socks:
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesSOCKSEnable as String: 1,
                kCFNetworkProxiesSOCKSProxy as String: host,
                kCFNetworkProxiesSOCKSPort as String: port,
            ]
        }
    }
}

public enum FileUtils {
    public static let partSuffix = ".nidestream"

    /// Returns `name`, or `name (1)`, `name (2)`… whichever is free in `directory`.
    /// `taken` holds lowercased names already claimed by other downloads.
    public static func uniqueName(_ name: String, in directory: URL, taken: Set<String> = [], checkPartFiles: Bool = true) -> String {
        let fm = FileManager.default
        func isFree(_ candidate: String) -> Bool {
            if taken.contains(candidate.lowercased()) { return false }
            if fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) { return false }
            if checkPartFiles, fm.fileExists(atPath: directory.appendingPathComponent(candidate + partSuffix).path) { return false }
            return true
        }
        if isFree(name) { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var index = 1
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            if isFree(candidate) { return candidate }
            index += 1
        }
    }

    /// Tags a finished file like Safari does: "Where from" metadata, plus the quarantine flag so
    /// Gatekeeper and XProtect check apps and disk images the first time they're opened.
    public static func markAsDownloaded(_ file: URL, from source: URL, referrer: String?, agentName: String) {
        var origins = [source.absoluteString]
        if let referrer, !referrer.isEmpty { origins.append(referrer) }
        if let data = try? PropertyListSerialization.data(fromPropertyList: origins, format: .binary, options: 0) {
            _ = data.withUnsafeBytes { buffer in
                setxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", buffer.baseAddress, buffer.count, 0, 0)
            }
        }
        var properties: [String: Any] = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: agentName,
            kLSQuarantineDataURLKey as String: source,
        ]
        if let referrer, let origin = URL(string: referrer) {
            properties[kLSQuarantineOriginURLKey as String] = origin
        }
        try? (file as NSURL).setResourceValue(properties, forKey: .quarantinePropertiesKey)
    }

    public static func availableCapacity(at directory: URL) -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// Supplies a username/password to HTTP auth challenges for a single task.
final class CredentialDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let credential: URLCredential

    init(credential: URLCredential) {
        self.credential = credential
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if Self.acceptsPassword(challenge), challenge.previousFailureCount == 0 {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    static func acceptsPassword(_ challenge: URLAuthenticationChallenge) -> Bool {
        let method = challenge.protectionSpace.authenticationMethod
        return [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM,
                NSURLAuthenticationMethodNegotiate, NSURLAuthenticationMethodDefault].contains(method)
    }
}

/// Events every download engine reports, always delivered in order from one queue.
public enum RunnerEvent: Sendable {
    case progress(DownloadProgress)
    case processing
    case finished(RunnerResult, DownloadProgress)
}

public enum RunnerResult: Sendable, Equatable {
    /// `outputs` lists finished files in a work directory; empty means the `.nidestream` file is the result.
    case completed(outputs: [URL])
    case stopped
    case failed(String)
}

public struct DownloadProgress: Sendable {
    public var receivedBytes: Int64
    public var totalBytes: Int64
    public var segments: [Segment]?
    public var activeSegments: [Int]
    public var resumable: Bool
    public var partsDone: Int?
    public var partsTotal: Int?

    public init(receivedBytes: Int64, totalBytes: Int64, segments: [Segment]?, activeSegments: [Int], resumable: Bool,
                partsDone: Int? = nil, partsTotal: Int? = nil) {
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.segments = segments
        self.activeSegments = activeSegments
        self.resumable = resumable
        self.partsDone = partsDone
        self.partsTotal = partsTotal
    }

    public var connections: Int { activeSegments.count }
}

public protocol DownloadRunner: AnyObject, Sendable {
    func start()
    /// Pauses: closes connections and reports `.finished(.stopped, …)` with the final state.
    func stop()
}

func isRetryable(_ error: Error) -> Bool {
    if let error = error as? DownloadError {
        switch error {
        case .http(let code): return code == 408 || code == 429 || code >= 500
        case .invalidResponse, .incomplete: return true
        default: return false
        }
    }
    if let error = error as? URLError {
        switch error.code {
        case .badURL, .unsupportedURL, .userAuthenticationRequired, .userCancelledAuthentication,
             .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired,
             .appTransportSecurityRequiresSecureConnection, .fileDoesNotExist, .noPermissionsToReadFile,
             .dataLengthExceedsMaximum, .cancelled:
            return false
        default:
            return true
        }
    }
    return true
}

func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}
