import AppKit
import AudioToolbox
import CoreAudio

/// Catches the volume/brightness keys with a session event tap, applies the change
/// itself and swallows the key so the system HUD stays hidden and ours shows instead.
/// Needs Accessibility permission. Keys we can't handle (e.g. HDMI audio with no
/// software volume) are passed through to macOS.
///
/// An active tap sits in the system's input path, so two rules keep it from ever stalling
/// the Mac: it runs on its own thread (a busy UI can't delay key events), and it is torn
/// down the moment Accessibility is revoked instead of being re-enabled in a loop.
final class MediaKeys {
    static let shared = MediaKeys()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tapLoop: CFRunLoop?
    private let lock = NSLock() // tap/source are touched from main and the tap thread

    private enum Key: Int { case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7 }

    func start() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        let thread = Thread { [weak self] in
            self?.tapLoop = CFRunLoopGetCurrent()
            // Keeps the run loop alive while there is no tap yet.
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFRunLoopSourceCreate(nil, 0, &Self.dummyContext), .commonModes)
            CFRunLoopRun()
        }
        thread.name = "Visor.MediaKeys"
        thread.qualityOfService = .userInteractive
        thread.start()
        // Watchdog: create the tap once trusted, remove it as soon as trust is revoked.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkTrust() }
    }

    private static var dummyContext = CFRunLoopSourceContext()

    private func checkTrust() {
        let trusted = AXIsProcessTrusted()
        lock.lock(); let hasTap = tap != nil; lock.unlock()
        if trusted && !hasTap { createTap() }
        if !trusted && hasTap { removeTap() }
    }

    private func createTap() {
        guard let loop = tapLoop else { return }
        let mask = CGEventMask(1) << 14 // NX_SYSDEFINED only: never ordinary keystrokes
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: tapCallback, userInfo: nil) else { return }
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        lock.lock(); tap = t; source = src; lock.unlock()
        CFRunLoopAddSource(loop, src, .commonModes)
        CFRunLoopWakeUp(loop)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    fileprivate func removeTap() {
        lock.lock()
        let t = tap, src = source
        tap = nil; source = nil
        lock.unlock()
        if let t { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let src, let loop = tapLoop { CFRunLoopRemoveSource(loop, src, .commonModes) }
        NSLog("Visor: media key tap removed (Accessibility not granted)")
    }

    /// macOS disabled the tap (it was slow, or the user/permissions intervened).
    /// Only switch it back on if we're still trusted; otherwise get out of the input path.
    fileprivate func tapWasDisabled() {
        guard AXIsProcessTrusted() else { return removeTap() }
        lock.lock(); let t = tap; lock.unlock()
        if let t { CGEvent.tapEnable(tap: t, enable: true) }
    }

    /// Returns true when the event was handled and should be swallowed. Runs on the tap thread:
    /// keep it quick, and hop to main for UI.
    fileprivate func handle(_ event: CGEvent) -> Bool {
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8,
              let key = Key(rawValue: (ns.data1 & 0xFFFF_0000) >> 16) else { return false }
        let isDown = (ns.data1 & 0xFF00) >> 8 == 0xA
        let fine = ns.modifierFlags.contains([.shift, .option])
        let step: Float = fine ? 1 / 64 : 1 / 16

        let hud: HUD
        switch key {
        case .soundUp, .soundDown, .mute:
            guard SystemVolume.canSet else { return false }
            guard isDown else { return true }
            if key == .mute {
                SystemVolume.muted.toggle()
            } else {
                SystemVolume.muted = false
                SystemVolume.volume += key == .soundUp ? step : -step
            }
            let v = SystemVolume.volume
            hud = HUD(kind: SystemVolume.muted || v == 0 ? .muted : .volume, level: SystemVolume.muted ? 0 : v)
        case .brightnessUp, .brightnessDown:
            guard let b = Brightness.value else { return false }
            guard isDown else { return true }
            let nb = min(max(b + (key == .brightnessUp ? step : -step), 0), 1)
            Brightness.value = nb
            hud = HUD(kind: .brightness, level: nb)
        }
        DispatchQueue.main.async { NotchState.shared.showHUD(hud) }
        return true
    }
}

private let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MediaKeys.shared.tapWasDisabled()
        return Unmanaged.passUnretained(event)
    }
    return MediaKeys.shared.handle(event) ? nil : Unmanaged.passUnretained(event)
}

enum SystemVolume {
    private static var device: AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
        return id
    }

    private static func address(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    static var canSet: Bool {
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &a, &settable) == noErr && settable.boolValue
    }

    static var volume: Float {
        get {
            var v = Float32(0); var size = UInt32(4)
            var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v)
            return v
        }
        set {
            var v = Float32(min(max(newValue, 0), 1))
            var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            AudioObjectSetPropertyData(device, &a, 0, nil, 4, &v)
        }
    }

    static var muted: Bool {
        get {
            var m = UInt32(0); var size = UInt32(4)
            var a = address(kAudioDevicePropertyMute)
            AudioObjectGetPropertyData(device, &a, 0, nil, &size, &m)
            return m != 0
        }
        set {
            var m = UInt32(newValue ? 1 : 0)
            var a = address(kAudioDevicePropertyMute)
            AudioObjectSetPropertyData(device, &a, 0, nil, 4, &m)
        }
    }
}

/// Built-in display brightness through the private DisplayServices framework (as Droppy does).
enum Brightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getFn = dlsym(lib, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn = dlsym(lib, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }

    private static var display: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n = UInt32(0)
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }

    /// nil when brightness can't be read (e.g. lid closed, external display only).
    static var value: Float? {
        get {
            var b: Float = 0
            guard let getFn, getFn(display, &b) == 0 else { return nil }
            return b
        }
        set { if let newValue { _ = setFn?(display, newValue) } }
    }
}
