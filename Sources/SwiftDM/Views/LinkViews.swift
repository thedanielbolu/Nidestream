import AppKit
import SwiftDMCore
import SwiftUI

struct FoundLink: Identifiable, Hashable {
    let id = UUID()
    var url: URL
    var text: String?
    var type: String?
    var size: Int64?
    var selected = false

    var fileName: String {
        let name = url.lastPathComponent
        return name.isEmpty || name == "/" ? (url.host ?? url.absoluteString) : name
    }

    var ext: String { url.pathExtension.lowercased() }
    var isHLS: Bool { type == "hls" || ext == "m3u8" }
}

struct LinkContext {
    var referrer: String?
    var cookiesByHost: [String: String] = [:]
    var userAgent: String?
    var title: String
    var isMedia = false
}

/// Lets the user tick which of many links to download: "Download all links", site grabber, imports, media.
struct LinkPickerView: View {
    let context: LinkContext
    let close: () -> Void
    @State private var links: [FoundLink]
    @State private var filter = ""
    @State private var filesOnly: Bool
    @State private var directory: URL?

    init(links: [FoundLink], context: LinkContext, close: @escaping () -> Void) {
        self.context = context
        self.close = close
        let known = Set(SettingsStore.shared.prefs.categories.flatMap(\.extensions))
        let anyKnown = links.contains { known.contains($0.ext) || $0.isHLS }
        let prepared = links.map { link -> FoundLink in
            var link = link
            link.selected = context.isMedia ? false : (known.contains(link.ext) || link.isHLS || !anyKnown)
            return link
        }
        var initial = prepared
        if context.isMedia, let best = initial.indices.max(by: { Self.mediaScore(initial[$0]) < Self.mediaScore(initial[$1]) }) {
            initial[best].selected = true
        }
        _links = State(initialValue: initial)
        _filesOnly = State(initialValue: !context.isMedia && anyKnown)
    }

    private static func mediaScore(_ link: FoundLink) -> Int64 {
        link.isHLS && link.url.absoluteString.lowercased().contains("master") ? .max : (link.size ?? (link.isHLS ? 1 : 0))
    }

    private var visible: [FoundLink] {
        let known = Set(SettingsStore.shared.prefs.categories.flatMap(\.extensions))
        return links.filter { link in
            (!filesOnly || known.contains(link.ext) || link.isHLS)
                && (filter.isEmpty || link.url.absoluteString.localizedCaseInsensitiveContains(filter)
                    || (link.text?.localizedCaseInsensitiveContains(filter) ?? false))
        }
    }

    private var selectedCount: Int { links.filter(\.selected).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !context.title.isEmpty {
                Text(context.title).font(.headline).lineLimit(1)
            }
            HStack {
                TextField("Filter", text: $filter, prompt: Text("Filter by name or address"))
                    .textFieldStyle(.roundedBorder)
                if !context.isMedia {
                    Toggle("Files only", isOn: $filesOnly)
                }
                Menu("Select") {
                    Button("All Shown") { setSelection(true) }
                    Button("None") { setSelection(false) }
                    Divider()
                    ForEach(SettingsStore.shared.prefs.categories.filter { !$0.extensions.isEmpty }) { category in
                        Button(category.name) {
                            let extensions = Set(category.extensions)
                            for index in links.indices where extensions.contains(links[index].ext) { links[index].selected = true }
                        }
                    }
                }
                .fixedSize()
            }
            Table(visible) {
                TableColumn("") { link in
                    Toggle("", isOn: binding(for: link.id)).labelsHidden()
                }
                .width(22)
                TableColumn("Name") { link in
                    HStack(spacing: 6) {
                        FileIcon(fileName: link.isHLS ? "video.mp4" : link.fileName)
                        Text(link.fileName).lineLimit(1).truncationMode(.middle)
                    }
                }
                .width(min: 160, ideal: 240)
                TableColumn("Type") { link in
                    Text(link.isHLS ? "HLS stream" : (link.type ?? link.ext.uppercased())).foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 90)
                TableColumn("Size") { link in
                    Text(link.size.map(Fmt.bytes) ?? "").foregroundStyle(.secondary).monospacedDigit()
                }
                .width(min: 50, ideal: 70)
                TableColumn("Text") { link in Text(link.text ?? "").foregroundStyle(.secondary).lineLimit(1) }
                    .width(min: 80, ideal: 150)
                TableColumn("Address") { link in
                    Text(link.url.absoluteString).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .width(min: 160, ideal: 300)
            }
            HStack {
                Text("\(selectedCount) of \(links.count) selected").foregroundStyle(.secondary)
                Spacer()
                Button(directory.map { "Save to \($0.lastPathComponent)" } ?? "Save to category folders") { chooseFolder() }
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                Button("Add to Queue") { submit(start: false) }.disabled(selectedCount == 0)
                Button("Download Now") { submit(start: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedCount == 0)
            }
        }
        .padding(16)
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(get: { links.first { $0.id == id }?.selected ?? false },
                set: { value in
                    if let index = links.firstIndex(where: { $0.id == id }) { links[index].selected = value }
                })
    }

    private func setSelection(_ value: Bool) {
        let shown = Set(visible.map(\.id))
        for index in links.indices where shown.contains(links[index].id) || !value { links[index].selected = value }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK { directory = panel.url }
    }

    private func submit(start: Bool) {
        for link in links where link.selected {
            var new = NewDownload(url: link.url)
            new.referrer = context.referrer
            new.cookies = link.url.host.flatMap { context.cookiesByHost[$0] }
            new.userAgent = context.userAgent
            new.directory = directory
            new.note = link.text ?? context.title
            new.totalBytes = link.size
            if link.isHLS {
                new.kind = .hls
                let title = context.title.isEmpty ? (link.url.deletingPathExtension().lastPathComponent) : context.title
                new.fileName = HTTPHeaderParsing.sanitizeFileName(title) + ".mp4"
            }
            DownloadManager.shared.add(new, start: start)
        }
        close()
    }
}

struct BatchDownloadView: View {
    let close: () -> Void
    @State private var template = ""
    @State private var useLetters = false
    @State private var fromNumber = 1
    @State private var toNumber = 10
    @State private var width = 0
    @State private var fromLetter = "a"
    @State private var toLetter = "z"

    private var urls: [String] {
        let range: BatchPattern.Range
        if useLetters {
            guard let from = fromLetter.first, let to = toLetter.first else { return [] }
            range = .letters(from: from, to: to)
        } else {
            range = .numbers(from: fromNumber, to: toNumber, width: width)
        }
        return BatchPattern.expand(template, range: range, limit: 5000)
            .filter { URL(string: $0)?.scheme.map { ["http", "https"].contains($0.lowercased()) } ?? false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Use * in the address where the number or letter goes, for example https://example.com/photos/img*.jpg")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Address", text: $template, prompt: Text("https://example.com/file*.zip"))
                Picker("Replace * with", selection: $useLetters) {
                    Text("Numbers").tag(false)
                    Text("Letters").tag(true)
                }
                .pickerStyle(.segmented)
                if useLetters {
                    TextField("From", text: $fromLetter)
                    TextField("To", text: $toLetter)
                } else {
                    TextField("From", value: $fromNumber, format: .number)
                    TextField("To", value: $toNumber, format: .number)
                    Stepper(value: $width, in: 0...8) {
                        LabeledContent("Digits", value: width == 0 ? "As needed" : "\(width) (e.g. \(String(repeating: "0", count: max(0, width - 1)))1)")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            if let first = urls.first {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(urls.count) files").font(.callout.weight(.semibold))
                    Text("First: \(first)").lineLimit(1).truncationMode(.middle)
                    if urls.count > 1, let last = urls.last { Text("Last: \(last)").lineLimit(1).truncationMode(.middle) }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Review Links…") {
                    WindowPresenter.showLinkPicker(urls.compactMap(URL.init(string:)).map { FoundLink(url: $0) },
                                                   context: LinkContext(title: "Batch download"))
                    close()
                }
                .disabled(urls.isEmpty || !template.contains("*"))
                Button("Add to Queue") { add(start: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(urls.isEmpty || !template.contains("*"))
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func add(start: Bool) {
        for address in urls {
            if let url = URL(string: address) { DownloadManager.shared.add(NewDownload(url: url), start: start) }
        }
        close()
    }
}

/// IDM's Site Grabber: crawl a site to a chosen depth and collect files of chosen types.
struct GrabberView: View {
    let close: () -> Void
    @State private var address = ""
    @State private var depth = 1
    @State private var sameHost = true
    @State private var selectedCategories: Set<String> = ["compressed", "documents", "music", "programs", "video"]
    @State private var includeImages = false
    @State private var extraExtensions = ""
    @State private var status = ""
    @State private var scanning = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                TextField("Start page", text: $address, prompt: Text("https://example.com/downloads/"))
                Stepper(value: $depth, in: 0...4) {
                    LabeledContent("Follow links", value: depth == 0 ? "This page only" : "\(depth) level\(depth == 1 ? "" : "s") deep")
                }
                Toggle("Stay on the same site", isOn: $sameHost)
                LabeledContent("File types") {
                    VStack(alignment: .leading) {
                        ForEach(SettingsStore.shared.prefs.categories.filter { !$0.extensions.isEmpty }) { category in
                            Toggle(category.name, isOn: Binding(get: { selectedCategories.contains(category.id) },
                                                                set: { on in
                                                                    if on { selectedCategories.insert(category.id) } else { selectedCategories.remove(category.id) }
                                                                }))
                        }
                        Toggle("Images", isOn: $includeImages)
                    }
                }
                TextField("Other extensions", text: $extraExtensions, prompt: Text("e.g. srt, torrent"))
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                if scanning { ProgressView().controlSize(.small) }
                Text(status).foregroundStyle(.secondary).font(.callout)
                Spacer()
                Button("Cancel", role: .cancel) {
                    task?.cancel()
                    close()
                }
                .keyboardShortcut(.cancelAction)
                Button(scanning ? "Scanning…" : "Scan") { scan() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(scanning || URL(string: address)?.host == nil)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private var extensions: Set<String> {
        var result = Set(SettingsStore.shared.prefs.categories.filter { selectedCategories.contains($0.id) }.flatMap(\.extensions))
        if includeImages { result.formUnion(["jpg", "jpeg", "png", "gif", "webp", "heic", "tiff", "bmp", "svg"]) }
        for item in extraExtensions.split(whereSeparator: { $0 == "," || $0 == " " }) {
            result.insert(item.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased())
        }
        result.remove("")
        result.remove("m3u8")
        return result
    }

    private func scan() {
        guard let start = URL(string: address.trimmingCharacters(in: .whitespaces)), start.host != nil else { return }
        scanning = true
        status = "Starting…"
        let options = CrawlOptions(startURL: start, depth: depth, sameHost: sameHost, extensions: extensions,
                                   headers: ["User-Agent": SettingsStore.shared.prefs.userAgent])
        task = Task {
            let found = await SiteCrawler.crawl(options) { pages, files in
                Task { @MainActor in status = "Scanned \(pages) page\(pages == 1 ? "" : "s"), found \(files) file\(files == 1 ? "" : "s")" }
            }
            scanning = false
            guard !Task.isCancelled else { return }
            if found.isEmpty {
                status = "No matching files found."
            } else {
                WindowPresenter.showLinkPicker(found.map { FoundLink(url: $0.url, text: $0.text) },
                                               context: LinkContext(referrer: start.absoluteString, title: "Files on \(start.host ?? "site")"))
                close()
            }
        }
    }
}

struct CountdownView: View {
    let action: PostQueueAction
    let close: () -> Void
    @State private var remaining = 30

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 36)).foregroundStyle(.green)
            Text("The download queue has finished").font(.headline)
            Text("SwiftDM will \(verb) in \(remaining) seconds.").foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                Button("\(action.title) Now") {
                    close()
                    Scheduler.perform(action)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .task {
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                remaining -= 1
            }
            close()
            Scheduler.perform(action)
        }
    }

    private var verb: String {
        switch action {
        case .nothing: return "do nothing"
        case .quit: return "quit"
        case .sleep: return "put your Mac to sleep"
        case .shutDown: return "shut down your Mac"
        }
    }
}
