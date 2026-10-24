import AppKit
import SwiftDMCore
import SwiftUI
import UniformTypeIdentifiers

/// The "Download File Info" dialog: checks the link, then lets the user pick name, folder and options.
struct AddDownloadView: View {
    let close: () -> Void
    private let base: NewDownload?

    @State private var address: String
    @State private var fileName = ""
    @State private var nameEdited = false
    @State private var categoryID: String
    @State private var categoryEdited = false
    @State private var directory: URL
    @State private var directoryEdited = false
    @State private var connections: Int
    @State private var referrer: String
    @State private var username = ""
    @State private var password = ""
    @State private var speedLimit = ""
    @State private var showAdvanced = false
    @State private var probe: ProbeState = .idle
    @State private var master: HLSMasterPlaylist?
    @State private var variant: URL?

    private enum ProbeState {
        case idle, checking
        case done(ProbeResult)
        case failed(String)
    }

    init(initial: NewDownload?, close: @escaping () -> Void) {
        self.close = close
        base = initial
        let prefs = SettingsStore.shared.prefs
        var startAddress = initial?.url.absoluteString ?? ""
        if startAddress.isEmpty, let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: clip), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
            startAddress = clip
        }
        _address = State(initialValue: startAddress)
        let name = initial?.fileName ?? ""
        _fileName = State(initialValue: name)
        _nameEdited = State(initialValue: !name.isEmpty)
        let category = initial?.category ?? FileCategory.detect(fileName: name.isEmpty ? (URL(string: startAddress)?.lastPathComponent ?? "") : name,
                                                                 in: prefs.categories)
        _categoryID = State(initialValue: category)
        _directory = State(initialValue: initial?.directory ?? DownloadManager.shared.folder(for: category))
        _connections = State(initialValue: initial?.connections ?? prefs.connectionsPerDownload)
        _referrer = State(initialValue: initial?.referrer ?? "")
    }

    private var url: URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    private var isHLS: Bool {
        if case .done(let result) = probe, result.isHLS { return true }
        return base?.kind == .hls || url?.pathExtension.lowercased() == "m3u8"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Form {
                TextField("Address", text: $address, prompt: Text("https://example.com/file.zip"))
                TextField("File name", text: Binding(get: { fileName }, set: { fileName = $0; nameEdited = true }))
                Picker("Category", selection: Binding(get: { categoryID }, set: { newValue in
                    categoryID = newValue
                    categoryEdited = true
                    if !directoryEdited { directory = DownloadManager.shared.folder(for: newValue) }
                })) {
                    ForEach(SettingsStore.shared.prefs.categories) { category in
                        Label(category.name, systemImage: category.symbol).tag(category.id)
                    }
                }
                LabeledContent("Save to") {
                    HStack {
                        Text(directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                if let master, !master.variants.isEmpty {
                    Picker("Quality", selection: $variant) {
                        ForEach(master.variants.sorted { $0.bandwidth > $1.bandwidth }) { item in
                            Text(item.label).tag(Optional(item.url))
                        }
                    }
                }
                Stepper(value: $connections, in: 1...32) {
                    LabeledContent("Connections", value: "\(connections)")
                }
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    TextField("Referrer", text: $referrer)
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                    TextField("Speed limit (KB/s)", text: $speedLimit, prompt: Text("No limit"))
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            if let url, let existing = DownloadManager.shared.existingDownload(for: url) {
                Label("This link is already in your list (\(existing.statusText.lowercased())).", systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Download Later") { submit(start: false) }
                    .disabled(url == nil)
                Button("Start Download") { submit(start: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(url == nil)
            }
        }
        .padding(20)
        .frame(width: 580)
        .task(id: address) { await check() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            FileIcon(fileName: fileName.isEmpty ? "file" : fileName, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(fileName.isEmpty ? "New Download" : fileName)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                summary
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var summary: some View {
        switch probe {
        case .idle:
            Text(url == nil ? "Enter or paste a link." : " ")
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking link…")
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
        case .done(let result):
            Text(describe(result))
                .foregroundStyle(result.isWebPage ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
    }

    private func describe(_ result: ProbeResult) -> String {
        if result.isHLS {
            if let master { return "Video stream · \(master.variants.count) quality option\(master.variants.count == 1 ? "" : "s")" }
            return "Video stream (HLS)"
        }
        var parts: [String] = []
        parts.append(result.totalBytes >= 0 ? Fmt.bytes(result.totalBytes) : "Unknown size")
        let ext = (result.fileName as NSString).pathExtension
        if let type = UTType(filenameExtension: ext)?.localizedDescription { parts.append(type) }
        parts.append(result.acceptsRanges ? "Resumable" : "Can't resume")
        if result.isWebPage { parts = ["This link opens a web page, not a file"] }
        return parts.joined(separator: " · ")
    }

    private func check() async {
        master = nil
        guard let url else {
            probe = .idle
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        probe = .checking
        var headers = ["User-Agent": base?.userAgent ?? SettingsStore.shared.prefs.userAgent, "Accept": "*/*"]
        if !referrer.isEmpty { headers["Referer"] = referrer }
        if let cookies = base?.cookies { headers["Cookie"] = cookies }
        let credential = username.isEmpty ? nil : URLCredential(user: username, password: password, persistence: .forSession)
        do {
            let result = try await Prober.probe(url: url, headers: headers, credential: credential, proxy: SettingsStore.shared.prefs.proxy)
            guard !Task.isCancelled else { return }
            if result.isHLS {
                master = await loadMaster(result.finalURL, headers: headers)
                variant = master?.variants.max { $0.bandwidth < $1.bandwidth }?.url
                if !nameEdited {
                    let title = base?.note.flatMap { $0.isEmpty ? nil : HTTPHeaderParsing.sanitizeFileName($0) }
                    fileName = (title ?? (result.fileName as NSString).deletingPathExtension) + ".mp4"
                }
            } else if !nameEdited {
                fileName = result.fileName
            }
            if !categoryEdited {
                categoryID = FileCategory.detect(fileName: fileName, in: SettingsStore.shared.prefs.categories)
                if !directoryEdited { directory = DownloadManager.shared.folder(for: categoryID) }
            }
            probe = .done(result)
        } catch {
            guard !Task.isCancelled else { return }
            probe = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            if !nameEdited { fileName = HTTPHeaderParsing.suggestedFileName(url: url, contentDisposition: nil, mimeType: nil) }
        }
    }

    private func loadMaster(_ url: URL, headers: [String: String]) async -> HLSMasterPlaylist? {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let text = String(data: data, encoding: .utf8),
              case .master(let master)? = try? HLSParser.parse(text, baseURL: response.url ?? url) else { return nil }
        return master
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let chosen = panel.url {
            directory = chosen
            directoryEdited = true
        }
    }

    private func submit(start: Bool) {
        guard let url else { return }
        var new = base ?? NewDownload(url: url)
        new.url = url
        new.fileName = fileName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : fileName
        new.directory = directory
        new.category = categoryID
        new.connections = connections
        new.referrer = referrer.isEmpty ? nil : referrer
        new.username = username.isEmpty ? nil : username
        new.password = password.isEmpty ? nil : password
        new.speedLimitKBps = Int(speedLimit.trimmingCharacters(in: .whitespaces))
        if case .done(let result) = probe {
            new.totalBytes = result.totalBytes
            new.mimeType = result.mimeType
        }
        if isHLS {
            new.kind = .hls
            new.totalBytes = nil
            if let master, let variant, let chosen = master.variants.first(where: { $0.url == variant }) {
                new.hlsVariantURL = chosen.url
                new.hlsAudioURL = master.audio(for: chosen)
            }
        }
        DownloadManager.shared.add(new, start: start)
        close()
    }
}
