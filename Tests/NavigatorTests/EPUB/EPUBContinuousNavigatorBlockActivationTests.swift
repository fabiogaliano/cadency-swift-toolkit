//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import XCTest

/// Contract tests for `blockActivated` message validation: every malformed payload must be
/// rejected with a warning rather than surfacing as a degraded-but-present activation.
class EPUBContinuousNavigatorBlockActivationTests: XCTestCase {
    private typealias Nav = EPUBContinuousNavigatorViewController

    private let readingOrder: [Link] = [
        Link(href: "chapter1.xhtml", mediaType: .xhtml),
        Link(href: "chapter2.xhtml", mediaType: .xhtml),
    ]

    private func chapterURL(_ link: Link) -> AnyURL {
        AnyURL(string: "http://127.0.0.1:8080/publication/\(link.href)")!
    }

    private func validLocator(href: String = "chapter1.xhtml") -> [String: Any] {
        [
            "href": href,
            "type": "application/xhtml+xml",
            "locations": ["cssSelector": "#chapter > p:nth-child(3)"],
            "text": [
                "highlight": "The exact block text.",
                "before": "Preceding context.",
                "after": "Following context.",
            ],
        ]
    }

    private func validBody(
        locator: Any? = nil,
        rect: Any? = ["x": 12.0, "y": 34.0, "width": 320.0, "height": 48.0],
        blockKey: Any? = "chapter1.xhtml##chapter > p:nth-child(3)::abc123",
        trigger: Any? = "double-tap"
    ) -> [String: Any] {
        var body: [String: Any] = [:]
        body["locator"] = locator ?? validLocator()
        if let rect { body["rect"] = rect }
        if let blockKey { body["blockKey"] = blockKey }
        if let trigger { body["trigger"] = trigger }
        return body
    }

    private func parse(
        _ body: Any,
        frameURL: URL? = nil
    ) -> Result<Nav.BlockActivationEvent, Nav.BlockActivationRejection> {
        Nav.parseBlockActivationEvent(
            body,
            frameURL: frameURL,
            readingOrder: readingOrder,
            urlToLink: chapterURL
        )
    }

    private func assertRejected(
        _ body: Any,
        frameURL: URL? = nil,
        warningContains fragment: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        switch parse(body, frameURL: frameURL) {
        case .success:
            XCTFail("Expected rejection containing \"\(fragment)\"", file: file, line: line)
        case let .failure(rejection):
            XCTAssertTrue(
                rejection.warning.contains(fragment),
                "Warning \"\(rejection.warning)\" does not contain \"\(fragment)\"",
                file: file,
                line: line
            )
        }
    }

    // MARK: - Valid payloads

    func testAcceptsValidPayload() throws {
        let event = try parse(validBody()).get()
        XCTAssertEqual(event.locator.href, AnyURL(string: "chapter1.xhtml")!)
        XCTAssertEqual(event.locator.locations.cssSelector, "#chapter > p:nth-child(3)")
        XCTAssertEqual(event.locator.text.highlight, "The exact block text.")
        XCTAssertEqual(event.rect, CGRect(x: 12, y: 34, width: 320, height: 48))
        XCTAssertEqual(event.blockKey, "chapter1.xhtml##chapter > p:nth-child(3)::abc123")
        XCTAssertEqual(event.trigger, .doubleTap)
    }

    func testAcceptsSingleTapTrigger() throws {
        let event = try parse(validBody(trigger: "single-tap")).get()
        XCTAssertEqual(event.trigger, .singleTap)
    }

    func testAcceptsMissingBlockKeyAsNil() throws {
        let event = try parse(validBody(blockKey: nil)).get()
        XCTAssertNil(event.blockKey)
    }

    func testAcceptsNSNullBlockKeyAsNil() throws {
        // WKScriptMessage.body bridges JS `null` to NSNull; it must not be rejected.
        let event = try parse(validBody(blockKey: NSNull())).get()
        XCTAssertNil(event.blockKey)
    }

    // MARK: - Malformed payloads

    func testRejectsNonDictionaryBody() {
        assertRejected("not a dictionary", warningContains: "not a dictionary")
        assertRejected(42, warningContains: "not a dictionary")
        assertRejected([validBody()], warningContains: "not a dictionary")
    }

    func testRejectsMissingLocator() {
        var body = validBody()
        body["locator"] = nil
        assertRejected(body, warningContains: "valid locator")
    }

    func testRejectsMalformedLocator() {
        assertRejected(validBody(locator: ["type": "application/xhtml+xml"]), warningContains: "valid locator")
        assertRejected(validBody(locator: "chapter1.xhtml"), warningContains: "valid locator")
    }

    func testRejectsHrefOutsideReadingOrder() {
        assertRejected(
            validBody(locator: validLocator(href: "unknown.xhtml")),
            warningContains: "not in the publication reading order"
        )
    }

    func testRejectsNonXHTMLLocatorType() {
        var locator = validLocator()
        locator["type"] = "text/plain"
        assertRejected(validBody(locator: locator), warningContains: "not XHTML")
    }

    func testRejectsMissingOrEmptyCSSSelector() {
        var locator = validLocator()
        locator["locations"] = [:] as [String: Any]
        assertRejected(validBody(locator: locator), warningContains: "cssSelector")

        locator["locations"] = ["cssSelector": ""]
        assertRejected(validBody(locator: locator), warningContains: "cssSelector")
    }

    func testRejectsMissingOrEmptyHighlight() {
        var locator = validLocator()
        locator["text"] = ["before": "context only"]
        assertRejected(validBody(locator: locator), warningContains: "text.highlight")

        locator["text"] = ["highlight": ""]
        assertRejected(validBody(locator: locator), warningContains: "text.highlight")
    }

    // MARK: - Rect contract

    func testRejectsMissingRect() {
        assertRejected(validBody(rect: nil), warningContains: "rect")
    }

    func testRejectsNonFiniteRect() {
        assertRejected(
            validBody(rect: ["x": Double.nan, "y": 0.0, "width": 10.0, "height": 10.0]),
            warningContains: "rect"
        )
        assertRejected(
            validBody(rect: ["x": 0.0, "y": 0.0, "width": Double.infinity, "height": 10.0]),
            warningContains: "rect"
        )
    }

    func testRejectsNonPositiveRect() {
        assertRejected(
            validBody(rect: ["x": 0.0, "y": 0.0, "width": 0.0, "height": 10.0]),
            warningContains: "rect"
        )
        assertRejected(
            validBody(rect: ["x": 0.0, "y": 0.0, "width": 10.0, "height": -5.0]),
            warningContains: "rect"
        )
    }

    func testRejectsRectWithMissingFields() {
        assertRejected(
            validBody(rect: ["x": 0.0, "y": 0.0, "width": 10.0]),
            warningContains: "rect"
        )
    }

    // MARK: - Block key contract

    func testRejectsEmptyOrNonStringBlockKey() {
        assertRejected(validBody(blockKey: ""), warningContains: "blockKey")
        assertRejected(validBody(blockKey: 42), warningContains: "blockKey")
    }

    func testRejectsMissingOrUnknownTrigger() {
        assertRejected(validBody(trigger: nil), warningContains: "trigger")
        assertRejected(validBody(trigger: "long-press"), warningContains: "trigger")
        assertRejected(validBody(trigger: 42), warningContains: "trigger")
    }

    // MARK: - Frame origin check

    func testAcceptsMatchingFrameURL() throws {
        let event = try parse(
            validBody(),
            frameURL: URL(string: "http://127.0.0.1:8080/publication/chapter1.xhtml")!
        ).get()
        XCTAssertEqual(event.locator.href, AnyURL(string: "chapter1.xhtml")!)
    }

    func testRejectsFrameURLNotMatchingClaimedHref() {
        // A frame claiming another chapter's href must be dropped, even with a valid payload.
        assertRejected(
            validBody(),
            frameURL: URL(string: "http://127.0.0.1:8080/publication/chapter2.xhtml")!,
            warningContains: "does not match claimed href"
        )
    }

    func testSkipsOriginCheckWhenFrameURLUnavailable() throws {
        // WebKit not surfacing a frame URL is a WebKit limitation, not evidence of a
        // malformed message.
        _ = try parse(validBody(), frameURL: nil).get()
    }
}
