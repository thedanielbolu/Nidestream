import AppKit
import NidestreamCore
import SwiftUI

/// `Nidestream --render-ui <folder>` draws the menu bar widget (with sample downloads, empty, and the
/// Finished tab) and the Add Links dialog, in light and dark mode, into PNG files. Used for design
/// review and screenshots; it doesn't touch the real download list or start any download.
@MainActor
enum UIRender {
    static func run(_ arguments: [String]) -> Int32 {
        guard let index = arguments.firstIndex(of: "--render-ui"), index + 1 < arguments.count else {
            FileHandle.standardError.write(Data("usage: Nidestream --render-ui <folder>\n".utf8))
            return 64
        }
        let folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        BridgeStatus.shared.listening = true

        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            DownloadManager.shared.showPreview(samples())
            render(MenuBarView(tab: .downloads), dark: dark, to: folder.appendingPathComponent("widget-downloads-\(mode).png"))
            render(MenuBarView(tab: .finished), dark: dark, to: folder.appendingPathComponent("widget-finished-\(mode).png"))
            DownloadManager.shared.showPreview([])
            render(MenuBarView(tab: .downloads), dark: dark, to: folder.appendingPathComponent("widget-empty-\(mode).png"))
            render(ToastView(names: ["tfpdl-trnr2672wd.mkv"], size: 876_727_979, open: {}), dark: dark,
                   to: folder.appendingPathComponent("toast-\(mode).png"))
            render(AddLinksView(close: {}, initialText: "https://example.com/releases/app-2.4.dmg\nCheck these too: https://example.com/docs/manual.pdf and https://example.com/media/intro.mp4\n"),
                   dark: dark, to: folder.appendingPathComponent("add-links-\(mode).png"))
        }
        print("Rendered to \(folder.path)")
        return 0
    }

    private static func render<V: View>(_ view: V, dark: Bool, to url: URL) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func samples() -> [(record: DownloadRecord, speed: Double)] {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        func record(_ name: String, _ status: DownloadStatus, total: Int64, done: Double, minutesAgo: Double = 0) -> DownloadRecord {
            var record = DownloadRecord(url: URL(string: "https://example.com/\(name)")!, fileName: name, directory: folder)
            record.status = status
            record.totalBytes = total
            record.receivedBytes = Int64(Double(total) * done)
            record.dateAdded = Date().addingTimeInterval(-minutesAgo * 60 - 60)
            if status == .completed { record.dateCompleted = Date().addingTimeInterval(-minutesAgo * 60) }
            record.startWhenPossible = status == .queued
            return record
        }
        return [
            (record("ubuntu-24.04-desktop-arm64.iso", .downloading, total: 3_100_000_000, done: 0.62), 8_400_000),
            (record("Sunrise Timelapse 4K.mp4", .downloading, total: 412_000_000, done: 0.27), 2_100_000),
            (record("Xcode_16.4.xip", .queued, total: 3_400_000_000, done: 0), 0),
            (record("design-assets.zip", .paused, total: 860_000_000, done: 0.41), 0),
            (record("Quarterly report.pdf", .completed, total: 4_200_000, done: 1, minutesAgo: 3), 0),
            (record("Blender-4.2-macos-arm64.dmg", .completed, total: 382_000_000, done: 1, minutesAgo: 26), 0),
            (record("podcast-episode-112.mp3", .completed, total: 58_000_000, done: 1, minutesAgo: 95), 0),
            (record("fonts-collection.7z", .completed, total: 120_000_000, done: 1, minutesAgo: 240), 0),
        ]
    }
}
