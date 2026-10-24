import Foundation
import NidestreamCore

// `Nidestream --download <url>` runs a single download in the terminal; otherwise start the app.
if CommandLine.arguments.contains("--download") {
    exit(CommandLineDownload.run(CommandLine.arguments))
}
// `Nidestream --render-ui <folder>` draws the menu bar widget and dialogs into PNG files.
if CommandLine.arguments.contains("--render-ui") {
    exit(MainActor.assumeIsolated { UIRender.run(CommandLine.arguments) })
}
NidestreamApp.main()
