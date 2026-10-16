import XCTest
final class PagerUITests: XCTestCase {
    func testDoubleTapResetsZoomAndPaging() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.staticTexts["Selected 1 / 3"].waitForExistence(timeout: 10))
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        center.doubleTap()
        XCTAssertTrue(app.staticTexts["Zoomed"].waitForExistence(timeout: 3))
        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["Selected 1 / 3"].exists)
        center.doubleTap()
        XCTAssertTrue(app.staticTexts["Fit"].waitForExistence(timeout: 3))
        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["Selected 2 / 3"].waitForExistence(timeout: 3))
    }
    func testRealGestures() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Selected 1 / 3"].waitForExistence(timeout: 10))
        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["Selected 2 / 3"].waitForExistence(timeout: 3), "Horizontal paging must follow a real finger swipe")
        app.scrollViews["media-image-zoom"].pinch(withScale: 2, velocity: 1)
        XCTAssertTrue(app.staticTexts["Zoomed"].waitForExistence(timeout: 3))
        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["Selected 2 / 3"].exists, "Zoomed images must pan without turning the page")
        // XCTest pinch scale is approximate at screen edges: continue until the
        // scroll view actually reaches its minimum, then verify paging resumes.
        for _ in 0..<4 where !app.staticTexts["Fit"].exists {
            app.scrollViews["media-image-zoom"].pinch(withScale: 0.2, velocity: -2)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.lifetime = .keepAlways; add(screenshot)
        XCTAssertTrue(app.staticTexts["Fit"].waitForExistence(timeout: 3), "Pinch back must restore paging")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let short = app.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: short)
        XCTAssertTrue(app.staticTexts["Selected 2 / 3"].exists, "A short cancelled drag must not change the page")
        app.swipeRight()
        XCTAssertTrue(app.staticTexts["Selected 1 / 3"].waitForExistence(timeout: 3))
        app.swipeRight()
        XCTAssertTrue(app.staticTexts["Selected 1 / 3"].exists, "The first page must resist overscroll")
        app.segmentedControls.buttons["Vertical"].tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Selected 2 / 3"].waitForExistence(timeout: 3), "Vertical paging must follow a real finger swipe")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Selected 3 / 3"].waitForExistence(timeout: 3))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Selected 3 / 3"].exists, "The last page must resist overscroll")
        app.swipeDown(); app.swipeDown()
        XCTAssertTrue(app.staticTexts["Selected 1 / 3"].waitForExistence(timeout: 3))
    }
}
