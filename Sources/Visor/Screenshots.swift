import AppKit
import SwiftUI

/// `swift run -c release Visor --screenshots docs/screenshots [--artwork cover.jpg]`
/// Renders the real views offscreen with made-up demo data, for the README. Refuses to run
/// from the .app so it can never touch a real install's settings.
enum Screenshots {
    static func run(into dir: URL, artwork coverFile: URL? = nil) {
        guard Bundle.main.bundleIdentifier == nil else {
            fputs("Run --screenshots from `swift run`, not from the .app\n", stderr)
            exit(1)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let samples = FileManager.default.temporaryDirectory.appendingPathComponent("visor-samples", isDirectory: true)
        seedDemoData(samples, cover: coverFile.flatMap { NSImage(contentsOf: $0) })

        let state = NotchState.shared
        state.notchSize = CGSize(width: 190, height: 32)
        let wide = CGSize(width: 1000, height: 330), strip = CGSize(width: 1000, height: 96)

        state.expanded = true
        for tab in NotchState.Tab.allCases {
            state.tab = tab
            render("\(tab.rawValue).png", size: wide, into: dir)
        }
        state.expanded = false
        render("collapsed-music.png", size: strip, into: dir)
        state.hud = HUD(kind: .volume, level: 0.62)
        render("hud-volume.png", size: strip, into: dir)
        state.hud = HUD(kind: .brightness, level: 0.8)
        render("hud-brightness.png", size: strip, into: dir)
        state.hud = nil
        Downloads.shared.begin(downloadProgress(samples))
        MediaModel.shared.playing = false
        render("collapsed-download.png", size: strip, into: dir)

        try? FileManager.default.removeItem(at: samples)
        // The tray persists to UserDefaults; this unbundled binary has its own domain, wipe it.
        UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
        print("Wrote screenshots to \(dir.path)")
    }

    private static func render(_ name: String, size: CGSize, into dir: URL) {
        let host = NSHostingView(rootView: Canvas())
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date() + 1.5) // let thumbnails load and animations settle
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
        window.orderOut(nil)
    }

    /// Fake desktop: wallpaper, menu bar, and the notch on top.
    private struct Canvas: View {
        var body: some View {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.13, green: 0.16, blue: 0.42), Color(red: 0.55, green: 0.25, blue: 0.55),
                                        Color(red: 0.96, green: 0.55, blue: 0.38)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                HStack(spacing: 18) {
                    Text("Finder").fontWeight(.bold)
                    ForEach(["File", "Edit", "View", "Go", "Window", "Help"], id: \.self) { Text($0) }
                    Spacer()
                    Image(systemName: "wifi")
                    Image(systemName: "battery.75percent")
                    Text("Wed 21 Oct  14:34")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 32)
                .background(.white.opacity(0.12))
                NotchRoot()
            }
        }
    }

    private static func seedDemoData(_ samples: URL, cover: NSImage?) {
        try? FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        let art = artwork()
        // The real cover is passed in with --artwork (not stored in the repo); generated art otherwise.
        let nowPlaying = cover ?? art
        MediaModel.shared.apply([
            "bundleId": "com.apple.Music", "title": "Chase The Lights (feat. Marns)", "artist": "Kings Of The Rollers",
            "album": "Chase The Lights (feat. Marns) - Single",
            "duration": 227.0, "elapsed": 84.0, "rate": 1.0, "playing": true,
            "timestamp": Date().timeIntervalSince1970,
            "artwork": nowPlaying.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }?.base64EncodedString() ?? NSNull(),
        ])

        let png = samples.appendingPathComponent("Hero shot.png")
        try? art.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }?.write(to: png)
        let md = samples.appendingPathComponent("Launch checklist.md")
        try? "# Launch checklist\n\n- [x] Screenshots\n- [x] README\n- [ ] Ship it\n".write(to: md, atomically: true, encoding: .utf8)
        let pdf = samples.appendingPathComponent("Quarterly report.pdf")
        let page = NSTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        page.string = "Quarterly report\n\nRevenue up 24%.\nChurn down 3 points.\nNotch usage: all time high."
        page.font = .systemFont(ofSize: 14)
        try? page.dataWithPDF(inside: page.bounds).write(to: pdf)
        let zip = samples.appendingPathComponent("design-assets.zip")
        FileManager.default.createFile(atPath: zip.path, contents: Data(count: 64))
        TrayStore.shared.items = [png, pdf, md, zip]

        UserDefaults.standard.register(defaults: ["notes": """
            Call Dana back about the venue ☎️
            Pick up: oat milk, coffee beans, AA batteries
            Idea: notch timer that turns red when a meeting runs over
            """])

        let now = Date()
        ClipboardStore.shared.clips = [
            Clip(date: now.addingTimeInterval(-40), text: "https://github.com/sergiuradulea/visor"),
            Clip(date: now.addingTimeInterval(-300), text: "Meet at 7 by the north entrance?"),
            Clip(date: now.addingTimeInterval(-900), text: "./build.sh && open build/Visor.app"),
            Clip(date: now.addingTimeInterval(-3600), thumb: art.tiffRepresentation.flatMap { ClipboardStore.encode($0)?.thumb }),
            Clip(date: now.addingTimeInterval(-7200), text: "Thanks! Sending the files over now."),
        ]
    }

    private static func downloadProgress(_ samples: URL) -> Progress {
        let p = Progress(totalUnitCount: 100)
        p.completedUnitCount = 64
        p.fileURL = samples.appendingPathComponent("Wallpapers 4K.zip.crdownload")
        return p
    }

    /// Generated album art, so no real artwork is shipped in the repo.
    private static func artwork() -> NSImage {
        NSImage(size: NSSize(width: 400, height: 400), flipped: false) { r in
            NSGradient(colors: [NSColor(red: 0.98, green: 0.35, blue: 0.45, alpha: 1), NSColor(red: 0.35, green: 0.2, blue: 0.75, alpha: 1)])?
                .draw(in: r, angle: -60)
            NSColor(red: 1, green: 0.85, blue: 0.4, alpha: 0.95).setFill()
            NSBezierPath(ovalIn: NSRect(x: 130, y: 170, width: 140, height: 140)).fill()
            NSColor(white: 0, alpha: 0.35).setFill()
            for i in 0..<6 { NSBezierPath(rect: NSRect(x: 0, y: 40 + i * 22, width: 400, height: 8)).fill() }
            return true
        }
    }
}
