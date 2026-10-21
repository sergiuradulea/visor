import AppKit
import QuickLookThumbnailing
import ServiceManagement
import SwiftUI

/// The notch silhouette: top corners curve outward into the menu bar, bottom corners round in.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY + top), control: CGPoint(x: r.minX + top, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: r.minX + top + bottom, y: r.maxY), control: CGPoint(x: r.minX + top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top - bottom, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.maxY - bottom), control: CGPoint(x: r.maxX - top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - top, y: r.minY))
        p.closeSubpath()
        return p
    }
}

private struct Blur: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

extension AnyTransition {
    /// Content grows out of the notch, sharpening as it lands.
    static var notchContent: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.86, anchor: .top)
                .combined(with: .opacity)
                .combined(with: .modifier(active: Blur(radius: 8), identity: Blur(radius: 0)))
                .animation(.spring(duration: 0.42, bounce: 0.2).delay(0.04)),
            removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .top)).animation(.easeIn(duration: 0.12)))
    }
    static var ear: AnyTransition { .opacity.combined(with: .scale(scale: 0.6)).animation(.spring(duration: 0.3)) }
}

struct NotchRoot: View {
    @ObservedObject var state = NotchState.shared
    @ObservedObject var media = MediaModel.shared
    @ObservedObject var downloads = Downloads.shared
    @Namespace private var ns

    var body: some View {
        let size = state.shapeSize
        let shape = NotchShape(top: state.topRadius, bottom: state.bottomRadius)
        ZStack(alignment: .top) {
            shape.fill(.black)
                .shadow(color: .black.opacity(state.expanded ? 0.55 : 0), radius: 18, y: 8)
            Group {
                if state.expanded {
                    ExpandedView(ns: ns)
                        .padding(.top, state.notchSize.height)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 16)
                        .transition(.notchContent)
                } else if let hud = state.hud {
                    Ears(notch: state.notchSize) {
                        Image(systemName: hud.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                    } right: {
                        if hud.kind == .screenshot || hud.kind == .downloaded {
                            Text(hud.kind == .screenshot ? "In tray" : "Downloaded").font(.system(size: 12, weight: .semibold))
                        } else {
                            LevelBar(level: hud.level, tint: .white).frame(width: 78, height: 5)
                        }
                    }
                    .transition(.ear)
                } else if !downloads.active.isEmpty {
                    Ears(notch: state.notchSize) {
                        ProgressRing(fraction: downloads.overall).frame(width: 18, height: 18)
                    } right: {
                        Text(downloads.active.count > 1 ? "\(downloads.active.count) files" : "\(Int(downloads.overall * 100))%")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .contentTransition(.numericText())
                    }
                    .transition(.ear)
                } else if media.playing {
                    Ears(notch: state.notchSize) {
                        Artwork(image: media.artwork, size: 22, radius: 6)
                            .matchedGeometryEffect(id: "art", in: ns)
                    } right: {
                        PlayingBars(tint: media.accent).frame(width: 20, height: 14)
                    }
                    .transition(.ear)
                }
            }
            .padding(.horizontal, state.topRadius)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .contentShape(shape)
        .onDrop(of: [.fileURL], isTargeted: nil) { TrayStore.shared.handleDrop($0) }
        .contextMenu { AppMenu() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(state.expanded ? .spring(duration: 0.45, bounce: 0.3) : .spring(duration: 0.32, bounce: 0.05), value: size)
        .animation(.spring(duration: 0.3), value: state.hud)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}

extension HUD {
    var symbol: String {
        switch kind {
        case .screenshot: "camera.viewfinder"
        case .downloaded: "arrow.down.circle.fill"
        case .muted: "speaker.slash.fill"
        case .brightness: level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .volume: level < 0.33 ? "speaker.wave.1.fill" : level < 0.66 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        }
    }
}

/// Content left and right of the physical notch.
struct Ears<L: View, R: View>: View {
    let notch: CGSize
    @ViewBuilder var left: L
    @ViewBuilder var right: R
    var body: some View {
        HStack(spacing: 0) {
            left.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 10)
            Color.clear.frame(width: notch.width)
            right.frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 10)
        }
        .frame(height: notch.height)
    }
}

struct LevelBar: View {
    let level: Float
    var tint: Color = .white
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                Capsule().fill(tint)
                    .frame(width: max(g.size.height, g.size.width * CGFloat(level)))
                    .shadow(color: tint.opacity(0.6), radius: 4)
                    .opacity(level > 0 ? 1 : 0)
            }
        }
        .animation(.spring(duration: 0.25), value: level)
    }
}

struct PlayingBars: View {
    var tint: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { t in
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let x = t.date.timeIntervalSinceReferenceDate
                    let h = 0.35 + 0.65 * abs(sin(x * (3.1 + Double(i) * 0.9) + Double(i) * 1.3))
                    Capsule().fill(tint).frame(width: 3, height: 14 * h)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

struct Artwork: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            else {
                ZStack {
                    LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: size * 0.38, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Round hover highlight + press squish, used for every control in the notch.
struct NotchButton: ButtonStyle {
    var size: CGFloat = 32
    func makeBody(configuration: Configuration) -> some View { Inner(configuration: configuration, size: size) }
    private struct Inner: View {
        let configuration: Configuration
        let size: CGFloat
        @State private var hover = false
        var body: some View {
            configuration.label
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.2 : hover ? 0.1 : 0)))
                .scaleEffect(configuration.isPressed ? 0.86 : 1)
                .animation(.spring(duration: 0.2), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hover)
                .contentShape(Circle())
                .onHover { hover = $0 }
        }
    }
}

struct ExpandedView: View {
    let ns: Namespace.ID
    @ObservedObject var state = NotchState.shared

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                switch state.tab {
                case .music: MusicView(ns: ns).transition(.tab)
                case .tray: TrayView().transition(.tab)
                case .notes: NotesView().transition(.tab)
                case .clipboard: ClipboardView().transition(.tab)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 10)
            TabBar()
        }
    }
}

/// Bottom tab bar: icons only, the selected one grows into a labelled pill.
private struct TabBar: View {
    @ObservedObject var state = NotchState.shared
    @ObservedObject var media = MediaModel.shared
    @Namespace private var tabs
    private let icons: [NotchState.Tab: String] = [.music: "music.note", .tray: "tray.full", .notes: "square.and.pencil", .clipboard: "doc.on.clipboard"]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(NotchState.Tab.allCases, id: \.self) { tab in
                let selected = state.tab == tab
                Button { withAnimation(.spring(duration: 0.35, bounce: 0.25)) { state.tab = tab } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: icons[tab]!).font(.system(size: 11.5, weight: .semibold))
                        if selected { Text(tab.rawValue.capitalized).font(.system(size: 11.5, weight: .semibold)).fixedSize() }
                    }
                    .foregroundStyle(selected ? .black : .white.opacity(0.5))
                    .padding(.horizontal, selected ? 11 : 9)
                    .frame(height: 24)
                    .background { if selected { Capsule().fill(.white).matchedGeometryEffect(id: "pill", in: tabs) } }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(.white.opacity(0.08)))
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) {
            // Mini now-playing, so music is one click away from any tab.
            if media.playing && state.tab != .music {
                Button { withAnimation(.spring(duration: 0.35, bounce: 0.25)) { state.tab = .music } } label: {
                    HStack(spacing: 6) {
                        PlayingBars(tint: media.accent).frame(width: 14, height: 10)
                        Text(media.title.isEmpty ? media.appName : media.title)
                            .font(.system(size: 11, weight: .medium)).lineLimit(1).frame(maxWidth: 110, alignment: .leading)
                    }
                    .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
    }
}

private extension AnyTransition {
    static var tab: AnyTransition { .opacity.combined(with: .offset(y: 6)).animation(.spring(duration: 0.3)) }
}

struct MusicView: View {
    let ns: Namespace.ID
    @ObservedObject var media = MediaModel.shared

    var body: some View {
        if media.bundleId == nil {
            VStack(spacing: 8) {
                Image(systemName: "music.note").font(.system(size: 26, weight: .light))
                Text("Nothing playing").font(.callout)
            }
            .foregroundStyle(.white.opacity(0.4))
        } else {
            HStack(spacing: 18) {
                Artwork(image: media.artwork, size: 112, radius: 16)
                    .matchedGeometryEffect(id: "art", in: ns)
                    .shadow(color: media.accent.opacity(0.45), radius: 18, y: 4)
                    .scaleEffect(media.playing ? 1 : 0.92)
                    .animation(.spring(duration: 0.4, bounce: 0.3), value: media.playing)
                    .onTapGesture { media.openPlayer() }
                    .help("Open \(media.appName)")
                VStack(alignment: .leading, spacing: 3) {
                    Text(media.title.isEmpty ? media.appName : media.title)
                        .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(media.artist.isEmpty ? media.album : media.artist)
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    Spacer(minLength: 6)
                    if media.duration > 0 { Progress().padding(.bottom, 4) }
                    HStack(spacing: 18) {
                        control("backward.fill", .previous, size: 15)
                        control(media.playing ? "pause.fill" : "play.fill", .toggle, size: 22)
                            .contentTransition(.symbolEffect(.replace))
                        control("forward.fill", .next, size: 15)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func control(_ symbol: String, _ c: MediaModel.Command, size: CGFloat) -> some View {
        Button { media.send(c) } label: { Image(systemName: symbol).font(.system(size: size)) }
            .buttonStyle(NotchButton(size: size * 2.1))
    }
}

private struct Progress: View {
    @ObservedObject var media = MediaModel.shared
    @State private var hover = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { t in
            let pos = media.position(at: t.date)
            VStack(spacing: 4) {
                GeometryReader { g in
                    LevelBar(level: Float(pos / max(media.duration, 1)), tint: media.accent)
                        .frame(height: hover ? 7 : 4)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { p in media.seek(to: Double(p.x / g.size.width) * media.duration) }
                }
                .frame(height: 10)
                .onHover { hover = $0 }
                .animation(.spring(duration: 0.2), value: hover)
                HStack { Text(fmt(pos)); Spacer(); Text("-" + fmt(media.duration - pos)) }
                    .font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.45))
            }
        }
    }
    private func fmt(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}

struct TrayView: View {
    @ObservedObject var tray = TrayStore.shared
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 8) {
        DownloadRows()
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(targeted ? 0.6 : tray.items.isEmpty ? 0.15 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(targeted ? 0.08 : 0)))
            if tray.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc.fill").font(.system(size: 24))
                        .symbolEffect(.bounce, value: targeted)
                    Text(targeted ? "Let go to keep it here" : "Drop files here").font(.callout)
                }
                .foregroundStyle(.white.opacity(targeted ? 0.9 : 0.4))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(tray.items, id: \.self) { TrayItem(url: $0).transition(.scale.combined(with: .opacity)) }
                        }
                        .padding(.horizontal, 4).padding(.top, 6)
                    }
                    HStack {
                        Text("\(tray.items.count) item\(tray.items.count == 1 ? "" : "s") · drag out, or right-click for more")
                        Spacer()
                        Button("AirDrop all") { TrayActions.airDrop(tray.items) }.buttonStyle(.plain)
                        Text("·")
                        Button("Clear") { withAnimation(.spring(duration: 0.3)) { tray.items.removeAll() } }.buttonStyle(.plain)
                    }
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 6)
                }
            }
        }
        }
        .animation(.spring(duration: 0.3), value: targeted)
        .animation(.spring(duration: 0.35, bounce: 0.25), value: tray.items)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { tray.handleDrop($0) }
    }
}

struct TrayItem: View {
    let url: URL
    @State private var hover = false
    @State private var thumb: NSImage?

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: thumb ?? NSWorkspace.shared.icon(forFile: url.path))
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            Text(url.lastPathComponent)
                .font(.system(size: 10, weight: .medium)).lineLimit(1).truncationMode(.middle)
                .frame(width: 76)
                .foregroundStyle(.white.opacity(hover ? 1 : 0.7))
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hover ? 0.1 : 0)))
        .overlay(alignment: .topTrailing) {
            if hover {
                Button { withAnimation(.spring(duration: 0.3)) { TrayStore.shared.items.removeAll { $0 == url } } } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.white, .gray.opacity(0.8))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .scaleEffect(hover ? 1.04 : 1)
        .animation(.spring(duration: 0.2), value: hover)
        .onHover { hover = $0 }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu { TrayActions(urls: [url]) }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .help(url.path)
        .task {
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 112, height: 112),
                                                    scale: 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { thumb = rep.nsImage }
        }
    }
}

struct BasketView: View {
    let close: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Basket", systemImage: "basket.fill").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(NotchButton(size: 22))
            }
            TrayView()
        }
        .padding(14)
        .foregroundStyle(.white)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
    }
}

struct ClipboardView: View {
    @ObservedObject var store = ClipboardStore.shared

    var body: some View {
        if store.clips.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 24, weight: .light))
                Text("Copy something and it shows up here").font(.callout)
            }
            .foregroundStyle(.white.opacity(0.4))
        } else {
            VStack(spacing: 6) {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 3) { ForEach(store.clips) { ClipRow(clip: $0) } }
                }
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                HStack {
                    Text("Click to copy").foregroundStyle(.white.opacity(0.3))
                    Spacer()
                    Button("Clear history") { withAnimation { store.clear() } }.buttonStyle(.plain)
                }
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }
            .animation(.spring(duration: 0.3), value: store.clips)
        }
    }
}

private struct ClipRow: View {
    let clip: Clip
    @State private var hover = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: copied ? "checkmark" : clip.text != nil ? "text.alignleft" : "photo")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(copied ? .green : .white.opacity(0.4))
                .frame(width: 16)
                .contentTransition(.symbolEffect(.replace))
            if let text = clip.text {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " "))
                    .lineLimit(1).font(.system(size: 12.5))
            } else if let png = clip.png, let img = NSImage(data: png) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            Spacer(minLength: 8)
            if hover {
                Button { withAnimation { ClipboardStore.shared.delete(clip) } } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(NotchButton(size: 22))
            } else {
                Text(clip.date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(hover ? 0.11 : 0.04)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .onTapGesture {
            ClipboardStore.shared.copy(clip)
            withAnimation(.spring(duration: 0.25)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { NotchState.shared.expanded = false }
        }
    }
}

struct AppMenu: View {
    var body: some View {
        Button(SMAppService.mainApp.status == .enabled ? "Don't Open at Login" : "Open at Login") {
            if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
            else { try? SMAppService.mainApp.register() }
        }
        Divider()
        Button("Quit Visor") { NSApp.terminate(nil) }
    }
}

struct ProgressRing: View {
    let fraction: Double
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.2), lineWidth: 2.5)
            Circle().trim(from: 0, to: max(fraction, 0.03))
                .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.25), value: fraction)
        }
    }
}

/// Live downloads, shown above the parked files in the Tray tab.
struct DownloadRows: View {
    @ObservedObject var downloads = Downloads.shared
    var body: some View {
        if !downloads.active.isEmpty {
            VStack(spacing: 6) {
                ForEach(downloads.active.prefix(2)) { d in
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle").font(.system(size: 12, weight: .semibold))
                        Text(d.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        LevelBar(level: Float(d.fraction)).frame(height: 4)
                        Text("\(Int(d.fraction * 100))%").font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5)).frame(width: 30, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
        }
    }
}

/// Right-click menu for tray files.
struct TrayActions: View {
    let urls: [URL]

    var body: some View {
        Button("Open") { urls.forEach { NSWorkspace.shared.open($0) } }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        Divider()
        Button("AirDrop") { Self.airDrop(urls) }
        Button("Share…") { Self.share(urls) }
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        }
        Divider()
        Button("Remove from Tray") { withAnimation(.spring(duration: 0.3)) { TrayStore.shared.items.removeAll { urls.contains($0) } } }
    }

    static func airDrop(_ urls: [URL]) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
    }

    static func share(_ urls: [URL]) {
        guard let view = NotchController.shared.panel.contentView else { return }
        let p = view.convert(NotchController.shared.panel.mouseLocationOutsideOfEventStream, from: nil)
        NSSharingServicePicker(items: urls).show(relativeTo: NSRect(origin: p, size: CGSize(width: 1, height: 1)), of: view, preferredEdge: .minY)
    }
}

/// A single scratchpad that saves as you type. The notch stays open while you're typing.
struct NotesView: View {
    @AppStorage("notes") private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .focused($focused)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(focused ? 0.09 : 0.05)))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Jot something down…").font(.system(size: 13)).foregroundStyle(.white.opacity(0.3))
                            .padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: focused)
            HStack(spacing: 10) {
                Text(text.isEmpty ? "Saved automatically" : "\(text.split(whereSeparator: \.isWhitespace).count) words")
                Spacer()
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                    .buttonStyle(.plain).disabled(text.isEmpty)
                Button("Clear") { text = "" }.buttonStyle(.plain).disabled(text.isEmpty)
            }
            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
        }
        .onAppear { focused = true }
    }
}
