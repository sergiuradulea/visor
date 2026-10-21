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
}
