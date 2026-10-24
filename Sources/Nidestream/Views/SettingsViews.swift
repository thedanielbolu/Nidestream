import AppKit
import NidestreamCore
import SwiftUI

struct QueueSchedulerView: View {
    @Bindable private var settings = SettingsStore.shared
    private var manager: DownloadManager { .shared }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Main Queue").font(.headline)
                    Spacer()
                    Button(manager.queueRunning ? "Stop Queue" : "Start Queue") {
                        manager.queueRunning ? manager.stopQueue() : manager.startQueue()
                    }
                }
                Stepper(value: $settings.prefs.maxSimultaneous, in: 1...10) {
                    Text("Download \(settings.prefs.maxSimultaneous) file\(settings.prefs.maxSimultaneous == 1 ? "" : "s") at a time")
                }
                List {
                    ForEach(manager.queuedItems) { item in
                        HStack {
                            FileIcon(fileName: item.record.fileName)
                            Text(item.record.fileName).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(item.sizeText).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .contextMenu {
                            Button("Remove from Queue") { manager.pause([item]) }
                        }
                    }
                    .onMove { manager.moveQueue(from: $0, to: $1) }
                }
                .overlay {
                    if manager.queuedItems.isEmpty {
                        Text("Use “Download Later” to add files to the queue.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
                Text("Drag to reorder.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(minWidth: 320)

            Divider()

            Form {
                Section("Start") {
                    Toggle("Start the queue at", isOn: $settings.prefs.schedule.startEnabled)
                    DatePicker("Time", selection: time(\.startMinutes), displayedComponents: .hourAndMinute)
                        .disabled(!settings.prefs.schedule.startEnabled)
                }
                Section("Stop") {
                    Toggle("Stop the queue at", isOn: $settings.prefs.schedule.stopEnabled)
                    DatePicker("Time", selection: time(\.stopMinutes), displayedComponents: .hourAndMinute)
                        .disabled(!settings.prefs.schedule.stopEnabled)
                }
                Section("Days") {
                    WeekdayPicker(days: $settings.prefs.schedule.days)
                }
                Section("When the queue finishes") {
                    Picker("Then", selection: $settings.prefs.schedule.whenDone) {
                        ForEach(PostQueueAction.allCases) { Text($0.title).tag($0) }
                    }
                    if settings.prefs.schedule.whenDone == .shutDown {
                        Text("macOS asks once for permission to control System Events.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 330)
        }
        .frame(minWidth: 680, minHeight: 440)
    }

    private func time(_ keyPath: WritableKeyPath<Schedule, Int>) -> Binding<Date> {
        Binding(get: {
            let minutes = settings.prefs.schedule[keyPath: keyPath]
            return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            settings.prefs.schedule[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }
}

private struct WeekdayPicker: View {
    @Binding var days: Set<Int>

    var body: some View {
        let calendar = Calendar.current
        let symbols = calendar.veryShortWeekdaySymbols
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        HStack(spacing: 6) {
            ForEach(order, id: \.self) { day in
                Toggle(symbols[day - 1], isOn: Binding(get: { days.contains(day) }, set: { on in
                    if on { days.insert(day) } else { days.remove(day) }
                }))
                .toggleStyle(.button)
            }
        }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ConnectionSettings().tabItem { Label("Connection", systemImage: "network") }
            BrowserSettings().tabItem { Label("Browser", systemImage: "puzzlepiece.extension") }
            FileTypeSettings().tabItem { Label("File Types", systemImage: "folder") }
            LoginSettings().tabItem { Label("Logins", systemImage: "key") }
        }
        .frame(width: 600)
        .frame(minHeight: 440)
    }
}

private struct GeneralSettings: View {
    @Bindable private var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Download folder") {
                    HStack {
                        Text(settings.prefs.downloadFolder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") {
                            if let path = chooseFolder() { settings.prefs.downloadFolder = path }
                        }
                    }
                }
                Stepper(value: $settings.prefs.connectionsPerDownload, in: 1...32) {
                    LabeledContent("Connections per download", value: "\(settings.prefs.connectionsPerDownload)")
                }
                Stepper(value: $settings.prefs.maxSimultaneous, in: 1...10) {
                    LabeledContent("Downloads at the same time", value: "\(settings.prefs.maxSimultaneous)")
                }
            }
            Section {
                Toggle("Offer to download links I copy", isOn: $settings.prefs.monitorClipboard)
                Toggle("Notify me when downloads finish", isOn: $settings.prefs.notify)
                Toggle("Keep the Mac awake while downloading", isOn: $settings.prefs.preventSleep)
                Toggle("Resume unfinished downloads when Nidestream opens", isOn: $settings.prefs.resumeOnLaunch)
                Toggle("Show in the menu bar", isOn: $settings.prefs.showMenuBarIcon)
            }
            Section("Video streams") {
                Toggle("Convert streams to MP4 with FFmpeg", isOn: $settings.prefs.remuxToMP4)
                if let path = FFmpeg.path {
                    LabeledContent("FFmpeg", value: path)
                } else {
                    Text("FFmpeg isn't installed, so streams are saved as .ts files (VLC and IINA play them). Install it with `brew install ffmpeg` to get .mp4 files.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ConnectionSettings: View {
    @Bindable private var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section("Speed limiter") {
                Toggle("Limit download speed", isOn: $settings.prefs.speedLimitEnabled)
                TextField("Maximum (KB/s)", value: $settings.prefs.speedLimitKBps, format: .number)
                    .disabled(!settings.prefs.speedLimitEnabled)
            }
            Section("Reliability") {
                Stepper(value: $settings.prefs.maxRetries, in: 0...50) {
                    LabeledContent("Retries per connection", value: "\(settings.prefs.maxRetries)")
                }
                Stepper(value: $settings.prefs.timeoutSeconds, in: 5...300, step: 5) {
                    LabeledContent("Connection timeout", value: "\(settings.prefs.timeoutSeconds) s")
                }
            }
            Section("Proxy") {
                Picker("Proxy", selection: $settings.prefs.proxy.mode) {
                    Text("Use system settings").tag(ProxySettings.Mode.system)
                    Text("No proxy").tag(ProxySettings.Mode.none)
                    Text("HTTP / HTTPS").tag(ProxySettings.Mode.http)
                    Text("SOCKS").tag(ProxySettings.Mode.socks)
                }
                if settings.prefs.proxy.mode == .http || settings.prefs.proxy.mode == .socks {
                    TextField("Host", text: $settings.prefs.proxy.host)
                    TextField("Port", value: $settings.prefs.proxy.port, format: .number.grouping(.never))
                }
            }
            Section("Identity") {
                TextField("User agent", text: $settings.prefs.userAgent, axis: .vertical)
                    .lineLimit(2...4)
                Button("Reset to Safari") { settings.prefs.userAgent = Preferences.safariUserAgent }
            }
        }
        .formStyle(.grouped)
    }
}

private struct BrowserSettings: View {
    @Bindable private var settings = SettingsStore.shared
    private var bridge: BridgeStatus { .shared }

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Label(bridge.message, systemImage: bridge.listening ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(bridge.listening ? .green : .red)
                }
                if let contact = bridge.lastContact {
                    LabeledContent("Extension last seen", value: contact.formatted(.relative(presentation: .named)))
                }
                Toggle("Take over downloads from the browser", isOn: $settings.prefs.browserCapture)
                Toggle("Show the download dialog first", isOn: $settings.prefs.showDialogForBrowser)
                TextField("Skip files smaller than (KB)", value: $settings.prefs.minCaptureSizeKB, format: .number)
            }
            Section("Install the extension") {
                Text("Works with Chrome, Edge, Brave, Arc, Vivaldi, Opera and Firefox.")
                VStack(alignment: .leading, spacing: 6) {
                    Text("**Chrome and other Chromium browsers:** open the Extensions page, turn on Developer mode, click “Load unpacked” and pick the extension folder.")
                    Text("**Firefox:** open about:debugging → This Firefox → “Load Temporary Add-on…” and pick manifest.json in the extension folder.")
                    Text("**Safari:** use the clipboard monitor, drag links into Nidestream, or this bookmarklet: `javascript:location.href='nidestream://add?url='+encodeURIComponent(location.href)`")
                }
                .font(.callout)
                .textSelection(.enabled)
                HStack {
                    Button("Show Extension Folder") {
                        ExtensionInstaller.sync()
                        NSWorkspace.shared.activateFileViewerSelecting([ExtensionInstaller.installedFolder])
                    }
                    Button("Copy chrome://extensions") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("chrome://extensions", forType: .string)
                        ClipboardMonitor.shared.ignoreChangeCount = NSPasteboard.general.changeCount
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct FileTypeSettings: View {
    @Bindable private var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section("Categories") {
                ForEach($settings.prefs.categories) { $category in
                    DisclosureGroup {
                        if category.id != FileCategory.generalID {
                            TextField("Extensions", text: Binding(get: { category.extensions.joined(separator: " ") },
                                                                  set: { category.extensions = Self.parse($0) }),
                                      axis: .vertical)
                                .lineLimit(1...4)
                        }
                        LabeledContent("Save to") {
                            HStack {
                                Text(category.folder?.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "Download folder")
                                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Button("Choose…") { if let path = chooseFolder() { category.folder = path } }
                                if category.folder != nil { Button("Reset") { category.folder = nil } }
                            }
                        }
                    } label: {
                        Label(category.name, systemImage: category.symbol)
                    }
                }
            }
            Section {
                TextField("Extensions", text: Binding(get: { settings.prefs.captureExtensions.joined(separator: " ") },
                                                      set: { settings.prefs.captureExtensions = Self.parse($0) }),
                          axis: .vertical)
                    .lineLimit(3...8)
                Button("Restore Defaults") { settings.prefs.captureExtensions = defaultCaptureExtensions }
            } header: {
                Text("Take over these file types")
            } footer: {
                Text("Used by the browser extension and the clipboard monitor.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == " " || $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

private struct LoginSettings: View {
    @Bindable private var settings = SettingsStore.shared
    @State private var host = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section {
                if settings.prefs.siteLogins.isEmpty {
                    Text("No saved logins.").foregroundStyle(.secondary)
                }
                ForEach(settings.prefs.siteLogins) { login in
                    HStack {
                        Label(login.host, systemImage: "globe")
                        Spacer()
                        Text(login.username).foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            Keychain.delete(account: login.keychainAccount)
                            settings.prefs.siteLogins.removeAll { $0.id == login.id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Site logins")
            } footer: {
                Text("Used when a server asks for a username and password. Passwords are stored in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Add a login") {
                TextField("Server", text: $host, prompt: Text("files.example.com"))
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
                Button("Add") {
                    let login = SiteLogin(host: host.trimmingCharacters(in: .whitespaces).lowercased(), username: username)
                    Keychain.set(password, account: login.keychainAccount)
                    settings.prefs.siteLogins.append(login)
                    host = ""
                    username = ""
                    password = ""
                }
                .disabled(host.isEmpty || username.isEmpty || password.isEmpty)
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
private func chooseFolder() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    return panel.runModal() == .OK ? panel.url?.path : nil
}

// MARK: - Menu bar

struct MenuBarLabel: View {
    private var manager: DownloadManager { .shared }

    var body: some View {
        let speed = Fmt.speed(manager.totalSpeed)
        HStack(spacing: 3) {
            Image(systemName: manager.runningCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
            if manager.runningCount > 0, !speed.isEmpty { Text(speed).monospacedDigit() }
        }
    }
}

struct MenuBarView: View {
    @Bindable private var settings = SettingsStore.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    private var manager: DownloadManager { .shared }

    var body: some View {
        let active = manager.items.filter { $0.record.status.isRunning || $0.record.status == .queued }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Nidestream").font(.headline)
                Spacer()
                Text(Fmt.speed(manager.totalSpeed)).monospacedDigit().foregroundStyle(.secondary)
            }
            if active.isEmpty {
                Text("No active downloads").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(active.prefix(6)) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            FileIcon(fileName: item.record.fileName, size: 14)
                            Text(item.record.fileName).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(item.record.status == .downloading ? Fmt.speed(item.speed) : item.statusText)
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.callout)
                        ProgressView(value: item.progress).progressViewStyle(.linear).controlSize(.small)
                    }
                }
                if active.count > 6 {
                    Text("and \(active.count - 6) more").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            Toggle("Limit speed to \(Fmt.bytes(Int64(settings.prefs.speedLimitKBps) * 1024))/s", isOn: $settings.prefs.speedLimitEnabled)
            HStack {
                Button("New Download…") { WindowPresenter.showAdd() }
                Spacer()
                Button("Pause All") { manager.pauseAll() }
                Button("Resume All") { manager.resumeAll() }
            }
            Divider()
            HStack {
                Button("Open Nidestream") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Button("Settings…") {
                    openSettings()
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}
