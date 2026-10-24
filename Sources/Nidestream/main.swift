import Foundation
import NidestreamCore

// `Nidestream --download <url>` runs a single download in the terminal; otherwise start the app.
if CommandLine.arguments.contains("--download") {
    exit(CommandLineDownload.run(CommandLine.arguments))
}
NidestreamApp.main()
