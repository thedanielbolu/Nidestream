import AppKit
import Observation
import NidestreamCore
import SwiftUI
import UniformTypeIdentifiers

enum SidebarFilter: Hashable {
    case all, unfinished, finished, queue
    case category(String)

    @MainActor func matches(_ item: DownloadItem) -> Bool {
        switch self {
        case .all: return true
        case .unfinished: return item.record.status != .completed
        case .finished: return item.record.status == .completed
        case .queue: return item.record.status == .queued || (item.record.status.isRunning && !item.record.startWhenPossible)
        case .category(let id): return item.record.category == id
        }
    }

    @MainActor var title: String {
        switch self {
        case .all: return "All Downloads"
        case .unfinished: return "Unfinished"
        case .finished: return "Finished"
        case .queue: return "Queue"
        case .category(let id): return SettingsStore.shared.prefs.categories.first { $0.id == id }?.name ?? "Category"
        }
    }
}

@MainActor @Observable
final class UIState {
    static let shared = UIState()
    var filter: SidebarFilter? = .all
    var selection = Set<UUID>()
    var search = ""
    var showInspector = true

    var selectedItems: [DownloadItem] { DownloadManager.shared.items.filter { selection.contains($0.id) } }
    var primarySelection: DownloadItem? { selection.count == 1 ? selectedItems.first : nil }
}

/// Shared by the toolbar, context menus, menu bar and keyboard shortcuts.
@MainActor
enum Actions {
    private static var manager: DownloadManager { .shared }

    static func items(_ ids: Set<UUID>) -> [DownloadItem] {
        manager.items.filter { ids.contains($0.id) }
    }

    static func open(_ ids: Set<UUID>) {
        let targets = items(ids)
        let finished = targets.filter { $0.record.status == .completed }
        if finished.isEmpty {
            UIState.shared.showInspector = true
        }
        for item in finished { NSWorkspace.shared.open(item.record.fileURL) }
    }

    static func reveal(_ ids: Set<UUID>) {
        let fm = FileManager.default
        let urls = items(ids).map { item -> URL in
            let record = item.record
            if fm.fileExists(atPath: record.fileURL.path) { return record.fileURL }
            if fm.fileExists(atPath: record.partURL.path) { return record.partURL }
            return record.directory
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func resume(_ ids: Set<UUID>) { manager.resume(items(ids)) }
    static func pause(_ ids: Set<UUID>) { manager.pause(items(ids)) }
    static func restart(_ ids: Set<UUID>) { manager.restart(items(ids)) }
    static func addToQueue(_ ids: Set<UUID>) { manager.addToQueue(items(ids)) }

    static func remove(_ ids: Set<UUID>) {
        let targets = items(ids)
        guard !targets.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = targets.count == 1 ? "Remove “\(targets[0].record.fileName)”?" : "Remove \(targets.count) downloads?"
        alert.informativeText = "Unfinished downloads lose their partial data."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if targets.contains(where: { $0.record.status == .completed }) {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Also move downloaded files to the Trash"
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        manager.remove(targets, deleteFiles: alert.suppressionButton?.state == .on)
        UIState.shared.selection.subtract(ids)
    }

    static func copyAddresses(_ ids: Set<UUID>) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(items(ids).map(\.record.url.absoluteString).joined(separator: "\n"), forType: .string)
        ClipboardMonitor.shared.ignoreChangeCount = pasteboard.changeCount
    }

    static func importLinks() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.message = "Choose a text file with one link per line."
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let links = text.components(separatedBy: .newlines).compactMap { line -> FoundLink? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let link = URL(string: trimmed), ["http", "https"].contains(link.scheme?.lowercased() ?? "") else { return nil }
            return FoundLink(url: link)
        }
        guard !links.isEmpty else { return }
        WindowPresenter.showLinkPicker(links, context: LinkContext(title: url.lastPathComponent))
    }

    static func exportLinks() {
        let selected = UIState.shared.selectedItems
        let targets = selected.isEmpty ? manager.items : selected
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Nidestream links.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? targets.map(\.record.url.absoluteString).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// URLs dropped on the main window.
    static func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let accepted = providers.filter { $0.canLoadObject(ofClass: URL.self) || $0.canLoadObject(ofClass: String.self) }
        guard !accepted.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in accepted {
                if let url = await loadURL(provider) { urls.append(url) }
            }
            if urls.count == 1 {
                WindowPresenter.showAdd(NewDownload(url: urls[0]))
            } else if !urls.isEmpty {
                WindowPresenter.showLinkPicker(urls.map { FoundLink(url: $0) }, context: LinkContext(title: "Dropped links"))
            }
        }
        return true
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil })
                }
            } else {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    let url = text.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    continuation.resume(returning: url.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil })
                }
            }
        }
    }
}

/// Opens the auxiliary windows (dialogs) as plain AppKit windows, so they work even when the
/// main window is closed and the app lives in the menu bar.
@MainActor
enum WindowPresenter {
    private static var windows: [String: NSWindow] = [:]
    private static var observers: [String: NSObjectProtocol] = [:]
    private static var floatObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    static func showMain() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindowAction?()
        }
    }

    /// Captured from SwiftUI so AppKit code can reopen the main window.
    static var openMainWindowAction: (() -> Void)?

    static func showAdd(_ new: NewDownload? = nil) {
        present(key: "add-\(UUID().uuidString)", title: "New Download") { close in
            AddDownloadView(initial: new, close: close)
        }
    }

    static func showAddLinks() {
        present(key: "add-links", title: "Add Links") { close in AddLinksView(close: close) }
    }

    static func showBatch() {
        present(key: "batch", title: "Batch Download") { close in BatchDownloadView(close: close) }
    }

    static func showGrabber() {
        present(key: "grabber", title: "Site Grabber", resizable: true) { close in GrabberView(close: close) }
    }

    static func showScheduler() {
        present(key: "scheduler", title: "Queue & Scheduler", resizable: true) { _ in QueueSchedulerView() }
    }

    static func showLinkPicker(_ links: [FoundLink], context: LinkContext) {
        let title = context.isMedia ? "Media Found" : "Select Links"
        present(key: "links-\(UUID().uuidString)", title: title, resizable: true) { close in
            LinkPickerView(links: links, context: context, close: close)
                .frame(minWidth: 760, minHeight: 460)
        }
    }

    static func showBrowserSetup() {
        present(key: "browser-setup", title: "Connect Your Browsers") { close in BrowserSetupView(close: close) }
    }

    static func showCountdown(_ action: PostQueueAction) {
        present(key: "countdown", title: "Queue Finished") { close in CountdownView(action: action, close: close) }
    }

    private static func present<Content: View>(key: String, title: String, resizable: Bool = false,
                                               @ViewBuilder content: (_ close: @escaping () -> Void) -> Content) {
        if let existing = windows[key] {
            bringForward(existing)
            return
        }
        var style: NSWindow.StyleMask = [.titled, .closable]
        if resizable { style.formUnion([.resizable, .miniaturizable]) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        let close: () -> Void = { [weak window] in window?.close() }
        let host = NSHostingController(rootView: content(close))
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        window.center()
        windows[key] = window
        observers[key] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                windows[key] = nil
                if let observer = observers.removeValue(forKey: key) { NotificationCenter.default.removeObserver(observer) }
            }
        }
        bringForward(window)
    }

    /// macOS no longer lets an app in the background take focus, so a window opened while you're in
    /// the browser would land behind it. Float it above other apps until you click it.
    private static func bringForward(_ window: NSWindow) {
        if !NSApp.isActive, floatObservers[ObjectIdentifier(window)] == nil {
            window.level = .floating
            let id = ObjectIdentifier(window)
            floatObservers[id] = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated {
                    window.level = .normal
                    if let observer = floatObservers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(observer) }
                }
            }
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
    }
}
