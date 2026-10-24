import AppKit
import CryptoKit
import SwiftDMCore
import SwiftUI

struct InspectorView: View {
    let item: DownloadItem?
    let selectionCount: Int

    var body: some View {
        if let item {
            ScrollView {
                DownloadDetails(item: item)
                    .padding(16)
            }
            .id(item.id)
        } else {
            ContentUnavailableView(selectionCount > 1 ? "\(selectionCount) Downloads Selected" : "No Selection",
                                   systemImage: "sidebar.right",
                                   description: Text(selectionCount > 1 ? "Select a single download to see its details." : "Select a download to see its details."))
        }
    }
}

private struct DownloadDetails: View {
    let item: DownloadItem
    @State private var checksum: String?
    @State private var hashing = false
    @State private var editingAddress = false
    @State private var newAddress = ""
    @State private var showLogin = false
    @State private var username = ""
    @State private var password = ""

    private var record: DownloadRecord { item.record }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            progressSection
            if let error = record.lastError, record.status == .failed {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                if record.lastError?.contains("401") == true || record.lastError?.contains("403") == true {
                    Button("Enter Login…") { showLogin = true }
                }
            }
            actions
            Divider()
            info
            if record.status == .completed { checksumSection }
            if record.kind == .http, record.status != .completed, record.segments.count > 1 { connectionsSection }
        }
        .sheet(isPresented: $editingAddress) { addressSheet }
        .sheet(isPresented: $showLogin) { loginSheet }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            FileIcon(fileName: record.fileName, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.fileName)
                    .font(.headline)
                    .textSelection(.enabled)
                    .lineLimit(3)
                Text(record.url.host ?? record.url.absoluteString)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                StatusCell(item: item).font(.callout)
            }
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if record.kind == .http {
                SegmentMap(segments: record.segments, total: record.totalBytes, active: Set(item.activeSegments),
                           complete: record.status == .completed)
            } else {
                ProgressView(value: item.progress).progressViewStyle(.linear)
            }
            HStack {
                Text(progressText).monospacedDigit()
                Spacer()
                if record.status == .downloading {
                    Text(Fmt.speed(item.speed)).monospacedDigit()
                    if let eta = item.eta { Text("· \(Fmt.duration(eta)) left").monospacedDigit() }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var progressText: String {
        if record.status == .completed { return Fmt.bytes(record.totalBytes) }
        if record.totalBytes > 0 {
            let percent = Int((Double(record.receivedBytes) / Double(record.totalBytes) * 100).rounded(.down))
            return "\(Fmt.bytes(record.receivedBytes)) of \(record.kind == .hls ? "~" : "")\(Fmt.bytes(record.totalBytes)) (\(percent)%)"
        }
        return record.receivedBytes > 0 ? Fmt.bytes(record.receivedBytes) : "Not started"
    }

    private var actions: some View {
        HStack {
            switch record.status {
            case .completed:
                Button("Open") { NSWorkspace.shared.open(record.fileURL) }
                    .keyboardShortcut(.defaultAction)
            case .paused, .failed, .queued:
                Button("Resume") { DownloadManager.shared.resume([item]) }
            default:
                Button("Pause") { DownloadManager.shared.pause([item]) }
            }
            Button("Show in Finder") { Actions.reveal([item.id]) }
            Menu {
                Button("Copy Address") { Actions.copyAddresses([item.id]) }
                if record.status != .completed {
                    Button("Change Address…") {
                        newAddress = record.url.absoluteString
                        editingAddress = true
                    }
                    Button("Login…") {
                        username = record.username ?? ""
                        password = ""
                        showLogin = true
                    }
                }
                Button(record.status == .completed ? "Download Again" : "Restart") { DownloadManager.shared.restart([item]) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .controlSize(.regular)
    }

    private var info: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
            row("Size", record.totalBytes >= 0 ? Fmt.bytes(record.totalBytes) : "Unknown")
            row("Resume", record.kind == .hls ? "Yes (by segment)" : (record.resumable ? "Yes" : "No"))
            if record.status.isRunning, record.kind == .http {
                row("Connections", "\(item.activeSegments.count) of \(record.maxConnections)")
            }
            if let parts = item.parts { row("Segments", "\(parts.done) of \(parts.total)") }
            GridRow {
                Text("Saved in").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Button(record.directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    NSWorkspace.shared.activateFileViewerSelecting([record.directory])
                }
                .buttonStyle(.link)
                .lineLimit(2)
            }
            GridRow {
                Text("Address").foregroundStyle(.secondary)
                Text(record.url.absoluteString)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .truncationMode(.middle)
            }
            if let referrer = record.referrer, !referrer.isEmpty { row("Referrer", referrer) }
            if let note = record.note, !note.isEmpty { row("From page", note) }
            if let mime = record.mimeType { row("Type", mime) }
            row("Added", record.dateAdded.formatted(date: .abbreviated, time: .shortened))
            if let completed = record.dateCompleted { row("Finished", completed.formatted(date: .abbreviated, time: .shortened)) }
        }
        .font(.callout)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(3)
        }
    }

    private var checksumSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Checksum").font(.subheadline.weight(.semibold))
            if let checksum {
                Text(checksum)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                Button(hashing ? "Calculating…" : "Calculate SHA-256") { computeChecksum() }
                    .disabled(hashing)
            }
        }
    }

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connections").font(.subheadline.weight(.semibold))
            ForEach(record.segments) { segment in
                HStack {
                    Image(systemName: item.activeSegments.contains(segment.id) ? "circle.fill" : (segment.isComplete ? "checkmark.circle" : "circle"))
                        .font(.caption2)
                        .foregroundStyle(item.activeSegments.contains(segment.id) ? Color.accentColor : .secondary)
                    Text("#\(segment.id + 1)")
                    Spacer()
                    Text("\(Fmt.bytes(segment.received)) / \(Fmt.bytes(segment.length ?? 0))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }

    private var addressSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change Address").font(.headline)
            Text("Use this when a link has expired. Progress is kept if the new link serves the same file.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Address", text: $newAddress)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { editingAddress = false }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let url = URL(string: newAddress.trimmingCharacters(in: .whitespaces)), url.scheme != nil {
                        DownloadManager.shared.updateAddress(item, to: url)
                    }
                    editingAddress = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var loginSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Login for \(record.url.host ?? "server")").font(.headline)
            Form {
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
            }
            HStack {
                Spacer()
                Button("Cancel") { showLogin = false }.keyboardShortcut(.cancelAction)
                Button("Save and Resume") {
                    DownloadManager.shared.setPassword(password, username: username, for: item)
                    DownloadManager.shared.resume([item])
                    showLogin = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func computeChecksum() {
        hashing = true
        let url = record.fileURL
        Task.detached(priority: .userInitiated) {
            let result: String = {
                guard let handle = try? FileHandle(forReadingFrom: url) else { return "Couldn't read the file." }
                defer { try? handle.close() }
                var hasher = SHA256()
                while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
                return hasher.finalize().map { String(format: "%02x", $0) }.joined()
            }()
            await MainActor.run {
                checksum = result
                hashing = false
            }
        }
    }
}

/// IDM-style bar showing which parts of the file have arrived and where each connection is working.
struct SegmentMap: View {
    let segments: [Segment]
    let total: Int64
    let active: Set<Int>
    let complete: Bool

    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            context.fill(Path(bounds), with: .color(.secondary.opacity(0.18)))
            if complete {
                context.fill(Path(bounds), with: .color(.green.opacity(0.85)))
                return
            }
            guard total > 0 else { return }
            let scale = size.width / CGFloat(total)
            for segment in segments {
                let x = CGFloat(segment.start) * scale
                let width = CGFloat(segment.received) * scale
                let isActive = active.contains(segment.id)
                if width > 0 {
                    context.fill(Path(CGRect(x: x, y: 0, width: max(1, width), height: size.height)),
                                 with: .color(Color.accentColor.opacity(isActive ? 1 : 0.7)))
                }
                if isActive {
                    context.fill(Path(CGRect(x: x + width - 1, y: 0, width: 2, height: size.height)), with: .color(.white.opacity(0.9)))
                }
                if segment.start > 0 {
                    context.fill(Path(CGRect(x: x, y: 0, width: 0.5, height: size.height)), with: .color(.primary.opacity(0.35)))
                }
            }
        }
        .frame(height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
        .accessibilityLabel("Download progress by connection")
    }
}
