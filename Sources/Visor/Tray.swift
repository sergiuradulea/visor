import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Files parked in the notch / basket. Holds references (URLs), never copies.
final class TrayStore: ObservableObject {
    static let shared = TrayStore()
    @Published var items: [URL] = [] {
        didSet { UserDefaults.standard.set(items.map(\.path), forKey: "tray") }
    }

    init() {
        items = (UserDefaults.standard.stringArray(forKey: "tray") ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ url: URL) {
        if !items.contains(url) { items.append(url) }
    }

    private var screenshotQuery: NSMetadataQuery?

    /// New screenshots land in the tray. Spotlight tags them (kMDItemIsScreenCapture), but any
    /// app can set that tag on any file, so only files in the real screenshot folder are accepted.
    func watchScreenshots() {
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "kMDItemIsScreenCapture = 1")
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: q, queue: .main) { [weak self] n in
            let added = n.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? []
            for item in added {
                guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                      URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path == Self.screenshotFolder.path else { continue }
                self?.add(URL(fileURLWithPath: path))
                NotchState.shared.showHUD(HUD(kind: .screenshot, level: 0))
            }
        }
        q.start() // the initial gather (existing screenshots) is ignored; only updates are added
        // Desktop (the default) and Documents are privacy-protected: Spotlight hides their files
        // from us until macOS has asked once. Touching the folder triggers that prompt (off main, it blocks).
        let folder = Self.screenshotFolder
        DispatchQueue.global(qos: .utility).async { _ = try? FileManager.default.contentsOfDirectory(atPath: folder.path) }
        screenshotQuery = q
    }

    /// Where macOS saves screenshots (Screenshot app → Options → Save to); Desktop by default.
    static var screenshotFolder: URL {
        let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        let path = (custom.map { ($0 as NSString).expandingTildeInPath }) ?? NSHomeDirectory() + "/Desktop"
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { DispatchQueue.main.async { self.add(url) } }
            }
        }
        return true
    }
}

/// Shake the pointer while dragging files and a floating basket appears next to it.
final class Basket {
    static let shared = Basket()
    private var panel: NSPanel?
    private var dragChangeCount = 0
    private var lastX: CGFloat = 0, direction: CGFloat = 0, segmentStart: CGFloat = 0
    private var reversals: [Date] = []

    func start() {
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] e in self?.track(e) }
    }

    private func track(_ e: NSEvent) {
        let x = NSEvent.mouseLocation.x
        if e.type == .leftMouseDown {
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            reversals = []; direction = 0; lastX = x; segmentStart = x
            return
        }
        let dx = x - lastX
        lastX = x
        guard abs(dx) > 2 else { return }
        let d: CGFloat = dx > 0 ? 1 : -1
        if d != direction {
            if abs(x - segmentStart) > 25 { reversals.append(Date()) }
            direction = d; segmentStart = x
        }
        reversals.removeAll { -$0.timeIntervalSinceNow > 0.7 }
        let pb = NSPasteboard(name: .drag)
        if reversals.count >= 4, pb.changeCount != dragChangeCount, pb.types?.contains(.fileURL) == true {
            reversals = []
            show(at: NSEvent.mouseLocation)
        }
    }

    func show(at point: NSPoint) {
        let size = NSSize(width: 300, height: 170)
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .floating
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.isMovableByWindowBackground = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = FirstMouseHostingView(rootView: BasketView { [weak self] in self?.hide() })
            panel = p
        }
        panel?.setFrame(NSRect(x: point.x + 20, y: point.y - size.height / 2, width: size.width, height: size.height), display: true)
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}
