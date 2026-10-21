import AppKit
import SwiftUI

struct HUD: Equatable {
    enum Kind { case volume, muted, brightness, screenshot, downloaded }
    var kind: Kind
    var level: Float
}

final class NotchState: ObservableObject {
    static let shared = NotchState()
    enum Tab: String, CaseIterable { case music, tray, notes, clipboard }

    @Published var expanded = false
    @Published var tab: Tab = .music
    @Published var hud: HUD?
    @Published var notchSize = CGSize(width: 200, height: 32)
    var menuOpen = false // context menu / share picker showing: don't collapse under it
    private var hudHide: DispatchWorkItem?

    static let expandedSize = CGSize(width: 580, height: 214) // below the notch

    /// Outward curve where the shape meets the menu bar, and the rounded bottom corners.
    var topRadius: CGFloat { expanded ? 14 : 6 }
    var bottomRadius: CGFloat { expanded ? 30 : 12 }

    /// Body size, without the top flares.
    var bodySize: CGSize {
        if expanded { return CGSize(width: Self.expandedSize.width, height: notchSize.height + Self.expandedSize.height) }
        if hud != nil { return CGSize(width: notchSize.width + 200, height: notchSize.height) }
        if !Downloads.shared.active.isEmpty { return CGSize(width: notchSize.width + 130, height: notchSize.height) }
        if MediaModel.shared.playing { return CGSize(width: notchSize.width + 84, height: notchSize.height) }
        return notchSize
    }

    var shapeSize: CGSize { CGSize(width: bodySize.width + topRadius * 2, height: bodySize.height) }

    func showHUD(_ hud: HUD) {
        self.hud = hud
        hudHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hud = nil }
        hudHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Lets clicks land on buttons even though the panel is never the active app.
final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class NotchController {
    static let shared = NotchController()
    private let state = NotchState.shared
    private let panelSize = CGSize(width: 720, height: 320) // room for the shadow
    private(set) var panel: NotchPanel!
    /// Set in layout(). nil for a moment when no display is connected (lid closed, monitor unplugged).
    private var screen: NSScreen?

    func start() {
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = FirstMouseHostingView(rootView: NotchRoot())
        layout()
        panel.orderFrontRegardless()
        NotchSpace.attach(panel)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.layout() }
        // Polling the pointer is simpler and more reliable than event monitors:
        // it keeps working during file drags owned by other apps.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.02 // lets macOS batch these wakeups with others
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in self?.state.menuOpen = true }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in self?.state.menuOpen = false }
        // A click anywhere else ends note editing and closes the notch.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, state.expanded, rect(state.shapeSize)?.contains(NSEvent.mouseLocation) == false else { return }
            panel.makeFirstResponder(nil)
            state.expanded = false
        }
    }

    private func layout() {
        screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        guard let s = screen else { return }
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            state.notchSize = CGSize(width: s.frame.width - l.width - r.width, height: s.safeAreaInsets.top)
        } else {
            state.notchSize = CGSize(width: 200, height: 28) // no notch: draw a pill at the top
        }
        panel.setFrame(NSRect(x: s.frame.midX - panelSize.width / 2, y: s.frame.maxY - panelSize.height,
                              width: panelSize.width, height: panelSize.height), display: true)
    }

    private func rect(_ size: CGSize) -> NSRect? {
        guard let f = screen?.frame else { return nil }
        return NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height)
    }

    private func tick() {
        guard let shape = rect(state.shapeSize) else { return }
        let mouse = NSEvent.mouseLocation
        if !state.expanded {
            if shape.insetBy(dx: -4, dy: -4).contains(mouse) {
                if Self.isDraggingFiles { state.tab = .tray }
                state.expanded = true
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        } else if !state.menuOpen, !isEditingNote, !shape.insetBy(dx: -12, dy: -12).contains(mouse) {
            state.expanded = false
        }
        // Each assignment is a window-server call; only make it when the value flips.
        let ignore = !(rect(state.shapeSize) ?? shape).contains(mouse)
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
    }

    /// While typing a note the notch stays open even if the pointer drifts away.
    private var isEditingNote: Bool { state.tab == .notes && panel.isKeyWindow && panel.firstResponder is NSTextView }

    static var isDraggingFiles: Bool {
        NSEvent.pressedMouseButtons & 1 != 0 && NSPasteboard(name: .drag).types?.contains(.fileURL) == true
    }
}

/// Puts a window on its own always-on-top Space via private SkyLight calls (as Droppy does),
/// so the notch doesn't slide or ghost when swiping between Spaces or into full-screen apps.
enum NotchSpace {
    private typealias ConnFn = @convention(c) () -> Int32
    private typealias CreateFn = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias LevelFn = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowFn = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddFn = @convention(c) (Int32, CFArray, CFArray) -> Int32
    private static let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static func fn<T>(_ name: String, _: T.Type) -> T? { dlsym(lib, name).map { unsafeBitCast($0, to: T.self) } }

    private static let space: UInt64? = {
        guard let conn = fn("SLSMainConnectionID", ConnFn.self), let create = fn("SLSSpaceCreate", CreateFn.self),
              let level = fn("SLSSpaceSetAbsoluteLevel", LevelFn.self), let show = fn("SLSShowSpaces", ShowFn.self) else { return nil }
        let cid = conn()
        let id = create(cid, 1, nil)
        _ = level(cid, id, Int32.max)
        _ = show(cid, [id] as CFArray)
        return id
    }()

    /// Falls back to the normal all-Spaces window if the private API is missing.
    static func attach(_ window: NSWindow) {
        guard let space, let conn = fn("SLSMainConnectionID", ConnFn.self), let add = fn("SLSAddWindowsToSpaces", AddFn.self) else {
            NSLog("Visor: SkyLight space API unavailable, notch may move with Space swipes")
            return
        }
        _ = add(conn(), [window.windowNumber] as CFArray, [space] as CFArray)
    }
}
