import AppKit

/// Live downloads in ~/Downloads. Browsers publish an NSProgress for each file they
/// download (that's what draws Finder's progress bars); we subscribe to the folder,
/// the same way Droppy does. Finished files are added to the tray.
final class Downloads: ObservableObject {
    static let shared = Downloads()

    struct Item: Identifiable {
        let progress: Progress
        var id: ObjectIdentifier { ObjectIdentifier(progress) }
        var fraction: Double { progress.fractionCompleted }
        var name: String { Downloads.finalURL(for: progress.fileURL)?.lastPathComponent ?? "Download" }
    }

    @Published private(set) var active: [Item] = []
    private var subscription: Any?
    private var refresh: Timer?

    var overall: Double { active.isEmpty ? 0 : active.map(\.fraction).reduce(0, +) / Double(active.count) }

    func start() {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        // Downloads is privacy-protected: without access, progress events never arrive.
        // Touching the folder makes macOS ask once; that blocks until answered, so do it off main.
        DispatchQueue.global(qos: .utility).async {
            let allowed = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) != nil
            DispatchQueue.main.async {
                guard allowed else { return NSLog("Visor: no Downloads access; live downloads disabled") }
                self.subscription = Progress.addSubscriber(forFileURL: dir) { [weak self] progress in
                    DispatchQueue.main.async { self?.begin(progress) }
                    return { DispatchQueue.main.async { self?.end(progress) } }
                }
            }
        }
    }

    func begin(_ p: Progress) {
        guard !active.contains(where: { $0.progress === p }) else { return }
        active.append(Item(progress: p))
        // Progress fires far too often to publish every change; redraw a few times a second instead.
        refresh = refresh ?? Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.objectWillChange.send() }
    }

    private func end(_ p: Progress) {
        let temp = p.fileURL
        active.removeAll { $0.progress === p }
        if active.isEmpty { refresh?.invalidate(); refresh = nil }
        // The browser renames the temp file a moment after it unpublishes; cancelled downloads leave nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard let url = Self.finalURL(for: temp), FileManager.default.fileExists(atPath: url.path) else { return }
            TrayStore.shared.add(url)
            NotchState.shared.showHUD(HUD(kind: .downloaded, level: 1))
        }
    }

    /// "x.zip.crdownload" (Chrome), "x.zip.download" (Safari), "x.zip.part" (Firefox) -> "x.zip".
    static func finalURL(for url: URL?) -> URL? {
        guard let url else { return nil }
        return ["crdownload", "download", "part"].contains(url.pathExtension) ? url.deletingPathExtension() : url
    }
}
