import AppKit
import NidestreamCore
import UserNotifications

/// Offers to download links the user copies, like IDM's clipboard monitoring.
@MainActor
final class ClipboardMonitor {
    static let shared = ClipboardMonitor()
    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    /// Set when Nidestream itself writes to the pasteboard ("Copy Address").
    var ignoreChangeCount: Int?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardMonitor.shared.check() }
        }
    }

    private func check() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChange else { return }
        lastChange = pasteboard.changeCount
        guard SettingsStore.shared.prefs.monitorClipboard, ignoreChangeCount != pasteboard.changeCount else { return }
        guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.count < 4096, !text.contains(where: \.isWhitespace),
              let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return }
        let ext = url.pathExtension.lowercased()
        guard SettingsStore.shared.prefs.captureExtensions.contains(ext) || ext == "m3u8" else { return }
        guard DownloadManager.shared.existingDownload(for: url) == nil else { return }
        WindowPresenter.showAdd(NewDownload(url: url))
    }
}

/// Starts and stops the main queue at the scheduled times and runs the "when done" action.
@MainActor
final class Scheduler {
    static let shared = Scheduler()
    private var timer: Timer?
    private var fired: Set<String> = []

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { Scheduler.shared.tick() }
        }
        DownloadManager.shared.onQueueFinished = { Scheduler.shared.queueFinished() }
    }

    private func tick() {
        let schedule = SettingsStore.shared.prefs.schedule
        let now = Date()
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: now)
        guard let weekday = parts.weekday, schedule.days.contains(weekday) else { return }
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let stamp = "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)-\(minutes)"
        if schedule.startEnabled, minutes == schedule.startMinutes, fired.insert("start-" + stamp).inserted {
            DownloadManager.shared.startQueue()
        }
        if schedule.stopEnabled, minutes == schedule.stopMinutes, fired.insert("stop-" + stamp).inserted {
            DownloadManager.shared.stopQueue()
        }
    }

    private func queueFinished() {
        let action = SettingsStore.shared.prefs.schedule.whenDone
        Notifier.post(title: "Queue finished", body: "All downloads in the queue are done.", file: nil)
        guard action != .nothing else { return }
        WindowPresenter.showCountdown(action)
    }

    static func perform(_ action: PostQueueAction) {
        switch action {
        case .nothing:
            break
        case .quit:
            NSApp.terminate(nil)
        case .sleep:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["sleepnow"]
            try? process.run()
        case .shutDown:
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"System Events\" to shut down")?.executeAndReturnError(&error)
        }
    }
}

@MainActor
enum Notifier {
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func setUp(delegate: UNUserNotificationCenterDelegate) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func downloadFinished(_ item: DownloadItem) {
        post(title: "Download complete", body: item.record.fileName, file: item.record.fileURL)
    }

    static func downloadFailed(_ item: DownloadItem) {
        post(title: "Download failed", body: "\(item.record.fileName): \(item.record.lastError ?? "Unknown error")", file: nil)
    }

    static func post(title: String, body: String, file: URL?) {
        guard available, SettingsStore.shared.prefs.notify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let file { content.userInfo = ["path": file.path] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Keeps a copy of the browser extension in Application Support, a stable folder Chrome can load.
enum ExtensionInstaller {
    static var installedFolder: URL { Persistence.supportDirectory.appendingPathComponent("BrowserExtension", isDirectory: true) }

    static var bundledFolder: URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension"),
            // `swift run` from the project folder
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("BrowserExtension"),
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
        }
    }

    static func sync() {
        guard let source = bundledFolder, filesDiffer(source, installedFolder) else { return }
        try? FileManager.default.removeItem(at: installedFolder)
        try? FileManager.default.copyItem(at: source, to: installedFolder)
    }

    private static func filesDiffer(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        guard let files = fm.enumerator(atPath: a.path) else { return true }
        for case let path as String in files {
            let left = a.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: left.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            if (try? Data(contentsOf: left)) != (try? Data(contentsOf: b.appendingPathComponent(path))) { return true }
        }
        return false
    }
}

/// `nidestream://add?url=…&referrer=…&name=…&silent=1` for bookmarklets, scripts and other apps.
/// `silent=1` starts the download without showing the dialog.
@MainActor
enum URLSchemeHandler {
    static func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "nidestream" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        switch url.host?.lowercased() {
        case "add":
            guard let target = value("url").flatMap(URL.init(string:)), ["http", "https"].contains(target.scheme?.lowercased() ?? "") else { return }
            var new = NewDownload(url: target)
            new.referrer = value("referrer")
            new.fileName = value("name")
            if value("silent") == "1" {
                DownloadManager.shared.add(new, start: true)
            } else {
                WindowPresenter.showAdd(new)
            }
        default:
            WindowPresenter.showMain()
        }
    }
}
