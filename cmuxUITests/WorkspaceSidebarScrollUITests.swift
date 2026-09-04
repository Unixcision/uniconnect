import CoreGraphics
import Foundation
import ImageIO
import XCTest

final class WorkspaceSidebarScrollUITests: XCTestCase {
    private let topTitlebarWorkspaceClearance: CGFloat = 32
    private let maxSidebarOverflowWorkspaceCount = 80

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testCompactRailRendersInExplicitDarkAppearance() {
        assertCompactRailAppearance(.dark)
    }

    func testCompactRailRendersInExplicitLightAppearance() {
        assertCompactRailAppearance(.light)
    }

    func testWorkspaceSelectionKeepsSidebarRowVisible() {
        let app = XCUIApplication()
        configureLaunch(app)
        launchAndEnsureRunning(app)
        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 8.0), "Expected a main window")
        XCTAssertTrue(
            waitForWorkspaceRowHittable(index: 1, count: 1, app: app, timeout: 8.0),
            "Expected the initial workspace row to be visible"
        )

        let workspaceCount = 20
        for expectedCount in 2...workspaceCount {
            app.typeKey("n", modifierFlags: [.command])
            XCTAssertTrue(
                waitForWorkspaceRowHittable(index: expectedCount, count: expectedCount, app: app, timeout: 6.0),
                "Expected the newly selected workspace \(expectedCount) to be visible"
            )
        }

        XCTAssertTrue(
            waitForWorkspaceRowHittable(index: workspaceCount, count: workspaceCount, app: app, timeout: 6.0),
            "Expected the newly selected bottom workspace to be visible"
        )

        app.typeKey("1", modifierFlags: [.command])
        XCTAssertTrue(
            waitForWorkspaceRowHittable(index: 1, count: workspaceCount, app: app, timeout: 6.0),
            "Expected Cmd+1 to scroll the first workspace back into view"
        )
        XCTAssertTrue(
            waitForWorkspaceRowClearsTitlebar(index: 1, count: workspaceCount, app: app, timeout: 6.0),
            "Expected Cmd+1 to keep the first workspace below the titlebar controls"
        )
    }

    func testCommandPaletteMoveWorkspaceToTopKeepsMovedWorkspaceVisible() {
        let app = XCUIApplication()
        configureLaunch(app)
        launchAndEnsureRunning(app)
        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 8.0), "Expected a main window")
        XCTAssertTrue(
            waitForWorkspaceRowHittable(index: 1, count: 1, app: app, timeout: 8.0),
            "Expected the initial workspace row to be visible"
        )

        let workspaceCount = 20
        for expectedCount in 2...workspaceCount {
            app.typeKey("n", modifierFlags: [.command])
            XCTAssertTrue(
                waitForWorkspaceRowHittable(index: expectedCount, count: expectedCount, app: app, timeout: 6.0),
                "Expected the newly selected workspace \(expectedCount) to be visible"
            )
        }

        runCommandPaletteMoveToTop(app: app)

        XCTAssertTrue(
            waitForWorkspaceRowHittable(index: 1, count: workspaceCount, app: app, timeout: 6.0),
            "Expected Cmd+Shift+P Move to Top to scroll the moved workspace back into view"
        )
    }

    func testSidebarScrollerVisibilityFollowsWorkspaceOverflow() {
        let app = XCUIApplication()
        configureLaunch(app)
        launchAndEnsureRunning(app)
        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 8.0), "Expected a main window")
        XCTAssertTrue(
            waitForWorkspaceRowHittable(index: 1, count: 1, app: app, timeout: 8.0),
            "Expected the initial workspace row to be visible"
        )

        let sidebar = app.descendants(matching: .any)["Sidebar"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5.0), "Expected the workspace sidebar to exist")
        XCTAssertTrue(
            waitForSidebarVerticalScrollerHidden(app: app, sidebar: sidebar, timeout: 4.0),
            "Expected the sidebar scroller to hide when the workspace content fits"
        )

        let overflowProbeStartCount = sidebarOverflowProbeStartCount(app: app, sidebar: sidebar)
        var overflowReached = false
        for expectedCount in 2...maxSidebarOverflowWorkspaceCount {
            app.typeKey("n", modifierFlags: [.command])
            XCTAssertTrue(
                waitForWorkspaceRowHittable(index: expectedCount, count: expectedCount, app: app, timeout: 6.0),
                "Expected the newly selected workspace \(expectedCount) to be visible"
            )

            guard expectedCount >= overflowProbeStartCount else { continue }
            if revealSidebarVerticalScroller(app: app, sidebar: sidebar, timeout: 1.0) {
                overflowReached = true
                break
            }
        }

        XCTAssertTrue(
            overflowReached,
            "Expected the sidebar scroller to appear before creating \(maxSidebarOverflowWorkspaceCount) workspaces"
        )
    }

    private enum AppearanceUnderTest: String {
        case dark
        case light
    }

    private func assertCompactRailAppearance(_ appearance: AppearanceUnderTest) {
        let app = XCUIApplication()
        let dataPath = "/tmp/uniconnect-ui-appearance-\(appearance.rawValue)-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)

        configureLaunch(app, appearance: appearance, compactSidebar: true)
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH"] = dataPath
        launchAndEnsureRunning(app)
        defer {
            app.terminate()
            try? FileManager.default.removeItem(atPath: dataPath)
        }

        XCTAssertTrue(
            waitForJSONValue("ready", equals: "1", atPath: dataPath, timeout: 20),
            "Expected the two-window appearance fixture to become ready"
        )

        let rail = app.descendants(matching: .any)["UniConnectRailSidebar"].firstMatch
        XCTAssertTrue(rail.waitForExistence(timeout: 8), "Expected the compact UniConnect rail")

        let railScreenshot = rail.screenshot()
        addKeptScreenshot(railScreenshot, name: "UniConnect-rail-\(appearance.rawValue)")
        guard let luminance = medianRelativeLuminance(of: railScreenshot) else {
            XCTFail("Expected to measure the compact rail screenshot")
            return
        }
        assertExpectedLuminance(
            luminance,
            appearance: appearance,
            element: "compact rail"
        )

        let tile = app.descendants(matching: .button)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "UniConnectRailTile-"))
            .firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "Expected a compact workspace tile")
        tile.click()

        let flyout = app.descendants(matching: .any)["UniConnectRailFlyout"].firstMatch
        XCTAssertTrue(flyout.waitForExistence(timeout: 5), "Expected the persistent workspace card after click")
        let flyoutWindows = app.descendants(matching: .button)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "UniConnectRailFlyoutWindow-"))
        XCTAssertTrue(
            pollUntil(timeout: 5) { flyoutWindows.count >= 2 },
            "Expected the hover card to list both fixture windows"
        )
        let flyoutScreenshot = flyout.screenshot()
        addKeptScreenshot(flyoutScreenshot, name: "UniConnect-flyout-\(appearance.rawValue)")
        guard let flyoutLuminance = medianRelativeLuminance(of: flyoutScreenshot) else {
            XCTFail("Expected to measure the workspace flyout screenshot")
            return
        }
        assertExpectedLuminance(
            flyoutLuminance,
            appearance: appearance,
            element: "workspace flyout"
        )

        tile.rightClick()
        XCTAssertTrue(
            app.menuItems["Rename Box…"].waitForExistence(timeout: 4),
            "Expected the rail menu to expose Rename Box"
        )
        XCTAssertTrue(
            app.menuItems["New Window"].waitForExistence(timeout: 2),
            "Expected the rail menu to expose New Window"
        )
        XCTAssertTrue(
            app.menuItems["Close Box"].waitForExistence(timeout: 2),
            "Expected the rail menu to expose Close Box"
        )
        addKeptScreenshot(XCUIScreen.main.screenshot(), name: "UniConnect-context-menu-\(appearance.rawValue)")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

        app.typeKey("p", modifierFlags: [.command, .shift])
        let paletteSearch = app.textFields["CommandPaletteSearchField"].firstMatch
        XCTAssertTrue(paletteSearch.waitForExistence(timeout: 5), "Expected the command palette")
        paletteSearch.click()
        paletteSearch.typeText("Save Now")
        let saveNow = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@ AND value == %@",
                    "CommandPaletteResultRow.",
                    "palette.uniConnect.persistNow"
                )
            )
            .firstMatch
        XCTAssertTrue(saveNow.waitForExistence(timeout: 5), "Expected Save Now in the command palette")
        addKeptScreenshot(app.windows.firstMatch.screenshot(), name: "UniConnect-palette-\(appearance.rawValue)")
    }

    private func configureLaunch(
        _ app: XCUIApplication,
        appearance: AppearanceUnderTest = .dark,
        compactSidebar: Bool = false
    ) {
        app.launchArguments += ["-newWorkspacePlacement", "end"]
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
            "-menuBarOnly", "false",
            "-uniconnect.sidebarCompact", compactSidebar ? "true" : "false",
        ]
        app.launchArguments += ["-appearanceMode", appearance.rawValue]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = compactSidebar
            ? "ui-appearance-\(appearance.rawValue)"
            : "ui-sidebar-scroll"
    }

    private func waitForJSONValue(
        _ key: String,
        equals expectedValue: String,
        atPath path: String,
        timeout: TimeInterval
    ) -> Bool {
        pollUntil(timeout: timeout) {
            guard let data = FileManager.default.contents(atPath: path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return false
            }
            return object[key] == expectedValue
        }
    }

    private func medianRelativeLuminance(of screenshot: XCUIScreenshot) -> Double? {
        guard let source = CGImageSourceCreateWithData(screenshot.pngRepresentation as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let rendered = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        var samples: [Double] = []
        samples.reserveCapacity((width / 3 + 1) * (height / 3 + 1))
        for y in stride(from: 0, to: height, by: 3) {
            for x in stride(from: 0, to: width, by: 3) {
                let index = (y * bytesPerRow) + (x * bytesPerPixel)
                let red = Double(pixels[index]) / 255
                let green = Double(pixels[index + 1]) / 255
                let blue = Double(pixels[index + 2]) / 255
                samples.append((0.2126 * red) + (0.7152 * green) + (0.0722 * blue))
            }
        }
        guard !samples.isEmpty else { return nil }
        samples.sort()
        return samples[samples.count / 2]
    }

    private func addKeptScreenshot(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertExpectedLuminance(
        _ luminance: Double,
        appearance: AppearanceUnderTest,
        element: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch appearance {
        case .dark:
            XCTAssertLessThan(
                luminance,
                0.50,
                "Expected the explicit dark \(element) to render dark; luminance=\(luminance)",
                file: file,
                line: line
            )
        case .light:
            XCTAssertGreaterThan(
                luminance,
                0.50,
                "Expected the explicit light \(element) to render light; luminance=\(luminance)",
                file: file,
                line: line
            )
        }
    }

    private func waitForWorkspaceRowHittable(
        index: Int,
        count: Int,
        app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        return pollUntil(timeout: timeout) {
            let row = workspaceRow(index: index, count: count, app: app)
            return row.exists && row.isHittable
        }
    }

    private func waitForWorkspaceRowClearsTitlebar(
        index: Int,
        count: Int,
        app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        pollUntil(timeout: timeout) {
            let row = workspaceRow(index: index, count: count, app: app)
            let window = app.windows.firstMatch
            guard row.exists, row.isHittable, window.exists else { return false }
            return row.frame.minY >= window.frame.minY + topTitlebarWorkspaceClearance
        }
    }

    private func workspaceRow(index: Int, count: Int, app: XCUIApplication) -> XCUIElement {
        let position = "workspace \(index) of \(count)"
        return app.descendants(matching: .other)
            .matching(NSPredicate(format: "label ENDSWITH %@", position))
            .firstMatch
    }

    private func sidebarOverflowProbeStartCount(app: XCUIApplication, sidebar: XCUIElement) -> Int {
        let firstRow = workspaceRow(index: 1, count: 1, app: app)
        guard sidebar.exists, firstRow.exists else { return 8 }

        let rowHeight = max(firstRow.frame.height, 1)
        let visibleRows = Int(ceil(sidebar.frame.height / rowHeight))
        return min(maxSidebarOverflowWorkspaceCount, max(3, visibleRows + 1))
    }

    private func waitForWindowCount(atLeast count: Int, app: XCUIApplication, timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            app.windows.count >= count
        }
    }

    private func waitForSidebarVerticalScrollerHidden(
        app: XCUIApplication,
        sidebar: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        pollUntil(timeout: timeout) {
            visibleSidebarVerticalScrollers(app: app, sidebar: sidebar).isEmpty
        }
    }

    private func waitForSidebarVerticalScrollerVisible(
        app: XCUIApplication,
        sidebar: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        pollUntil(timeout: timeout) {
            !visibleSidebarVerticalScrollers(app: app, sidebar: sidebar).isEmpty
        }
    }

    private func runCommandPaletteMoveToTop(app: XCUIApplication) {
        let searchField = app.textFields["CommandPaletteSearchField"].firstMatch
        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(searchField.waitForExistence(timeout: 5.0), "Expected command palette search field")
        searchField.click()
        searchField.typeText("move to top")

        let row = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@ AND value == %@",
                    "CommandPaletteResultRow.",
                    "palette.moveWorkspaceToTop"
                )
            )
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5.0), "Expected Move to Top command palette row")
        row.click()
        XCTAssertTrue(
            waitForNonExistence(searchField, timeout: 5.0),
            "Expected command palette to dismiss after Move to Top"
        )
    }

    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            !element.exists
        }
    }

    private func revealSidebarVerticalScroller(
        app: XCUIApplication,
        sidebar: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        sidebar.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).hover()
        if waitForSidebarVerticalScrollerVisible(app: app, sidebar: sidebar, timeout: min(0.25, timeout)) {
            return true
        }
        sidebar.swipeUp()
        return waitForSidebarVerticalScrollerVisible(app: app, sidebar: sidebar, timeout: timeout)
    }

    private func visibleSidebarVerticalScrollers(
        app: XCUIApplication,
        sidebar: XCUIElement
    ) -> [XCUIElement] {
        guard sidebar.exists else { return [] }
        let sidebarFrame = sidebar.frame
        return app.descendants(matching: .scrollBar).allElementsBoundByIndex.filter { scroller in
            guard scroller.exists, scroller.isHittable else { return false }
            let frame = scroller.frame
            guard frame.width > 0, frame.height > frame.width else { return false }
            return frame.midX >= sidebarFrame.minX
                && frame.midX <= sidebarFrame.maxX
                && frame.maxY > sidebarFrame.minY
                && frame.minY < sidebarFrame.maxY
        }
    }

    private func launchAndEnsureRunning(_ app: XCUIApplication) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("Headless CI may launch the app without foreground activation", options: options) {
            app.launch()
        }
        XCTAssertTrue(
            pollUntil(timeout: 10.0) {
                app.state == .runningForeground || app.state == .runningBackground
            },
            "App failed to launch. state=\(app.state.rawValue)"
        )
    }

    private func pollUntil(
        timeout: TimeInterval,
        interval: TimeInterval = 0.05,
        condition: () -> Bool
    ) -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        while true {
            if condition() {
                return true
            }
            if ProcessInfo.processInfo.systemUptime - start >= timeout {
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
        }
    }
}
