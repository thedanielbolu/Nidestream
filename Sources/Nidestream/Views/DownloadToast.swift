import AppKit
import NidestreamCore
import SwiftUI

/// The small "Downloading in Nidestream" pop-up in the top-right corner when a download comes in
/// from the browser. It shows above full-screen apps, needs no notification permission, and fades
/// out by itself; clicking it opens Nidestream.
@MainActor
enum DownloadToast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?
    private static var recent: [String] = []

    /// `title` replaces "Downloading in Nidestream", for example "Already downloaded".
    static func show(fileName: String, size: Int64, title: String? = nil) {
        if title == nil { recent.append(fileName) } else { recent = [fileName] }
        let view = ToastView(names: recent, size: recent.count == 1 && size > 0 ? size : nil, title: title) {
            WindowPresenter.showMain()
            hide()
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: view)
        panel.contentView = host
        let size = host.fittingSize
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: screen.maxX - size.width - 12, y: screen.maxY - size.height - 8, width: size.width, height: size.height),
                       display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { hide() } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    static func hide() {
        hideWork?.cancel()
        recent.removeAll()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }
}

struct ToastView: View {
    let names: [String]
    let size: Int64?
    var title: String? = nil
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? (names.count == 1 ? "Downloading in Nidestream" : "Downloading \(names.count) files in Nidestream"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.brand)
                Text(names.last ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let size {
                    Text(Fmt.bytes(size))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 250, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .padding(14)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .help("Open Nidestream")
    }
}
