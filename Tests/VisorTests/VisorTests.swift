import AppKit
import XCTest
@testable import Visor

final class VisorTests: XCTestCase {
    /// Security check: only files directly in the screenshot folder may be auto-added to the tray.
    func testScreenshotMustBeDirectlyInFolder() {
        let folder = URL(fileURLWithPath: "/Users/me/Pictures/Screenshots", isDirectory: true)
        XCTAssertTrue(TrayStore.isDirectlyInside("/Users/me/Pictures/Screenshots/shot.png", folder))
        XCTAssertFalse(TrayStore.isDirectlyInside("/Users/me/Pictures/Screenshots/sub/shot.png", folder))
        XCTAssertFalse(TrayStore.isDirectlyInside("/Users/me/Pictures/Screenshots-evil/shot.png", folder))
        XCTAssertFalse(TrayStore.isDirectlyInside("/Users/me/.ssh/id_ed25519", folder))
        XCTAssertTrue(TrayStore.isDirectlyInside("/Users/me/Pictures/Screenshots/../Screenshots/shot.png", folder))
    }

    func testDownloadTempNamesMapToFinalFile() {
        let dl = URL(fileURLWithPath: "/Users/me/Downloads")
        XCTAssertEqual(Downloads.finalURL(for: dl.appendingPathComponent("a.zip.crdownload"))?.lastPathComponent, "a.zip") // Chrome
        XCTAssertEqual(Downloads.finalURL(for: dl.appendingPathComponent("a.zip.download"))?.lastPathComponent, "a.zip")   // Safari
        XCTAssertEqual(Downloads.finalURL(for: dl.appendingPathComponent("a.zip.part"))?.lastPathComponent, "a.zip")       // Firefox
        XCTAssertEqual(Downloads.finalURL(for: dl.appendingPathComponent("a.zip"))?.lastPathComponent, "a.zip")
        XCTAssertNil(Downloads.finalURL(for: nil))
    }

    /// Image clips keep the full PNG on disk and only a small thumbnail in the index.
    func testClipboardImageThumbnailIsSmall() throws {
        let image = NSImage(size: NSSize(width: 1200, height: 800), flipped: false) { r in NSColor.orange.setFill(); r.fill(); return true }
        let encoded = try XCTUnwrap(ClipboardStore.encode(try XCTUnwrap(image.tiffRepresentation)))
        let thumb = try XCTUnwrap(NSBitmapImageRep(data: encoded.thumb))
        let full = try XCTUnwrap(NSBitmapImageRep(data: encoded.png))
        XCTAssertLessThanOrEqual(max(thumb.pixelsWide, thumb.pixelsHigh), 160)
        XCTAssertEqual(full.pixelsWide, 1200)
    }

    /// Same shape as the files Claude Code writes to ~/.claude/sessions.
    func testClaudeSessionFile() throws {
        let json = #"{"pid":1330,"sessionId":"abc","cwd":"/Users/me/code/visor","startedAt":1792586186121,"name":"Notch app","status":"busy"}"#
        let s = try XCTUnwrap(ClaudeAgents.parse(Data(json.utf8), isAlive: { _ in true }))
        XCTAssertEqual(s.name, "Notch app")
        XCTAssertEqual(s.project, "visor")
        XCTAssertTrue(s.busy)
        XCTAssertNil(ClaudeAgents.parse(Data(json.utf8), isAlive: { _ in false }), "dead sessions are hidden")
        let noName = #"{"pid":1,"cwd":"/x/api","status":"idle"}"#
        XCTAssertEqual(ClaudeAgents.parse(Data(noName.utf8), isAlive: { _ in true })?.name, "api")
    }

    func testClaudeLimitsParsing() throws {
        let iso = #"{"five_hour":{"utilization":42.4,"resets_at":"2026-10-21T18:00:00.123456+00:00"},"seven_day":{"utilization":130,"resets_at":1792800000}}"#
        let (five, week) = try XCTUnwrap(ClaudeLimits.parse(Data(iso.utf8)))
        XCTAssertEqual(five?.percent, 42.4)
        XCTAssertEqual(five?.resetsAt, ISO8601DateFormatter().date(from: "2026-10-21T18:00:00Z"))
        XCTAssertEqual(week?.percent, 100, "clamped")
        XCTAssertEqual(week?.resetsAt, Date(timeIntervalSince1970: 1792800000))
        XCTAssertNil(ClaudeLimits.parse(Data("not json".utf8)))
    }

    func testBluetoothBatteryParsing() {
        let json = #"{"SPBluetoothDataType":[{"device_connected":[{"Sergiu's AirPods Pro":{"device_batteryLevelCase":"40%","device_batteryLevelLeft":"80%","device_batteryLevelRight":"75%"}},{"Magic Keyboard":{"device_batteryLevelMain":"12%"}},{"Speaker":{"device_minorType":"Speaker"}}]}]}"#
        let devices = SystemStats.parseBluetooth(Data(json.utf8))
        XCTAssertEqual(devices.map(\.name), ["Magic Keyboard", "Sergiu's AirPods Pro"], "devices without a battery are skipped")
        XCTAssertEqual(devices[1].levels.map(\.part), ["Left", "Right", "Case"])
        XCTAssertEqual(devices[0].levels, [.init(part: "", percent: 12)])
    }
}
