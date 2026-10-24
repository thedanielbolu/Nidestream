import AppKit
import Observation
import SwiftUI

/// Which browsers have the extension, and when each last checked in. The extension says hello
/// every time its background script starts, which happens whenever the browser does anything with it.
@MainActor @Observable
final class ExtensionStatus {
    static let shared = ExtensionStatus()
    private static let key = "extension.lastSeen"

    private(set) var lastSeen: [String: Date]

    private init() {
        lastSeen = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Date] ?? [:]
    }

    var isConnected: Bool { !lastSeen.isEmpty }

    func record(_ browser: String) {
        lastSeen[browser] = Date()
        UserDefaults.standard.set(lastSeen, forKey: Self.key)
    }
}

/// A browser the extension can be added to.
struct KnownBrowser: Identifiable {
    /// The name the extension reports for itself.
    let id: String
    let appName: String
    let extensionsPage: String

    var isFirefox: Bool { id == "Firefox" }

    static let all = [
        KnownBrowser(id: "Chrome", appName: "Google Chrome", extensionsPage: "chrome://extensions"),
        KnownBrowser(id: "Brave", appName: "Brave Browser", extensionsPage: "brave://extensions"),
        KnownBrowser(id: "Edge", appName: "Microsoft Edge", extensionsPage: "edge://extensions"),
        KnownBrowser(id: "Vivaldi", appName: "Vivaldi", extensionsPage: "vivaldi://extensions"),
        KnownBrowser(id: "Opera", appName: "Opera", extensionsPage: "opera://extensions"),
        KnownBrowser(id: "Firefox", appName: "Firefox", extensionsPage: "about:debugging#/runtime/this-firefox"),
    ]

    static var installed: [KnownBrowser] { all.filter { $0.appURL != nil } }

    var appURL: URL? {
        let fm = FileManager.default
        return ["/Applications", NSHomeDirectory() + "/Applications"]
            .map { URL(fileURLWithPath: "\($0)/\(appName).app") }
            .first { fm.fileExists(atPath: $0.path) }
    }

    /// Opens the browser's extensions page and returns whether that worked. Chromium browsers refuse
    /// their internal pages from other apps' links and command lines, but open them when asked
    /// through AppleScript (macOS asks the user once to allow that).
    @discardableResult
    func openExtensionsPage() -> Bool {
        guard let appURL else { return false }
        if isFirefox {
            guard let executable = Bundle(url: appURL)?.executableURL else { return false }
            let process = Process()
            process.executableURL = executable
            process.arguments = [extensionsPage]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            return (try? process.run()) != nil
        }
        let script = """
        tell application "\(appName)"
            activate
            if (count of windows) is 0 then make new window
            tell front window to make new tab with properties {URL:"\(extensionsPage)"}
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        return error == nil
    }
}

struct BrowserSetupView: View {
    let close: () -> Void
    @State private var notice: String?
    private var status: ExtensionStatus { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect Your Browsers").font(.title3.bold())
                    Text("Add the Nidestream extension once and downloads you start in the browser come to Nidestream automatically, like IDM.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 0) {
                let browsers = KnownBrowser.installed
                if browsers.isEmpty {
                    Text("No supported browser found in Applications.").foregroundStyle(.secondary).padding(12)
                }
                ForEach(Array(browsers.enumerated()), id: \.element.id) { index, browser in
                    if index > 0 { Divider() }
                    row(browser)
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))

            VStack(alignment: .leading, spacing: 6) {
                Text("Chrome, Brave, Edge, Vivaldi, Opera").font(.callout.weight(.semibold))
                step(1, "Click **Open Extensions Page** next to the browser.")
                step(2, "Turn on **Developer mode** (top-right corner of that page).")
                step(3, "Drag the **BrowserExtension** folder from the Finder window onto the page, or click **Load unpacked** and choose it.")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Firefox").font(.callout.weight(.semibold))
                step(1, "Click **Open Add-ons Page**, then **Load Temporary Add-on…**")
                step(2, "Choose **manifest.json** inside the BrowserExtension folder. Firefox removes temporary add-ons when it quits.")
            }
            if let notice {
                Label(notice, systemImage: "doc.on.clipboard")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Safari can't use this extension yet. In Safari, copy a download link and Nidestream offers to take it.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button("Show Extension Folder") { revealFolder() }
                Button("Copy Folder Path") {
                    ExtensionInstaller.sync()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ExtensionInstaller.installedFolder.path, forType: .string)
                    ClipboardMonitor.shared.ignoreChangeCount = NSPasteboard.general.changeCount
                }
                .help("In the Load unpacked window, press ⇧⌘G and paste")
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private func row(_ browser: KnownBrowser) -> some View {
        HStack(spacing: 10) {
            if let url = browser.appURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(browser.appName).font(.body.weight(.medium))
                if let seen = status.lastSeen[browser.id] {
                    Label("Connected · \(seen.formatted(.relative(presentation: .named)))", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text("Not connected yet").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(browser.isFirefox ? "Open Add-ons Page" : "Open Extensions Page") {
                revealFolder()
                if browser.openExtensionsPage() {
                    notice = nil
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(browser.extensionsPage, forType: .string)
                    ClipboardMonitor.shared.ignoreChangeCount = NSPasteboard.general.changeCount
                    notice = "Couldn't open it automatically. \(browser.extensionsPage) is copied: paste it into \(browser.appName)'s address bar."
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func revealFolder() {
        ExtensionInstaller.sync()
        NSWorkspace.shared.activateFileViewerSelecting([ExtensionInstaller.installedFolder])
    }
}
