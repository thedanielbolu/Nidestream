import Foundation
import Observation
import NidestreamCore

enum PostQueueAction: String, Codable, CaseIterable, Identifiable {
    case nothing, quit, sleep, shutDown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nothing: return "Do nothing"
        case .quit: return "Quit Nidestream"
        case .sleep: return "Put the Mac to sleep"
        case .shutDown: return "Shut down the Mac"
        }
    }
}

struct Schedule: Codable, Equatable {
    var startEnabled = false
    /// Minutes after midnight.
    var startMinutes = 2 * 60
    var stopEnabled = false
    var stopMinutes = 8 * 60
    /// Calendar weekdays, 1 = Sunday.
    var days: Set<Int> = Set(1...7)
    var whenDone: PostQueueAction = .nothing
}

struct SiteLogin: Codable, Hashable, Identifiable {
    var id = UUID()
    var host: String
    var username: String

    var keychainAccount: String { "site:\(host.lowercased()):\(username)" }
}

struct Preferences: Codable, Equatable {
    static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    var downloadFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory() + "/Downloads"
    var categories = FileCategory.defaults
    var maxSimultaneous = 3
    var connectionsPerDownload = 8
    var speedLimitEnabled = false
    var speedLimitKBps = 1024
    var maxRetries = 8
    var timeoutSeconds = 30
    var userAgent = safariUserAgent
    var proxy = ProxySettings()
    var monitorClipboard = true
    var notify = true
    var preventSleep = true
    var resumeOnLaunch = false
    var showMenuBarIcon = true
    var browserCapture = true
    /// Browser downloads start right away, like IDM; turn this on to see the download dialog first.
    var askBeforeBrowserDownloads = false
    var minCaptureSizeKB = 0
    var captureExtensions = defaultCaptureExtensions
    var remuxToMP4 = true
    var schedule = Schedule()
    var siteLogins: [SiteLogin] = []
}

@MainActor @Observable
final class SettingsStore {
    static let shared = SettingsStore()
    private static let key = "preferences.v1"

    @ObservationIgnored private var stored: Preferences

    /// Only real changes notify observers: SwiftUI sometimes writes back an unchanged value while
    /// updating, and announcing that as a change can make views (or scenes) update in a loop.
    var prefs: Preferences {
        get {
            access(keyPath: \.prefs)
            return stored
        }
        set {
            guard newValue != stored else { return }
            let old = stored
            withMutation(keyPath: \.prefs) { stored = newValue }
            save()
            onChange?(old)
        }
    }

    @ObservationIgnored var onChange: ((Preferences) -> Void)?

    private init() {
        stored = Self.load()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Stored values are merged over the defaults, so settings added in later versions keep working.
    private static func load() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONSerialization.jsonObject(with: data),
              let defaultsData = try? JSONEncoder().encode(Preferences()),
              let defaults = try? JSONSerialization.jsonObject(with: defaultsData),
              let merged = try? JSONSerialization.data(withJSONObject: deepMerge(defaults, stored)),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: merged)
        else { return Preferences() }
        return prefs
    }

    private static func deepMerge(_ base: Any, _ overlay: Any) -> Any {
        guard var base = base as? [String: Any], let overlay = overlay as? [String: Any] else { return overlay }
        for (key, value) in overlay {
            base[key] = base[key].map { deepMerge($0, value) } ?? value
        }
        return base
    }
}
