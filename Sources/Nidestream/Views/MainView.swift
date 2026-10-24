import AppKit
import NidestreamCore
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Bindable private var ui = UIState.shared
    @State private var sortOrder = [KeyPathComparator(\DownloadItem.record.dateAdded, order: .reverse)]
    @Environment(\.openWindow) private var openWindow
    private var manager: DownloadManager { .shared }

    var body: some View {
        NavigationSplitView {
            SidebarView(filter: $ui.filter)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        } detail: {
            DownloadListView(items: visibleItems, sortOrder: $sortOrder)
                .inspector(isPresented: $ui.showInspector) {
                    InspectorView(item: ui.primarySelection, selectionCount: ui.selection.count)
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 440)
                }
        }
        .navigationTitle((ui.filter ?? .all).title)
        .navigationSubtitle(subtitle)
        .searchable(text: $ui.search, placement: .toolbar, prompt: "Search")
        .toolbar { MainToolbar() }
        .onDrop(of: [.url, .plainText], isTargeted: nil) { Actions.handleDrop($0) }
        .onAppear {
            let open = openWindow
            WindowPresenter.openMainWindowAction = { open(id: "main") }
        }
    }

    private var visibleItems: [DownloadItem] {
        let filter = ui.filter ?? .all
        let query = ui.search.trimmingCharacters(in: .whitespaces)
        return manager.items.filter { item in
            guard filter.matches(item) else { return false }
            guard !query.isEmpty else { return true }
            return item.record.fileName.localizedCaseInsensitiveContains(query)
                || item.record.url.absoluteString.localizedCaseInsensitiveContains(query)
        }.sorted(using: sortOrder)
    }

    private var subtitle: String {
        let running = manager.runningCount
        guard running > 0 else { return manager.queueRunning ? "Queue running" : "" }
        return "\(running) downloading · \(Fmt.speed(manager.totalSpeed))"
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @Binding var filter: SidebarFilter?
    private var manager: DownloadManager { .shared }
    private var settings: SettingsStore { .shared }

    var body: some View {
        List(selection: $filter) {
            Section("Downloads") {
                row(.all, "All Downloads", "tray.full")
                row(.unfinished, "Unfinished", "arrow.down.circle")
                row(.finished, "Finished", "checkmark.circle")
                row(.queue, "Queue", "list.number")
            }
            Section("Categories") {
                ForEach(settings.prefs.categories) { category in
                    row(.category(category.id), category.name, category.symbol)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ value: SidebarFilter, _ title: String, _ symbol: String) -> some View {
        let count = manager.items.filter { value.matches($0) }.count
        return Label(title, systemImage: symbol)
            .badge(count)
            .tag(value)
    }
}

// MARK: - Toolbar

private struct MainToolbar: ToolbarContent {
    @Bindable private var settings = SettingsStore.shared
    private var ui: UIState { .shared }
    private var manager: DownloadManager { .shared }

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                Button("New Download…", systemImage: "plus") { WindowPresenter.showAdd() }
                Button("Add Links…", systemImage: "link") { WindowPresenter.showAddLinks() }
                Button("Batch Download…", systemImage: "square.stack.3d.down.right") { WindowPresenter.showBatch() }
                Button("Site Grabber…", systemImage: "globe") { WindowPresenter.showGrabber() }
                Divider()
                Button("Import Links from Text File…", systemImage: "doc.text") { Actions.importLinks() }
            } label: {
                Label("Add", systemImage: "plus")
            } primaryAction: {
                WindowPresenter.showAdd()
            }
            .help("New download (⌘N)")
        }
        ToolbarItem(placement: .navigation) {
            Button { WindowPresenter.showAddLinks() } label: {
                Label("Add Links", systemImage: "link")
            }
            .help("Add links: paste one or more (⌘L)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { Actions.resume(ui.selection) } label: { Label("Resume", systemImage: "play.fill") }
                .help("Resume (⌘R)")
                .disabled(!canResume)
            Button { Actions.pause(ui.selection) } label: { Label("Pause", systemImage: "pause.fill") }
                .help("Pause (⌘.)")
                .disabled(!canPause)
            Button { Actions.remove(ui.selection) } label: { Label("Remove", systemImage: "trash") }
                .help("Remove")
                .disabled(ui.selection.isEmpty)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                manager.queueRunning ? manager.stopQueue() : manager.startQueue()
            } label: {
                Label(manager.queueRunning ? "Stop Queue" : "Start Queue",
                      systemImage: manager.queueRunning ? "stop.circle" : "list.bullet.circle")
            }
            .help(manager.queueRunning ? "Stop the queue" : "Start the queue")
            Button { WindowPresenter.showScheduler() } label: { Label("Scheduler", systemImage: "calendar.badge.clock") }
                .help("Queue & Scheduler")
            Toggle(isOn: $settings.prefs.speedLimitEnabled) {
                Label("Speed Limiter", systemImage: "gauge.with.dots.needle.33percent")
            }
            .help(settings.prefs.speedLimitEnabled ? "Speed limited to \(settings.prefs.speedLimitKBps) KB/s" : "Speed limiter is off")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { UIState.shared.showInspector.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
                .help("Show or hide details")
        }
    }

    private var canResume: Bool {
        ui.selectedItems.contains { [.paused, .failed, .queued].contains($0.record.status) }
    }

    private var canPause: Bool {
        ui.selectedItems.contains { $0.record.status.isRunning || $0.record.status == .queued }
    }
}

// MARK: - List

private struct DownloadListView: View {
    let items: [DownloadItem]
    @Binding var sortOrder: [KeyPathComparator<DownloadItem>]
    @Bindable private var ui = UIState.shared

    var body: some View {
        Group {
            if items.isEmpty {
                emptyState
            } else {
                table
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBarView() }
    }

    private var table: some View {
        Table(items, selection: $ui.selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.record.fileName) { item in NameCell(item: item) }
                .width(min: 200, ideal: 340)
            TableColumn("Size", value: \.record.totalBytes) { item in
                Text(item.sizeText).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 64, ideal: 84)
            TableColumn("Progress", value: \.progress) { item in ProgressCell(item: item) }
                .width(min: 110, ideal: 160)
            TableColumn("Status", value: \.statusRank) { item in StatusCell(item: item) }
                .width(min: 90, ideal: 130)
            TableColumn("Speed", value: \.speed) { item in
                Text(Fmt.speed(item.speed)).monospacedDigit()
            }
            .width(min: 64, ideal: 84)
            TableColumn("Time Left", value: \.etaRank) { item in
                Text(item.eta.map(Fmt.duration) ?? "").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 76)
            TableColumn("Added", value: \.record.dateAdded) { item in
                Text(item.record.dateAdded, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            ItemMenu(ids: ids)
        } primaryAction: { ids in
            Actions.open(ids)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(ui.search.isEmpty ? "No Downloads" : "No Results", systemImage: "arrow.down.circle")
        } description: {
            if ui.search.isEmpty {
                Text("Add a link with ⌘N, drop one here, copy a download link, or use the browser extension.")
            } else {
                Text("Nothing matches “\(ui.search)”.")
            }
        } actions: {
            if ui.search.isEmpty {
                Button("New Download…") { WindowPresenter.showAdd() }
            }
        }
    }
}

struct ItemMenu: View {
    let ids: Set<UUID>

    var body: some View {
        let items = Actions.items(ids)
        let finished = items.contains { $0.record.status == .completed }
        if !items.isEmpty {
            if finished {
                Button("Open") { Actions.open(ids) }
            }
            Button("Show in Finder") { Actions.reveal(ids) }
            Divider()
            if items.contains(where: { [.paused, .failed, .queued].contains($0.record.status) }) {
                Button("Resume") { Actions.resume(ids) }
            }
            if items.contains(where: { $0.record.status.isRunning || $0.record.status == .queued }) {
                Button("Pause") { Actions.pause(ids) }
            }
            if items.contains(where: { $0.record.status == .paused || $0.record.status == .failed }) {
                Button("Add to Queue") { Actions.addToQueue(ids) }
            }
            Button(finished ? "Download Again" : "Restart") { Actions.restart(ids) }
            Divider()
            Button("Copy Address") { Actions.copyAddresses(ids) }
            Divider()
            Button("Remove…", role: .destructive) { Actions.remove(ids) }
        }
    }
}

// MARK: - Cells

struct FileIcon: View {
    let fileName: String
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: IconCache.icon(for: fileName))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for fileName: String) -> NSImage {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if let cached = cache[ext] { return cached }
        let type = UTType(filenameExtension: ext) ?? .data
        let image = NSWorkspace.shared.icon(for: type)
        cache[ext] = image
        return image
    }
}

private struct NameCell: View {
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 8) {
            FileIcon(fileName: item.record.fileName, size: 18)
            Text(item.record.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(item.record.url.absoluteString)
    }
}

private struct ProgressCell: View {
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 6) {
            if item.record.status == .connecting || item.record.status == .processing || (item.record.status == .downloading && item.record.totalBytes < 0 && item.parts == nil) {
                ProgressView().progressViewStyle(.linear)
            } else {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                    .tint(tint)
            }
            Text(item.progress, format: .percent.precision(.fractionLength(0)))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .controlSize(.small)
    }

    private var tint: Color {
        switch item.record.status {
        case .completed: return .green
        case .failed: return .red
        case .paused, .queued: return .orange
        default: return .accentColor
        }
    }
}

struct StatusCell: View {
    let item: DownloadItem

    var body: some View {
        Label {
            Text(item.statusText)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .help(item.record.lastError ?? item.statusText)
    }

    private var symbol: String {
        switch item.record.status {
        case .queued: return item.record.startWhenPossible ? "hourglass" : "clock"
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .downloading: return "arrow.down.circle.fill"
        case .paused: return "pause.circle.fill"
        case .processing: return "gearshape.2"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch item.record.status {
        case .downloading, .connecting, .processing: return .accentColor
        case .completed: return .green
        case .failed: return .red
        case .paused: return .orange
        case .queued: return .secondary
        }
    }
}

// MARK: - Status bar

private struct StatusBarView: View {
    private var manager: DownloadManager { .shared }
    private var settings: SettingsStore { .shared }
    private var bridge: BridgeStatus { .shared }
    private var extensions: ExtensionStatus { .shared }

    var body: some View {
        HStack(spacing: 14) {
            Label(Fmt.speed(manager.totalSpeed).isEmpty ? "Idle" : Fmt.speed(manager.totalSpeed), systemImage: "arrow.down")
                .monospacedDigit()
            let waiting = manager.items.filter { $0.record.status == .queued }.count
            Text("\(manager.runningCount) active · \(waiting) waiting")
            if settings.prefs.speedLimitEnabled {
                Label("Limited to \(Fmt.bytes(Int64(settings.prefs.speedLimitKBps) * 1024))/s", systemImage: "gauge.with.dots.needle.33percent")
                    .foregroundStyle(.orange)
            }
            if manager.queueRunning {
                Label("Queue running", systemImage: "list.bullet.circle").foregroundStyle(Color.accentColor)
            }
            Spacer()
            if !bridge.listening {
                Label("Browser integration off", systemImage: "puzzlepiece.extension")
                    .foregroundStyle(.red)
                    .help(bridge.message)
            } else if extensions.isConnected {
                Button { WindowPresenter.showBrowserSetup() } label: {
                    Label("Browser extension connected", systemImage: "puzzlepiece.extension.fill")
                }
                .buttonStyle(.plain)
                .help("Connected: " + extensions.lastSeen.keys.sorted().joined(separator: ", "))
            } else {
                Button { WindowPresenter.showBrowserSetup() } label: {
                    Label("Set up browser extension…", systemImage: "puzzlepiece.extension")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .help("Downloads stay in the browser until the extension is added")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
