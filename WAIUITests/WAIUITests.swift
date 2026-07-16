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

        let outboundDuty = app.descendants(matching: .any)[
            "wai3.roster.duty.fixture-outbound-duty"
        ]
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
        let captain = app.descendants(matching: .any)[
            "wai3.crew.member.shared.10000.1-CPT-false"
        ]
        scrollUntilAccessible(captain, in: app)
        XCTAssertTrue(captain.label.contains("Test Captain"))
        XCTAssertTrue(captain.label.contains("CPT"))
        let cabinCrew = app.descendants(matching: .any).matching(
            identifier: "wai3.crew.member.shared.12345.6-CAB-false"
        )
        XCTAssertEqual(cabinCrew.count, 1)

        let hotelDetails = app.descendants(matching: .any)[
            "wai3.stay.hotelDetails"
        ]
        scrollUntilAccessible(hotelDetails, in: app)
        XCTAssertTrue(
            hotelDetails.label.contains("Radisson Blu Scandinavia Hotel")
        )
        hotelDetails.tap()

        XCTAssertTrue(app.navigationBars["Hotel"].waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.staticTexts["Radisson Blu Scandinavia Hotel"].exists
        )
        app.navigationBars["Hotel"].buttons["Done"].tap()
        XCTAssertTrue(
            app.navigationBars["2CPH1501P"].waitForExistence(timeout: 2)
        )

        let editRoomNumber = app.buttons["Edit room number"]
        scrollUntilAccessible(editRoomNumber, in: app, attempts: 12)
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

        let outboundDuty = app.descendants(matching: .any)[
            "wai3.roster.duty.fixture-outbound-duty"
        ]
        scrollToEarlierContentUntilAccessible(outboundDuty, in: app)
        XCTAssertTrue(outboundDuty.label.contains("Wake-up"))
        XCTAssertTrue(outboundDuty.label.contains("Pick-up"))
        assertHorizontallyContained(outboundDuty, in: app)
        attachScreenshot(named: "WAI 3 dark accessibility roster")

        outboundDuty.tap()
        let dutyNavigation = app.navigationBars["2CPH1501P"]
        if !dutyNavigation.waitForExistence(timeout: 3) {
            XCTAssertTrue(outboundDuty.waitForExistence(timeout: 2))
            outboundDuty.tap()
        }
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

    func testApprovedFixtureSupportsHomeRoutineAndBriefingEdits() {
        let app = XCUIApplication()
        app.launchArguments.append("--wai3-approved-ui-test-fixture")
        app.launch()

        let outboundDuty = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "2CPH1501P")
        ).firstMatch
        XCTAssertTrue(outboundDuty.waitForExistence(timeout: 4))
        XCTAssertTrue(outboundDuty.label.contains("Pick-up / leave home"))
        outboundDuty.tap()

        let adjustHomeRoutine = app.descendants(matching: .any)[
            "wai3.homeRoutine.adjust"
        ]
        scrollUntilAccessible(adjustHomeRoutine, in: app)
        adjustHomeRoutine.tap()
        XCTAssertTrue(
            app.navigationBars["Adjust home departure"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["wai3.homeRoutine.wakeup"].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["wai3.homeRoutine.pickup"].exists
        )
        app.buttons["Save"].tap()
        XCTAssertTrue(
            app.staticTexts["Adjusted for this duty"]
                .waitForExistence(timeout: 2)
        )

        let editBriefing = app.descendants(matching: .any)[
            "wai3.briefing.edit.fixture-outbound-leg"
        ]
        scrollToEarlierContentUntilAccessible(editBriefing, in: app)
        editBriefing.tap()

        XCTAssertTrue(
            app.navigationBars["TP0754 briefing"]
                .waitForExistence(timeout: 2)
        )
        let pax = app.descendants(matching: .any)["wai3.briefing.pax"]
        XCTAssertTrue(pax.waitForExistence(timeout: 2))
        pax.tap()
        pax.typeText(
            String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3)
                + "166"
        )
        let returnKey = app.keyboards.buttons["Return"]
        if returnKey.waitForExistence(timeout: 1) {
            returnKey.tap()
        }

        let customFlightTime = app.switches[
            "wai3.briefing.customFlightTime"
        ]
        scrollUntilAccessible(customFlightTime, in: app)
        customFlightTime.coordinate(
            withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)
        ).tap()
        XCTAssertEqual(customFlightTime.value as? String, "1")

        let password = app.descendants(matching: .any)[
            "wai3.briefing.password"
        ]
        scrollUntilAccessible(password, in: app)
        password.tap()
        password.typeText("7421")
        app.buttons["Save"].tap()

        let paxValue = app.descendants(matching: .any)[
            "wai3.briefing.paxValue.fixture-outbound-leg"
        ]
        XCTAssertTrue(paxValue.waitForExistence(timeout: 2))
        XCTAssertTrue(paxValue.label.contains("166"))
        let passwordStatus = app.descendants(matching: .any)[
            "wai3.briefing.passwordStatus.fixture-outbound-leg"
        ]
        XCTAssertTrue(passwordStatus.waitForExistence(timeout: 2))
        XCTAssertTrue(passwordStatus.label.contains("Saved"))
        XCTAssertTrue(
            app.descendants(matching: .any)["wai3.briefing.calendarSynced"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertFalse(app.staticTexts["7421"].exists)
    }

    func testLisbonDepartureOffersHomeRoutineSetup() {
        let app = XCUIApplication()
        app.launchArguments.append(
            "--wai3-approved-ui-test-fixture-no-home-routine"
        )
        app.launch()

        let outboundDuty = app.descendants(matching: .any)[
            "wai3.roster.duty.fixture-outbound-duty"
        ]
        XCTAssertTrue(outboundDuty.waitForExistence(timeout: 4))
        XCTAssertTrue(
            outboundDuty.label.contains("Set wake-up and pick-up")
        )
        outboundDuty.tap()

        let setup = app.descendants(matching: .any)[
            "wai3.homeRoutine.setup"
        ]
        XCTAssertTrue(setup.waitForExistence(timeout: 2))
        setup.tap()

        XCTAssertTrue(
            app.navigationBars["Home routine"].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        app.buttons["Save"].tap()

        XCTAssertTrue(
            app.staticTexts["Pick-up / leave home"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["Wake-up"].exists)
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

    private func scrollToEarlierContentUntilAccessible(
        _ element: XCUIElement,
        in app: XCUIApplication,
        attempts: Int = 8
    ) {
        for _ in 0..<attempts
        where !element.isHittable
            || element.frame.minY < app.frame.minY + 120 {
            app.swipeDown()
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
