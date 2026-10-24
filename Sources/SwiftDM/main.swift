import Foundation
import SwiftDMCore

// `SwiftDM --download <url>` runs a single download in the terminal; otherwise start the app.
if CommandLine.arguments.contains("--download") {
    exit(CommandLineDownload.run(CommandLine.arguments))
}
SwiftDMApp.main()
