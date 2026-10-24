import AppKit
import NidestreamCore
import SwiftUI

extension Color {
    /// Nidestream blue, from the app icon.
    static let brand = Color(red: 0.10, green: 0.50, blue: 0.84)
}

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

enum WidgetTab: String, CaseIterable {
    case downloads = "Downloads"
    case finished = "Finished"
}

/// The menu bar panel: quick actions, what's downloading, what finished, and overall progress.
struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var tab: WidgetTab
    private var manager: DownloadManager { .shared }
    private var settings: SettingsStore { .shared }

    init(tab: WidgetTab = .downloads) {
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            Divider()
            stats
            Divider()
            Group {
                switch tab {
                case .downloads: downloadsList
                case .finished: finishedList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 380, height: 540)
    }

    // MARK: Data

    private var unfinished: [DownloadItem] {
        func order(_ status: DownloadStatus) -> Int {
            switch status {
            case .downloading, .connecting, .processing: return 0
            case .queued: return 1
            case .paused: return 2
            case .failed: return 3
            case .completed: return 4
            }
        }
        return manager.items.filter { $0.record.status != .completed }.sorted {
            (order($0.record.status), $1.record.dateAdded) < (order($1.record.status), $0.record.dateAdded)
        }
    }

    private var finished: [DownloadItem] {
        manager.items.filter { $0.record.status == .completed }
            .sorted { ($0.record.dateCompleted ?? .distantPast) > ($1.record.dateCompleted ?? .distantPast) }
            .prefix(30).map { $0 }
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate()
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
            Button { WindowPresenter.showAddLinks() } label: {
                Label("Add links", systemImage: "link")
            }
            .buttonStyle(PillButtonStyle(prominent: true))
            .help("Paste one or more links to download")
            if manager.items.contains(where: { $0.record.status.isRunning || $0.record.status == .queued }) {
                Button { manager.pauseAll() } label: { Label("Pause all", systemImage: "pause.fill") }
                    .buttonStyle(PillButtonStyle())
            } else {
                Button { manager.resumeAll() } label: { Label("Resume all", systemImage: "play.fill") }
                    .buttonStyle(PillButtonStyle())
                    .disabled(!manager.items.contains { $0.record.status == .paused || $0.record.status == .failed })
            }
            Spacer(minLength: 0)
            menu
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var menu: some View {
        Menu {
            Button("Open Nidestream") { openMain() }
            Divider()
            Button("New Download…") { WindowPresenter.showAdd() }
            Button("Add Links…") { WindowPresenter.showAddLinks() }
            Button("Batch Download…") { WindowPresenter.showBatch() }
            Divider()
            Button("Resume All") { manager.resumeAll() }
            Button("Pause All") { manager.pauseAll() }
            Toggle("Limit Speed to \(Fmt.bytes(Int64(settings.prefs.speedLimitKBps) * 1024))/s",
                   isOn: Binding(get: { settings.prefs.speedLimitEnabled }, set: { settings.prefs.speedLimitEnabled = $0 }))
            Button("Queue & Scheduler…") { WindowPresenter.showScheduler() }
            Divider()
            Button("Connect Browsers…") { WindowPresenter.showBrowserSetup() }
            Button("Settings…") {
                openSettings()
                NSApp.activate()
            }
            Divider()
            Button("Quit Nidestream") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 17, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 22) {
            ForEach(WidgetTab.allCases, id: \.self) { item in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { tab = item }
                } label: {
                    VStack(spacing: 7) {
                        HStack(spacing: 6) {
                            Text(item.rawValue).font(.system(size: 14, weight: .semibold))
                            let count = item == .downloads ? unfinished.count : 0
                            if count > 0 {
                                Text("\(count)")
                                    .font(.system(size: 11, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.brand.opacity(0.15)))
                            }
                        }
                        .foregroundStyle(tab == item ? Color.brand : Color.secondary)
                        Capsule()
                            .fill(tab == item ? Color.brand : Color.clear)
                            .frame(height: 2.5)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    // MARK: Stats

    private var stats: some View {
        let pending = unfinished.filter { $0.record.totalBytes > 0 }
        let total = pending.reduce(Int64(0)) { $0 + $1.record.totalBytes }
        let received = pending.reduce(Int64(0)) { $0 + min($1.record.receivedBytes, $1.record.totalBytes) }
        let fraction = total > 0 ? Double(received) / Double(total) : 0
        let speed = manager.totalSpeed
        let limited = settings.prefs.speedLimitEnabled
        let limit = Double(max(1, settings.prefs.speedLimitKBps) * 1024)

        return HStack(spacing: 14) {
            statBlock(title: "Progress",
                      value: unfinished.isEmpty ? "Nothing downloading" : (total > 0 ? "\(Fmt.bytes(received)) / \(Fmt.bytes(total))" : "Starting…")) {
                RingGauge(progress: fraction) {
                    Text("\(Int((fraction * 100).rounded(.down)))%")
                        .font(.system(size: 13, weight: .bold))
                        .monospacedDigit()
                }
            }
            statBlock(title: limited ? "Speed · limited" : "Speed",
                      value: speed >= 1 ? Fmt.speed(speed) : "Idle") {
                RingGauge(progress: limited ? min(1, speed / limit) : (speed >= 1 ? 1 : 0), tint: limited ? .orange : .brand) {
                    Image(systemName: limited ? "gauge.with.dots.needle.33percent" : "arrow.down")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(limited ? Color.orange : Color.brand)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func statBlock<Gauge: View>(title: String, value: String, @ViewBuilder gauge: () -> Gauge) -> some View {
        HStack(spacing: 10) {
            gauge().frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(value)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Lists

    @ViewBuilder private var downloadsList: some View {
        if unfinished.isEmpty {
            emptyDownloads
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(unfinished) { WidgetDownloadRow(item: $0) }
                }
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder private var finishedList: some View {
        if finished.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "tray")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No finished downloads yet").font(.system(size: 15, weight: .semibold))
                Text("Files you download show up here.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(finished) { WidgetFinishedRow(item: $0) }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var emptyDownloads: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            EmptyIllustration()
            VStack(spacing: 5) {
                Text("Nothing downloading").font(.system(size: 18, weight: .bold))
                Text("Add a link, or start a download in your browser and Nidestream takes it from there.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            Button { WindowPresenter.showAddLinks() } label: { Label("Add links", systemImage: "link") }
                .buttonStyle(PillButtonStyle(prominent: true))
            Spacer(minLength: 0)
        }
    }

    // MARK: Footer

    private var footer: some View {
        let running = manager.runningCount
        let failed = manager.items.filter { $0.record.status == .failed }.count
        let (symbol, color, text, setup): (String, Color, String, Bool) = {
            if running > 0 { return ("arrow.down.circle.fill", .brand, "Downloading \(running) file\(running == 1 ? "" : "s")", false) }
            if failed > 0 { return ("exclamationmark.circle.fill", .orange, "\(failed) download\(failed == 1 ? " needs" : "s need") attention", false) }
            if !BridgeStatus.shared.listening { return ("xmark.octagon.fill", .red, "Browser integration is off", false) }
            if !ExtensionStatus.shared.isConnected { return ("puzzlepiece.extension.fill", .orange, "Connect your browser", true) }
            return ("checkmark.circle", .green, "All caught up", false)
        }()
        return HStack(spacing: 8) {
            Button {
                if setup { WindowPresenter.showBrowserSetup() } else { openMain() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 16))
                        .foregroundStyle(color)
                    Text(text).font(.system(size: 13))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Button(action: openMain) {
                Image(systemName: "macwindow")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 32, height: 32)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Open Nidestream")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Rows

private struct WidgetDownloadRow: View {
    let item: DownloadItem
    @State private var hovering = false

    private var record: DownloadRecord { item.record }

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(fileName: record.fileName, size: 32)
            VStack(alignment: .leading, spacing: 5) {
                Text(record.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                ThinProgressBar(value: item.progress, tint: tint,
                                indeterminate: record.status == .connecting || record.status == .processing)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(record.status == .failed ? Color.red : Color.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            RowButton(symbol: actionSymbol, help: actionHelp, action: action)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(record.lastError ?? record.url.absoluteString)
    }

    private var percent: String { "\(Int((item.progress * 100).rounded(.down)))%" }

    private var detail: String {
        switch record.status {
        case .downloading:
            var parts = [percent]
            if item.speed >= 1 { parts.append(Fmt.speed(item.speed)) }
            if let eta = item.eta { parts.append("\(Fmt.duration(eta)) left") }
            return parts.joined(separator: " · ")
        case .connecting: return "Connecting…"
        case .processing: return "Merging video…"
        case .queued: return record.startWhenPossible ? "Waiting for a free slot" : "In the queue"
        case .paused:
            return record.totalBytes > 0 ? "Paused · \(Fmt.bytes(record.receivedBytes)) of \(Fmt.bytes(record.totalBytes))" : "Paused"
        case .failed: return "Couldn't finish. Click ↻ to try again"
        case .completed: return ""
        }
    }

    private var tint: Color {
        switch record.status {
        case .failed: return .red
        case .paused: return .orange
        case .queued: return .secondary
        default: return .brand
        }
    }

    private var actionSymbol: String {
        switch record.status {
        case .paused: return "play.fill"
        case .failed: return "arrow.clockwise"
        default: return "pause.fill"
        }
    }

    private var actionHelp: String {
        switch record.status {
        case .paused: return "Resume"
        case .failed: return "Try again"
        default: return "Pause"
        }
    }

    private func action() {
        switch record.status {
        case .paused, .failed: DownloadManager.shared.resume([item])
        default: DownloadManager.shared.pause([item])
        }
    }
}

private struct WidgetFinishedRow: View {
    let item: DownloadItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(fileName: item.record.fileName, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.record.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            RowButton(symbol: "magnifyingglass", help: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.record.fileURL])
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { NSWorkspace.shared.open(item.record.fileURL) }
        .help("Open \(item.record.fileName)")
    }

    private var detail: String {
        var parts = [Fmt.bytes(item.record.totalBytes)]
        if let date = item.record.dateCompleted {
            parts.append(date.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Pieces

struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        PillLabel(configuration: configuration, prominent: prominent)
    }

    private struct PillLabel: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 8).fill(prominent ? Color.brand : Color.primary.opacity(0.09)))
                .opacity(configuration.isPressed ? 0.75 : (isEnabled ? 1 : 0.45))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct RowButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.14 : 0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct RingGauge<Center: View>: View {
    var progress: Double
    var tint: Color = .brand
    @ViewBuilder var center: Center

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center
        }
        .padding(2)
        .animation(.easeOut(duration: 0.4), value: progress)
    }
}

struct ThinProgressBar: View {
    var value: Double
    var tint: Color = .brand
    var indeterminate = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(tint)
                    .frame(width: max(4, proxy.size.width * (indeterminate ? 0.3 : max(0, min(1, value)))))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.3), value: value)
    }
}

/// The app icon with a couple of file cards tumbling behind it.
private struct EmptyIllustration: View {
    var body: some View {
        ZStack {
            card(symbol: "doc.zipper", colors: [Color(red: 1.0, green: 0.55, blue: 0.35), Color(red: 0.93, green: 0.33, blue: 0.24)])
                .rotationEffect(.degrees(-14))
                .offset(x: -50, y: 22)
            card(symbol: "film", colors: [Color(red: 0.62, green: 0.66, blue: 0.74), Color(red: 0.45, green: 0.49, blue: 0.58)])
                .rotationEffect(.degrees(13))
                .offset(x: 50, y: -16)
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 104, height: 104)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
        }
        .frame(width: 180, height: 130)
    }

    private func card(symbol: String, colors: [Color]) -> some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 48, height: 56)
            .overlay(Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
    }
}
