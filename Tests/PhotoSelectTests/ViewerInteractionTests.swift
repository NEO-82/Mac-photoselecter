import AppKit
import XCTest
@testable import PhotoSelect

final class ViewerInteractionTests: XCTestCase {
    @MainActor
    private func makeCanvas() -> PhotoCanvas {
        _ = NSApplication.shared
        return PhotoCanvas(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    }

    // These events exercise our AppKit handlers without posting system-wide input
    // or requiring Accessibility permissions. Physical event routing is manual-tested.
    @MainActor
    private func mouse(_ type: NSEvent.EventType, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: 50, y: 50), modifierFlags: [],
                          timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                          clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    @MainActor
    private func waitPastClickInterval() {
        let elapsed = expectation(description: "macOS double-click interval elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval + 0.05) { elapsed.fulfill() }
        wait(for: [elapsed], timeout: NSEvent.doubleClickInterval + 2)
    }

    @MainActor
    private func holdUntilZoomStarts(_ canvas: PhotoCanvas) {
        canvas.mouseDown(with: mouse(.leftMouseDown))
        waitPastClickInterval()
    }

    @MainActor
    private func arrow(_ code: UInt16, repeated: Bool = false) -> NSEvent {
        let character = code == 123 ? "\u{F702}" : code == 124 ? "\u{F703}" : "\u{1B}"
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                               windowNumber: 0, context: nil, characters: character,
                               charactersIgnoringModifiers: character, isARepeat: repeated, keyCode: code)!
    }

    private func image(raw: Bool, full: Bool = true) -> DecodedImage {
        let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8,
                                bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: raw ? 0 : 1, green: 0, blue: raw ? 1 : 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        return DecodedImage(image: context.makeImage()!, sourceSize: CGSize(width: 200, height: 100),
                            fullResolution: full, raw: raw)
    }

    @MainActor
    func testQuickDoubleClickClosesWithoutEverStartingZoom() {
        let canvas = makeCanvas()
        var closes = 0
        var zooms: [Bool] = []
        canvas.close = { closes += 1 }
        canvas.zoomChanged = { zooms.append($0) }
        canvas.mouseDown(with: mouse(.leftMouseDown))
        canvas.mouseUp(with: mouse(.leftMouseUp))
        canvas.mouseDown(with: mouse(.leftMouseDown, clicks: 2))
        XCTAssertEqual(closes, 1)
        waitPastClickInterval()
        XCTAssertEqual(zooms, [])
    }

    @MainActor
    func testShortClickReleaseDoesNotCauseDelayedZoom() {
        let canvas = makeCanvas()
        canvas.decoded = image(raw: false)
        var zooms: [Bool] = []
        canvas.zoomChanged = { zooms.append($0) }
        canvas.mouseDown(with: mouse(.leftMouseDown))
        canvas.mouseUp(with: mouse(.leftMouseUp))
        waitPastClickInterval()
        XCTAssertTrue(zooms.isEmpty)
        XCTAssertFalse(isRenderedZoomed(canvas))
    }

    @MainActor
    func testDraggingCommitsZoomImmediatelyWithoutWaitingForTimer() {
        let canvas = makeCanvas()
        canvas.decoded = image(raw: false)
        canvas.mouseDown(with: mouse(.leftMouseDown))
        XCTAssertFalse(isRenderedZoomed(canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged))
        XCTAssertTrue(isRenderedZoomed(canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp))
        XCTAssertFalse(isRenderedZoomed(canvas))
    }

    @MainActor
    func testEscapeCancelsPendingZoomBeforeClosing() {
        let canvas = makeCanvas()
        var closes = 0
        var zooms: [Bool] = []
        canvas.close = { closes += 1 }
        canvas.zoomChanged = { zooms.append($0) }
        canvas.mouseDown(with: mouse(.leftMouseDown))
        canvas.keyDown(with: arrow(53))
        waitPastClickInterval()
        XCTAssertEqual(closes, 1)
        XCTAssertTrue(zooms.isEmpty)
    }

    @MainActor
    func testDeactivationCancelsPendingZoom() {
        _ = NSApplication.shared
        let viewer = ViewerController()
        defer { viewer.close() }
        var zooms: [Bool] = []
        viewer.canvas.zoomChanged = { zooms.append($0) }
        viewer.canvas.mouseDown(with: mouse(.leftMouseDown))
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        waitPastClickInterval()
        XCTAssertTrue(zooms.isEmpty)
    }

    // The 2:1 image leaves this sample black in Fit; at 1:1 it fills the view.
    // Inspecting rendered pixels verifies the actual canvas state without exposing it.
    @MainActor
    private func isRenderedZoomed(_ canvas: PhotoCanvas) -> Bool {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)!
        canvas.draw(canvas.bounds)
        let color = bitmap.colorAt(x: 50, y: 10)!.usingColorSpace(.deviceRGB)!
        return max(color.redComponent, color.blueComponent) > 0.9
    }

    @MainActor
    private func renderedColor(_ canvas: PhotoCanvas, x: Int, y: Int) throws -> NSColor {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(canvas.bounds.width), pixelsHigh: Int(canvas.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        canvas.draw(canvas.bounds)
        return try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
    }

    @MainActor
    func testZoomUsesActualDecodedPixelsEvenWhenRawMetadataIsLarger() throws {
        let bitmap = image(raw: true).image
        let decoded = DecodedImage(image: bitmap, sourceSize: CGSize(width: 6000, height: 4000),
                                   fullResolution: false, raw: true)
        let retina = PhotoCanvas.imageRect(for: decoded, view: CGSize(width: 400, height: 300),
            cursor: CGPoint(x: 50, y: 50), backingScale: 2, zoomed: true)
        XCTAssertEqual(retina.size, CGSize(width: 100, height: 50))
        let canvas = PhotoCanvas(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        canvas.decoded = decoded
        canvas.mouseDown(with: mouse(.leftMouseDown))
        canvas.mouseDragged(with: mouse(.leftMouseDragged))
        defer { canvas.resetZoom() }
        // At native 1:1 this 200px image occupies only the middle 200pt.
        // Inflating it to the 6000px metadata would incorrectly cover this edge.
        XCTAssertLessThan(try renderedColor(canvas, x: 20, y: 150).blueComponent, 0.1)
        XCTAssertGreaterThan(try renderedColor(canvas, x: 200, y: 150).blueComponent, 0.9)
    }

    @MainActor
    func testLimitedRawFitDoesNotUpscaleAndJpegFitKeepsExistingBehavior() throws {
        let raw = image(raw: true, full: false)
        let view = CGSize(width: 800, height: 600)
        let rawRect = PhotoCanvas.imageRect(for: raw, view: view, cursor: .zero,
                                            backingScale: 2, zoomed: false)
        XCTAssertEqual(rawRect.size, CGSize(width: 100, height: 50))
        let jpegRect = PhotoCanvas.imageRect(for: image(raw: false), view: view, cursor: .zero,
                                             backingScale: 2, zoomed: false)
        XCTAssertEqual(jpegRect.size, CGSize(width: 800, height: 400))
        let canvas = PhotoCanvas(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        canvas.decoded = raw
        XCTAssertLessThan(try renderedColor(canvas, x: 20, y: 150).blueComponent, 0.1)
        XCTAssertGreaterThan(try renderedColor(canvas, x: 200, y: 150).blueComponent, 0.9)
    }

    @MainActor
    func testPressAndReleaseStillSwitchBetweenZoomAndFit() {
        let canvas = makeCanvas()
        canvas.decoded = image(raw: false)
        XCTAssertFalse(isRenderedZoomed(canvas))
        holdUntilZoomStarts(canvas)
        XCTAssertTrue(isRenderedZoomed(canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp))
        XCTAssertFalse(isRenderedZoomed(canvas))
    }

    @MainActor
    func testHeldMouseKeepsZoomAcrossRepeatedArrowsAndRawJpegReplacements() {
        let canvas = makeCanvas()
        // Decoder outputs, not ARW/JPEG codec fixtures: input handling is format-independent.
        let photos = [image(raw: false), image(raw: true, full: false), image(raw: false)]
        var index = 0
        var directions: [Int] = []
        var zoomChanges: [Bool] = []
        canvas.decoded = photos[index]
        canvas.zoomChanged = { zoomChanges.append($0) }
        canvas.navigate = { step in
            directions.append(step)
            let next = index + step
            guard photos.indices.contains(next) else { return }
            index = next
            canvas.decoded = photos[index]
        }
        defer { canvas.navigate = nil }

        holdUntilZoomStarts(canvas)
        canvas.keyDown(with: arrow(123)) // At the first photo, zoom must survive a no-op.
        XCTAssertEqual(index, 0)
        XCTAssertTrue(isRenderedZoomed(canvas))
        canvas.keyDown(with: arrow(124))
        XCTAssertEqual(index, 1)
        XCTAssertEqual(canvas.decoded?.raw, true)
        XCTAssertTrue(isRenderedZoomed(canvas))
        for _ in 0..<30 {
            canvas.keyDown(with: arrow(124, repeated: true))
            XCTAssertEqual(index, 2)
            XCTAssertEqual(canvas.decoded?.raw, false)
            XCTAssertTrue(isRenderedZoomed(canvas))
            canvas.keyDown(with: arrow(124, repeated: true)) // Last photo: another no-op.
            XCTAssertEqual(index, 2)
            XCTAssertTrue(isRenderedZoomed(canvas))
            canvas.keyDown(with: arrow(123, repeated: true))
            XCTAssertEqual(index, 1)
            XCTAssertEqual(canvas.decoded?.raw, true)
            XCTAssertTrue(isRenderedZoomed(canvas))
        }
        XCTAssertEqual(directions.count, 92)
        XCTAssertEqual(Array(directions.prefix(2)), [-1, 1])
        XCTAssertEqual(zoomChanges, [true])
        canvas.mouseUp(with: mouse(.leftMouseUp))
        XCTAssertEqual(zoomChanges, [true, false])
        XCTAssertFalse(isRenderedZoomed(canvas))
    }

    @MainActor
    func testReleaseBeforeAsyncPreviewAndFullImageArriveStaysInFit() {
        let canvas = makeCanvas()
        canvas.decoded = image(raw: false)
        var zoomChanges: [Bool] = []
        canvas.zoomChanged = { zoomChanges.append($0) }
        let finished = expectation(description: "late preview and full image")
        canvas.navigate = { _ in
            DispatchQueue.main.async {
                canvas.decoded = self.image(raw: true, full: false)
                XCTAssertFalse(self.isRenderedZoomed(canvas))
                canvas.decoded = self.image(raw: true)
                XCTAssertFalse(self.isRenderedZoomed(canvas))
                finished.fulfill()
            }
        }
        defer { canvas.navigate = nil }
        holdUntilZoomStarts(canvas)
        canvas.keyDown(with: arrow(124))
        canvas.mouseUp(with: mouse(.leftMouseUp))
        XCTAssertFalse(isRenderedZoomed(canvas))
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(zoomChanges, [true, false])
    }

    @MainActor
    func testEscapeStillResetsZoomAndCloses() {
        let canvas = makeCanvas()
        canvas.decoded = image(raw: false)
        var closed = false
        canvas.close = { closed = true }
        holdUntilZoomStarts(canvas)
        canvas.keyDown(with: arrow(53))
        XCTAssertTrue(closed)
        XCTAssertFalse(isRenderedZoomed(canvas))
    }

    @MainActor
    func testDeleteAndTagDoNotResetHeldZoomAndIgnoreKeyRepeat() {
        let canvas = makeCanvas(); canvas.decoded = image(raw: true)
        var trashed = 0, tagged = 0
        canvas.trashCurrent = { trashed += 1 }; canvas.toggleTag = { tagged += 1 }
        func key(_ code: UInt16, _ characters: String, repeated: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                             windowNumber: 0, context: nil, characters: characters,
                             charactersIgnoringModifiers: characters, isARepeat: repeated, keyCode: code)!
        }
        holdUntilZoomStarts(canvas)
        canvas.keyDown(with: key(51, "\u{7F}"))
        canvas.keyDown(with: key(51, "\u{7F}", repeated: true))
        canvas.keyDown(with: key(117, "\u{F728}"))
        canvas.keyDown(with: key(42, "\\"))
        canvas.keyDown(with: key(42, "\\", repeated: true))
        canvas.keyDown(with: key(42, "₩"))
        XCTAssertEqual(trashed, 2); XCTAssertEqual(tagged, 2)
        XCTAssertTrue(isRenderedZoomed(canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp))
        XCTAssertFalse(isRenderedZoomed(canvas))
    }
}
