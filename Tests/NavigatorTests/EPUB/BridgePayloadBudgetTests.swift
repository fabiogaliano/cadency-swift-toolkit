//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import XCTest

final class BridgePayloadBudgetTests: XCTestCase {
    func testAcceptsACompactJSONPayload() {
        XCTAssertSuccess(BridgePayloadBudget.validate([
            "href": "chapter.xhtml",
            "locations": ["cssSelector": "p:nth-child(2)"],
            "rect": ["x": 1.0, "y": 2.0, "width": 3.0, "height": 4.0],
        ]))
    }

    func testRejectsEveryBudgetDimension() {
        let deeplyNested = (0 ... BridgePayloadBudget.maxDepth).reduce("leaf" as Any) { value, _ in [value] }
        let cases: [(Any, BridgePayloadBudget.Rejection)] = [
            (Double.nan, .nonFiniteNumber),
            (deeplyNested, .tooDeep),
            (Array(repeating: 0, count: BridgePayloadBudget.maxEntries + 1), .tooManyEntries),
            (String(repeating: "x", count: BridgePayloadBudget.maxStringBytes + 1), .stringTooLong),
            (Array(repeating: String(repeating: "x", count: 1024), count: BridgePayloadBudget.maxEntries), .tooLarge),
            (Date(), .unsupportedValue),
        ]

        for (payload, expected) in cases {
            XCTAssertEqual(failure(BridgePayloadBudget.validate(payload)), expected)
        }
    }

    private func XCTAssertSuccess(
        _ result: Result<Void, BridgePayloadBudget.Rejection>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case let .failure(rejection) = result {
            XCTFail("Expected success, got \(rejection)", file: file, line: line)
        }
    }

    private func failure(_ result: Result<Void, BridgePayloadBudget.Rejection>) -> BridgePayloadBudget.Rejection? {
        if case let .failure(rejection) = result { return rejection }
        return nil
    }
}
