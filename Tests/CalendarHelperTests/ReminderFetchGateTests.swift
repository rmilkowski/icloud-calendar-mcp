// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import CalendarCore

final class ReminderFetchGateTests: XCTestCase {
    func testCompletionAndFailureHaveOneConsumer() throws {
        let completed = ReminderFetchGate<[String]>()
        XCTAssertTrue(completed.complete(.success(["synthetic"])))
        XCTAssertFalse(completed.complete(.success(["replacement"])))
        XCTAssertEqual(try completed.wait(timeout: 0.1), ["synthetic"])
        XCTAssertThrowsError(try completed.wait(timeout: 0.1))
        let failure = ReminderFetchGate<String>()
        failure.complete(.failure(CoreError("synthetic_failure", "Synthetic bounded error")))
        XCTAssertThrowsError(try failure.wait(timeout: 0.1))
    }

    func testTimeoutRejectsLateCallbackAndBoundsConfiguration() {
        let request = ReminderFetchGate<String>()
        let start = Date()
        XCTAssertThrowsError(try request.wait(timeout: 0.01))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertFalse(request.complete(.success("late synthetic callback")))
        for timeout in [0.0, -1, 11, .infinity, .nan] {
            XCTAssertThrowsError(try ReminderFetchGate<String>().wait(timeout: timeout))
        }
    }

    func testConcurrentCompletionPublishesOnlyOnce() throws {
        let request = ReminderFetchGate<Int>()
        DispatchQueue.global().async { request.complete(.success(7)) }
        XCTAssertEqual(try request.wait(timeout: 1), 7)
        XCTAssertFalse(request.complete(.success(8)))
    }
}
