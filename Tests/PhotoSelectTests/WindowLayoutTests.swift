import XCTest
@testable import PhotoSelect

final class WindowLayoutTests: XCTestCase {
    private let screens = [
        CGRect(x: 0, y: 24, width: 640, height: 336),
        CGRect(x: 0, y: 50, width: 1024, height: 680),
        CGRect(x: 0, y: 60, width: 1512, height: 890), // M1 Pro Retina logical points.
        CGRect(x: -1920, y: 30, width: 1920, height: 1010),
        CGRect(x: 2048, y: 40, width: 3840, height: 2060)
    ]
    func testInitialWindowsFitSmallRetinaAndMultipleDisplayAreas() {
        for screen in screens {
            for kind in [WindowLayout.Kind.browser, .viewer] {
                let frame = WindowLayout.initialFrame(in: screen, kind: kind)
                XCTAssertTrue(screen.contains(frame))
                XCTAssertEqual(frame.midX, screen.midX, accuracy: 0.5)
                XCTAssertEqual(frame.midY, screen.midY, accuracy: 0.5)
                XCTAssertGreaterThan(frame.width, 0); XCTAssertGreaterThan(frame.height, 0)
            }
        }
    }
    func testMinimumSizesNeverForceWindowOutsideSmallDisplay() {
        for screen in screens {
            for kind in [WindowLayout.Kind.browser, .viewer] {
                let minimum = WindowLayout.minimumSize(in: screen, kind: kind)
                let frame = WindowLayout.initialFrame(in: screen, kind: kind)
                XCTAssertLessThanOrEqual(minimum.width, frame.width)
                XCTAssertLessThanOrEqual(minimum.height, frame.height)
                XCTAssertLessThan(frame.width, screen.width)
                XCTAssertLessThan(frame.height, screen.height)
            }
        }
    }
    func testMovedOrDisconnectedDisplayFrameFitsNewScreen() {
        let oldFrame = CGRect(x: 2500, y: 600, width: 1800, height: 1200)
        for screen in screens {
            for kind in [WindowLayout.Kind.browser, .viewer] {
                let frame = WindowLayout.fittedFrame(oldFrame, in: screen, kind: kind)
                XCTAssertTrue(screen.contains(frame))
                XCTAssertEqual(WindowLayout.fittedFrame(frame, in: screen, kind: kind), frame)
            }
        }
    }
    func testPhotoGridGetsMostWidthAndPreviewHasBoundedSize() {
        for width in [CGFloat(480), 640, 800, 1000, 1280, 1600, 2560, 3840] {
            let columns = WindowLayout.columns(for: width)
            XCTAssertEqual(columns.folders + columns.photos + columns.preview + 2, width, accuracy: 0.01)
            XCTAssertGreaterThan(columns.folders, 0); XCTAssertGreaterThan(columns.preview, 0)
            XCTAssertLessThanOrEqual(columns.folders, 240)
            XCTAssertLessThanOrEqual(columns.preview, 320)
            XCTAssertLessThan(columns.preview, width * 0.30)
            XCTAssertGreaterThanOrEqual(columns.photos, (width - 2) * 0.5 - 0.01)
        }
    }
}
