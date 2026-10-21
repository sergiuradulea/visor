import AppKit
import SwiftUI

/// Now-playing state, fed by the VisorMedia helper (see its main.swift for why it's separate).
final class MediaModel: ObservableObject {
    static let shared = MediaModel()
    enum Command: Int { case play = 0, pause = 1, toggle = 2, next = 4, previous = 5 }

    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var bundleId: String?
    @Published var duration = 0.0
    @Published var playing = false
    @Published var artwork: NSImage? { didSet { accent = artwork?.accentColor ?? .white } }
    @Published var accent: Color = .white
    private var elapsed = 0.0
    private var timestamp = Date()
    private var rate = 1.0
    private var process: Process?
    private var startedAt = Date()
    private var quickExits = 0
    private var buffer = Data()

    private let helper = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Helpers/VisorMedia.app/Contents/MacOS/VisorMedia")

    var appName: String {
        guard let id = bundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return "" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    func position(at date: Date) -> Double {
        let p = playing ? elapsed + date.timeIntervalSince(timestamp) * (rate == 0 ? 1 : rate) : elapsed
        return min(max(p, 0), duration)
    }

    func start() {
        startedAt = Date()
        let p = Process()
        p.executableURL = helper
        p.arguments = ["stream"]
        p.standardInput = Pipe() // helper exits when this closes, i.e. when we quit
        let out = Pipe()
        p.standardOutput = out
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            DispatchQueue.main.async { self?.consume(chunk) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.restartAfterExit() }
        }
        do { try p.run(); process = p } catch { NSLog("Visor: media helper failed: \(error)") }
    }

    /// Relaunch a crashed helper, but give up if it keeps dying right away (e.g. a macOS update
    /// removed a private MediaRemote function) instead of respawning it every 2 s forever.
    private func restartAfterExit() {
        quickExits = Date().timeIntervalSince(startedAt) < 10 ? quickExits + 1 : 0
        guard quickExits < 3 else { return NSLog("Visor: media helper keeps exiting; now playing disabled") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer = Data(buffer[buffer.index(after: nl)...])
            if let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { apply(d) }
        }
    }

    func apply(_ d: [String: Any]) {
        bundleId = d["bundleId"] as? String
        title = d["title"] as? String ?? ""
        artist = d["artist"] as? String ?? ""
        album = d["album"] as? String ?? ""
        duration = d["duration"] as? Double ?? 0
        elapsed = d["elapsed"] as? Double ?? 0
        rate = d["rate"] as? Double ?? 1
        timestamp = (d["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        playing = bundleId != nil && (d["playing"] as? Bool ?? false)
        if let b64 = d["artwork"] as? String, let data = Data(base64Encoded: b64) {
            artwork = NSImage(data: data)
        } else if d["artwork"] is NSNull {
            artwork = nil
        } // key missing: artwork unchanged
    }

    private func runHelper(_ args: [String]) {
        let p = Process()
        p.executableURL = helper
        p.arguments = args
        try? p.run()
    }

    func send(_ c: Command) {
        if c == .toggle { // optimistic, the stream confirms a moment later
            elapsed = position(at: Date()); timestamp = Date(); playing.toggle()
        }
        runHelper(["send", String(c.rawValue)])
    }

    func seek(to seconds: Double) {
        elapsed = seconds; timestamp = Date()
        objectWillChange.send()
        runHelper(["seek", String(seconds)])
    }

    func openPlayer() {
        guard let id = bundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

extension NSImage {
    private static let ciContext = CIContext() // expensive to create; reuse across tracks
    /// Average colour of the artwork, lifted so it reads on black.
    var accentColor: Color? {
        guard let tiff = tiffRepresentation, let ci = CIImage(data: tiff),
              let f = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)]),
              let out = f.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        Self.ciContext.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let c = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        return Color(nsColor: NSColor(hue: c.hueComponent, saturation: min(c.saturationComponent * 1.3, 1),
                                      brightness: max(c.brightnessComponent, 0.8), alpha: 1))
    }
}
