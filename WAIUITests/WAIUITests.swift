//
//  WAIUITests.swift
//  WAIUITests
//
//  Created by Jopepo on 19/05/2026.
//

import XCTest

final class WAIUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunches() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertEqual(app.state, .runningForeground)
    }

    func testSecureEntryPointExposesPrivacyPolicy() throws {
        let app = XCUIApplication()
        app.launch()

        let heading = app.staticTexts["Crew timing, ready when you are"]
        guard heading.waitForExistence(timeout: 3) else {
            throw XCTSkip("WAI 3 secure mode is not enabled for this build")
        }

        XCTAssertTrue(app.buttons["Continue with Apple"].exists)
        XCTAssertFalse(app.staticTexts["ETD (UTC)"].exists)

        let privacyPolicy = app.descendants(matching: .any)[
            "wai3.privacyPolicy"
        ]
        XCTAssertTrue(privacyPolicy.waitForExistence(timeout: 2))
        for _ in 0..<3 where !privacyPolicy.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(privacyPolicy.isHittable)
    }

    func testApprovedFixtureCoversCrewWorkspace() {
        let app = XCUIApplication()
        app.launchArguments.append("--wai3-approved-ui-test-fixture")
        app.launch()

        let outboundDuty = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "2CPH1501P")
        ).firstMatch
        XCTAssertTrue(outboundDuty.waitForExistence(timeout: 4))
        XCTAssertTrue(outboundDuty.label.contains("13:30 - 19:00"))
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", "Wake-up")
            ).firstMatch.exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", "Pick-up")
            ).firstMatch.exists
        )

        outboundDuty.tap()

        XCTAssertTrue(app.navigationBars["2CPH1501P"].waitForExistence(timeout: 2))
        let editRoomNumber = app.buttons["Edit room number"]
        let hotelName = app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS[c] %@",
                "Radisson Blu Scandinavia Hotel"
            )
        ).firstMatch
        var foundHotelName = hotelName.exists
        for _ in 0..<6 {
            foundHotelName = foundHotelName || hotelName.exists
            if editRoomNumber.exists {
                let midpoint = editRoomNumber.frame.midY
                if editRoomNumber.isHittable, midpoint > 180, midpoint < 700 {
                    break
                }
            }
            app.swipeUp()
        }
        XCTAssertTrue(editRoomNumber.waitForExistence(timeout: 2))
        foundHotelName = foundHotelName || hotelName.exists
        XCTAssertTrue(foundHotelName)
        XCTAssertTrue(editRoomNumber.isHittable)
        XCTAssertGreaterThan(editRoomNumber.frame.midY, 180)
        XCTAssertLessThan(editRoomNumber.frame.midY, 700)
        editRoomNumber.tap()

        let roomNumber = app.textFields["Room number"]
        XCTAssertTrue(roomNumber.waitForExistence(timeout: 2))
        roomNumber.tap()
        roomNumber.typeText("742")
        app.buttons["Save"].tap()
        app.buttons["Done"].tap()

        XCTAssertTrue(app.staticTexts["Room 742"].waitForExistence(timeout: 2))

        app.tabBars.buttons["Analysis"].tap()
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Flight activity")
            ).firstMatch.waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH[c] %@", "Rotations")
            ).firstMatch.exists
        )

        let legVerification = app.descendants(matching: .any)[
            "wai3.analysis.legVerification"
        ]
        scrollUntilAccessible(legVerification, in: app)
        XCTAssertTrue(legVerification.isHittable)
        legVerification.tap()
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "TP0999")
            ).firstMatch.waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "DME")
            ).firstMatch.exists
        )

        let overlapConflict = app.descendants(matching: .any)[
            "wai3.analysis.overlapConflict"
        ]
        scrollUntilAccessible(overlapConflict, in: app)
        XCTAssertTrue(overlapConflict.isHittable)
        overlapConflict.tap()
        XCTAssertTrue(
            app.staticTexts["LISDME overlaps CPHLIS"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.buttons["Check Calendar Again"].exists)
        XCTAssertTrue(app.buttons["Import Updated iCal"].exists)

        app.tabBars.buttons["Calculator"].tap()
        XCTAssertTrue(
            app.staticTexts["Wakeup/Pickup Calculator"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Select station")
            ).firstMatch.exists
        )
    }

    func testApprovedFixtureSupportsDarkAccessibilityContent() {
        let app = XCUIApplication()
        app.launchArguments.append(
            "--wai3-approved-ui-test-fixture-dark-accessibility"
        )
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["wai3.approvedUITestFixture"]
                .waitForExistence(timeout: 4)
        )
        XCTAssertTrue(app.tabBars.buttons["Roster"].isHittable)
        XCTAssertTrue(app.tabBars.buttons["Analysis"].exists)
        XCTAssertTrue(app.tabBars.buttons["Calculator"].exists)

        let outboundDuty = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "2CPH1501P")
        ).firstMatch
        scrollUntilAccessible(outboundDuty, in: app)
        XCTAssertTrue(outboundDuty.label.contains("Wake-up"))
        XCTAssertTrue(outboundDuty.label.contains("Pick-up"))
        assertHorizontallyContained(outboundDuty, in: app)
        attachScreenshot(named: "WAI 3 dark accessibility roster")

        outboundDuty.tap()
        let dutyNavigation = app.navigationBars["2CPH1501P"]
        XCTAssertTrue(dutyNavigation.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Done"].isHittable)
        assertHorizontallyContained(dutyNavigation, in: app)
        attachScreenshot(named: "WAI 3 dark accessibility duty")
        app.buttons["Done"].tap()

        app.tabBars.buttons["Calculator"].tap()
        XCTAssertTrue(
            app.staticTexts["Wakeup/Pickup Calculator"]
                .waitForExistence(timeout: 3)
        )
        for label in [
            "What's New",
            "Hotels",
            "Saved Calculations",
            "Settings",
            "Account"
        ] {
            let button = app.buttons[label]
            XCTAssertTrue(button.exists)
            assertHorizontallyContained(button, in: app)
        }
        let stationPicker = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Select station")
        ).firstMatch
        scrollUntilAccessible(stationPicker, in: app)
        assertHorizontallyContained(stationPicker, in: app)
        attachScreenshot(named: "WAI 3 dark accessibility calculator")
    }

    private func scrollUntilAccessible(
        _ element: XCUIElement,
        in app: XCUIApplication,
        attempts: Int = 8
    ) {
        for _ in 0..<attempts where !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 2))
        XCTAssertTrue(element.isHittable)
    }

    private func assertHorizontallyContained(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) {
        let appFrame = app.frame
        let elementFrame = element.frame
        XCTAssertGreaterThan(elementFrame.width, 0)
        XCTAssertGreaterThan(elementFrame.height, 0)
        XCTAssertGreaterThanOrEqual(elementFrame.minX, appFrame.minX - 1)
        XCTAssertLessThanOrEqual(elementFrame.maxX, appFrame.maxX + 1)
        XCTAssertFalse(appFrame.intersection(elementFrame).isNull)
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(
            screenshot: XCUIScreen.main.screenshot()
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }
}
