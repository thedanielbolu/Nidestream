import Foundation
import Network
import Observation
import NidestreamCore

/// Local HTTP endpoint the browser extension talks to. It only listens on 127.0.0.1.
final class BrowserBridge: @unchecked Sendable {
    static let shared = BrowserBridge()
    static let port: UInt16 = 51515

    private let queue = DispatchQueue(label: "nidestream.bridge")
    private var listener: NWListener?

    func start() {
        do {
            let parameters = NWParameters.tcp
            // Bind to IPv4 loopback only: unreachable from the network, and matches the extension's address.
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
            (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
            parameters.acceptLocalOnly = true
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { state in
                DispatchQueue.main.async { MainActor.assumeIsolated { BridgeStatus.shared.update(state) } }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { BridgeStatus.shared.message = "Couldn't start: \(error.localizedDescription)" }
            }
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
        // Drop clients that never finish sending a request.
        queue.asyncAfter(deadline: .now() + 15) { connection.cancel() }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .complete(let request):
                DispatchQueue.main.async {
                    let response = MainActor.assumeIsolated { BridgeRouter.handle(request) }
                    BridgeLog.record(request, status: response.status)
                    connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
                }
            case .incomplete where !isComplete && error == nil:
                self.receive(on: connection, buffer: buffer)
            default:
                if !buffer.isEmpty { BridgeLog.write("unreadable request (\(buffer.count) bytes)") }
                connection.cancel()
            }
        }
    }
}

/// One line per request the browser bridge receives (no bodies, cookies or URLs of downloads),
/// so "the extension isn't taking downloads" can be diagnosed: ~/Library/Logs/Nidestream/bridge.log
enum BridgeLog {
    private static let queue = DispatchQueue(label: "nidestream.bridge-log")
    static var file: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Nidestream/bridge.log")
    }

    static func record(_ request: HTTPRequest, status: Int) {
        let origin = request.headers["origin"] ?? "-"
        let host = request.headers["host"] ?? "-"
        let preflight = request.headers["access-control-request-private-network"] != nil ? " private-network-preflight" : ""
        write("\(request.method) \(request.path) origin=\(origin) host=\(host)\(preflight) → \(status)")
    }

    static func write(_ line: String) {
        let stamped = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 1_000_000 {
                try? fm.removeItem(at: file)
            }
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(Data(stamped.utf8))
                try? handle.close()
            } else {
                try? Data(stamped.utf8).write(to: file)
            }
        }
    }
}

@MainActor @Observable
final class BridgeStatus {
    static let shared = BridgeStatus()
    var listening = false
    var message = "Starting…"
    var lastContact: Date?

    func update(_ state: NWListener.State) {
        switch state {
        case .ready:
            listening = true
            message = "Listening on 127.0.0.1:\(BrowserBridge.port)"
        case .waiting(let error), .failed(let error):
            listening = false
            message = "Not listening: \(error.localizedDescription). Is another copy of Nidestream running?"
        case .cancelled:
            listening = false
            message = "Stopped"
        default:
            break
        }
    }
}

private struct AddPayload: Decodable {
    var url: String
    var referrer: String?
    var cookies: String?
    var userAgent: String?
    var fileName: String?
    var fileSize: Int64?
    var mime: String?
    var pageTitle: String?
    var kind: String?
}

private struct HelloPayload: Decodable {
    var browser: String
    var version: String?
}

private struct LinksPayload: Decodable {
    struct Link: Decodable {
        var url: String
        var text: String?
        var type: String?
        var size: Int64?
    }

    var links: [Link]
    var referrer: String?
    var cookies: [String: String]?
    var userAgent: String?
    var pageTitle: String?
    var source: String?
}

@MainActor
enum BridgeRouter {
    private static var prefs: Preferences { SettingsStore.shared.prefs }

    static func handle(_ request: HTTPRequest) -> HTTPResponse {
        // Reject anything not addressed to us by loopback name (DNS rebinding) and any web page origin.
        let host = request.headers["host"]?.lowercased() ?? ""
        guard host == "127.0.0.1:\(BrowserBridge.port)" || host == "localhost:\(BrowserBridge.port)" else {
            return HTTPResponse(status: 403)
        }
        let origin = request.headers["origin"]
        if let origin, !isExtensionOrigin(origin) { return HTTPResponse(status: 403) }
        let cors = origin.map { ["Access-Control-Allow-Origin": $0, "Vary": "Origin"] } ?? [:]

        if request.method == "OPTIONS" {
            return HTTPResponse(status: 204, headers: cors.merging([
                "Access-Control-Allow-Methods": "GET, POST",
                "Access-Control-Allow-Headers": "Content-Type",
            ]) { a, _ in a })
        }
        BridgeStatus.shared.lastContact = Date()

        switch (request.method, request.path) {
        case ("GET", "/ping"):
            return .json(["app": "Nidestream", "version": appVersion], headers: cors)
        case ("GET", "/config"):
            return .json(["capture": prefs.browserCapture, "extensions": prefs.captureExtensions,
                          "minSizeKB": prefs.minCaptureSizeKB, "version": appVersion], headers: cors)
        case ("POST", let path):
            // Forms can't send JSON, so this also blocks cross-site form posts.
            guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
                return HTTPResponse(status: 415, headers: cors)
            }
            let decoder = JSONDecoder()
            switch path {
            case "/add":
                guard let payload = try? decoder.decode(AddPayload.self, from: request.body) else { return .json(["ok": false], status: 400, headers: cors) }
                return add(payload) ? .json(["ok": true], headers: cors) : .json(["ok": false], status: 400, headers: cors)
            case "/links":
                guard let payload = try? decoder.decode(LinksPayload.self, from: request.body) else { return .json(["ok": false], status: 400, headers: cors) }
                return links(payload) ? .json(["ok": true], headers: cors) : .json(["ok": false], status: 400, headers: cors)
            case "/hello":
                guard let payload = try? decoder.decode(HelloPayload.self, from: request.body) else { return .json(["ok": false], status: 400, headers: cors) }
                ExtensionStatus.shared.record(String(payload.browser.prefix(40)))
                return .json(["ok": true, "version": appVersion], headers: cors)
            default:
                return HTTPResponse(status: 404, headers: cors)
            }
        default:
            return HTTPResponse(status: 404, headers: cors)
        }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private static func isExtensionOrigin(_ origin: String) -> Bool {
        ["chrome-extension://", "moz-extension://", "safari-web-extension://", "extension://"].contains { origin.lowercased().hasPrefix($0) }
    }

    private static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    private static func add(_ payload: AddPayload) -> Bool {
        guard let url = webURL(payload.url) else { return false }
        let isHLS = payload.kind == "hls" || url.pathExtension.lowercased() == "m3u8"
        var new = NewDownload(url: url)
        new.fileName = payload.fileName.flatMap { $0.isEmpty ? nil : $0 }
        new.referrer = payload.referrer
        new.cookies = payload.cookies.flatMap { $0.isEmpty ? nil : $0 }
        new.userAgent = payload.userAgent
        new.totalBytes = payload.fileSize
        new.mimeType = payload.mime
        new.note = payload.pageTitle
        new.kind = isHLS ? .hls : .http
        if isHLS, new.fileName == nil, let title = payload.pageTitle, !title.isEmpty {
            new.fileName = HTTPHeaderParsing.sanitizeFileName(title) + ".mp4"
        }
        if prefs.showDialogForBrowser {
            WindowPresenter.showAdd(new)
        } else {
            DownloadManager.shared.add(new, start: true)
        }
        return true
    }

    private static func links(_ payload: LinksPayload) -> Bool {
        let found = payload.links.compactMap { link -> FoundLink? in
            guard let url = webURL(link.url) else { return nil }
            return FoundLink(url: url, text: link.text, type: link.type, size: link.size)
        }
        guard !found.isEmpty else { return false }
        let context = LinkContext(referrer: payload.referrer, cookiesByHost: payload.cookies ?? [:], userAgent: payload.userAgent,
                                  title: payload.pageTitle ?? "", isMedia: payload.source == "media")
        WindowPresenter.showLinkPicker(found, context: context)
        return true
    }
}
