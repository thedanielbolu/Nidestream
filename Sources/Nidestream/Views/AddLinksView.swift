import AppKit
import SwiftUI

/// "Add Links": paste one or many links (or a block of text containing them) and download them.
struct AddLinksView: View {
    let close: () -> Void
    @State private var text: String

    init(close: @escaping () -> Void, initialText: String? = nil) {
        self.close = close
        var start = initialText ?? ""
        // Like the single-link dialog, start with whatever links are on the clipboard.
        if initialText == nil, let clip = NSPasteboard.general.string(forType: .string), !LinkParsing.webLinks(in: clip).isEmpty {
            start = clip.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
        _text = State(initialValue: start)
    }

    private var links: [URL] { LinkParsing.webLinks(in: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "link")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.brand))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add Links").font(.title3.bold())
                    Text("Paste one or more download links, one per line. You can also paste a block of text and Nidestream picks out the links.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                if text.isEmpty {
                    Text("https://example.com/file.zip\nhttps://example.com/video.mp4")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 210)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.15)))

            HStack {
                Label(links.isEmpty ? "No links yet" : "\(links.count) link\(links.count == 1 ? "" : "s") found",
                      systemImage: links.isEmpty ? "link.badge.plus" : "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(links.isEmpty ? Color.secondary : Color.brand)
                Spacer()
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button(links.count > 1 ? "Add \(links.count) Links" : "Add Link", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(links.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func submit() {
        let found = links
        guard !found.isEmpty else { return }
        if found.count == 1 {
            WindowPresenter.showAdd(NewDownload(url: found[0]))
        } else {
            WindowPresenter.showLinkPicker(found.map { FoundLink(url: $0) }, context: LinkContext(title: "\(found.count) pasted links"))
        }
        close()
    }
}

enum LinkParsing {
    /// Every http(s) link in `text`, in order, without duplicates.
    static func webLinks(in text: String) -> [URL] {
        guard !text.isEmpty, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen = Set<String>()
        var result: [URL] = []
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { continue }
            if seen.insert(url.absoluteString).inserted { result.append(url) }
        }
        return result
    }
}
