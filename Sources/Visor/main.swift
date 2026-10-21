import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        NotchController.shared.start()
        MediaModel.shared.start()
        ClipboardStore.shared.start()
        MediaKeys.shared.start()
        Basket.shared.start()
        TrayStore.shared.watchScreenshots()
        Downloads.shared.start()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
if let i = CommandLine.arguments.firstIndex(of: "--screenshots"), i + 1 < CommandLine.arguments.count {
    let args = CommandLine.arguments
    let art = args.firstIndex(of: "--artwork").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
    // A missing cover must fail loudly: falling back silently once shipped the placeholder art to the README.
    if let art, NSImage(contentsOf: art) == nil { fputs("Can't read artwork at \(art.path)\n", stderr); exit(1) }
    Screenshots.run(into: URL(fileURLWithPath: args[i + 1]), artwork: art)
    exit(0)
}
app.run()
