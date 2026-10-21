// Tiny MediaRemote bridge. macOS 15.4+ only answers MediaRemote clients whose
// bundle id starts with "com.apple.", so this runs as a separate helper app with
// such an id (same trick Droppy's DroppyMediaHelper uses). The main app talks to
// it over stdin/stdout:
//   VisorMedia stream        -> one JSON object per line on every change
//   VisorMedia send <cmd>    -> 0 play, 1 pause, 2 toggle, 4 next, 5 previous
//   VisorMedia seek <secs>
import AppKit

typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
typealias GetPlayingFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
typealias GetPIDFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
typealias SendFn = @convention(c) (UInt32, CFDictionary?) -> Bool
typealias SeekFn = @convention(c) (Double) -> Void

let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
func sym<T>(_ name: String, _: T.Type) -> T {
    guard let p = dlsym(handle, name) else { fputs("missing \(name)\n", stderr); exit(2) }
    return unsafeBitCast(p, to: T.self)
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "send":
    let cmd = UInt32(args.dropFirst().first ?? "") ?? 2
    _ = sym("MRMediaRemoteSendCommand", SendFn.self)(cmd, nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3)) // let the XPC message go out
    exit(0)
case "seek":
    sym("MRMediaRemoteSetElapsedTime", SeekFn.self)(Double(args.dropFirst().first ?? "") ?? 0)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    exit(0)
case "stream", "get":
    break
default:
    fputs("usage: VisorMedia stream|get|send <cmd>|seek <secs>\n", stderr)
    exit(1)
}

let getInfo = sym("MRMediaRemoteGetNowPlayingInfo", GetInfoFn.self)
let getPlaying = sym("MRMediaRemoteGetNowPlayingApplicationIsPlaying", GetPlayingFn.self)
let getPID = sym("MRMediaRemoteGetNowPlayingApplicationPID", GetPIDFn.self)
let queue = DispatchQueue.main
var lastArtworkHash = 0
let once = args.first == "get"

func emit() {
    getInfo(queue) { cfInfo in
        getPlaying(queue) { playing in
            getPID(queue) { pid in
                let info = (cfInfo as? [String: Any]) ?? [:]
                var out: [String: Any] = ["playing": playing]
                let keys = ["title": "Title", "artist": "Artist", "album": "Album",
                            "duration": "Duration", "elapsed": "ElapsedTime", "rate": "PlaybackRate"]
                for (k, v) in keys { out[k] = info["kMRMediaRemoteNowPlayingInfo\(v)"] }
                if let ts = info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date {
                    out["timestamp"] = ts.timeIntervalSince1970
                }
                out["bundleId"] = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                // Artwork is big; only resend it when it changes.
                if let art = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data, art.hashValue != lastArtworkHash {
                    lastArtworkHash = art.hashValue
                    out["artwork"] = art.base64EncodedString()
                } else if info["kMRMediaRemoteNowPlayingInfoArtworkData"] == nil {
                    lastArtworkHash = 0
                    out["artwork"] = NSNull()
                }
                if let data = try? JSONSerialization.data(withJSONObject: out) {
                    FileHandle.standardOutput.write(data + Data("\n".utf8))
                }
                if once { exit(0) }
            }
        }
    }
}

sym("MRMediaRemoteRegisterForNowPlayingNotifications", RegisterFn.self)(queue)
for name in ["kMRMediaRemoteNowPlayingInfoDidChangeNotification",
             "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
             "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"] {
    NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in emit() }
}
// Exit when the parent app goes away (stdin closes).
if !once { FileHandle.standardInput.readabilityHandler = { h in if h.availableData.isEmpty { exit(0) } } }
emit()
RunLoop.main.run()
