import AppKit
import NidestreamCore
import SwiftUI
import UserNotifications

struct NidestreamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var menuBarInserted: Binding<Bool> {
        // SwiftUI writes this back during scene updates; writing an unchanged value would still
        // notify observers and re-run this body, looping until the stack overflows.
        Binding(get: { SettingsStore.shared.prefs.showMenuBarIcon },
                set: { newValue in
                    if SettingsStore.shared.prefs.showMenuBarIcon != newValue {
                        SettingsStore.shared.prefs.showMenuBarIcon = newValue
                    }
                })
    }

    var body: some Scene {
        Window("Nidestream", id: "main") {
            MainView()
                .frame(minWidth: 860, minHeight: 460)
        }
        .defaultSize(width: 1180, height: 680)
        .commands { AppCommands() }

        Settings {
            SettingsView()
        }

        MenuBarExtra(isInserted: menuBarInserted) {
            MenuBarView()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            SettingsStore.shared.onChange = { _ in DownloadManager.shared.applySettings() }
            DownloadManager.shared.load()
            BrowserBridge.shared.start()
            ClipboardMonitor.shared.start()
            Scheduler.shared.start()
            Notifier.setUp(delegate: self)
            ExtensionInstaller.sync()
            // Like IDM's installer, make sure the browser hookup isn't missed: until some browser
            // has connected, offer the setup assistant once per launch.
            if !ExtensionStatus.shared.isConnected {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    MainActor.assumeIsolated {
                        if !ExtensionStatus.shared.isConnected { WindowPresenter.showBrowserSetup() }
                    }
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let running = DownloadManager.shared.runningCount
            if running > 0 {
                let alert = NSAlert()
                alert.messageText = running == 1 ? "A download is in progress" : "\(running) downloads are in progress"
                alert.informativeText = "They'll be paused. You can resume them the next time you open Nidestream."
                alert.addButton(withTitle: "Quit")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
            }
            DownloadManager.shared.prepareForQuit()
            return .terminateNow
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { URLSchemeHandler.handle(url) }
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Download…", action: #selector(dockAdd), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Resume All", action: #selector(dockResumeAll), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Pause All", action: #selector(dockPauseAll), keyEquivalent: "").target = self
        return menu
    }

    @objc private func dockAdd() { MainActor.assumeIsolated { WindowPresenter.showAdd() } }
    @objc private func dockResumeAll() { MainActor.assumeIsolated { DownloadManager.shared.resumeAll() } }
    @objc private func dockPauseAll() { MainActor.assumeIsolated { DownloadManager.shared.pauseAll() } }

    // MARK: Notifications

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        completionHandler()
    }
}

struct AppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Download…") { WindowPresenter.showAdd() }
                .keyboardShortcut("n")
            Button("Batch Download…") { WindowPresenter.showBatch() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Site Grabber…") { WindowPresenter.showGrabber() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Button("Import Links from Text File…") { Actions.importLinks() }
            Button("Export Links…") { Actions.exportLinks() }
        }
        CommandMenu("Downloads") {
            DownloadCommands()
        }
    }
}

private struct DownloadCommands: View {
    @Bindable private var settings = SettingsStore.shared
    private var ui: UIState { .shared }
    private var manager: DownloadManager { .shared }

    var body: some View {
        Button("Resume") { Actions.resume(ui.selection) }
            .keyboardShortcut("r")
            .disabled(ui.selection.isEmpty)
        Button("Pause") { Actions.pause(ui.selection) }
            .keyboardShortcut(".")
            .disabled(ui.selection.isEmpty)
        Button("Restart") { Actions.restart(ui.selection) }
            .disabled(ui.selection.isEmpty)
        Button("Remove…") { Actions.remove(ui.selection) }
            .keyboardShortcut(.delete)
            .disabled(ui.selection.isEmpty)
        Divider()
        Button("Resume All") { manager.resumeAll() }
            .keyboardShortcut("r", modifiers: [.command, .option])
        Button("Pause All") { manager.pauseAll() }
            .keyboardShortcut(".", modifiers: [.command, .option])
        Button("Remove Completed") { manager.removeCompleted() }
        Divider()
        Button("Start Queue") { manager.startQueue() }
            .disabled(manager.queueRunning)
        Button("Stop Queue") { manager.stopQueue() }
            .disabled(!manager.queueRunning)
        Button("Queue & Scheduler…") { WindowPresenter.showScheduler() }
            .keyboardShortcut("s", modifiers: [.command, .option])
        Divider()
        Toggle("Speed Limiter", isOn: $settings.prefs.speedLimitEnabled)
            .keyboardShortcut("l", modifiers: [.command, .option])
    }
}
