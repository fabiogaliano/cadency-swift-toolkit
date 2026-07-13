//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import XCTest

class EPUBContinuousNavigatorScriptTests: XCTestCase {
    private typealias Nav = EPUBContinuousNavigatorViewController

    func testRoutesLoadedResourcesCSSToWrapper() {
        let script = #"readium.setCSSProperties({"--USER__fontSize":"140%"});"#
        XCTAssertEqual(
            Nav.continuousWrapperScript(for: script, in: .loadedResources),
            #"continuousWrapper.setCSSProperties({"--USER__fontSize":"140%"});"#
        )
    }

    func testIgnoresResourceScopedCSSRatherThanBroadcastingIt() {
        let script = #"readium.setCSSProperties({"--USER__appearance":"readium-night-on"});"#
        XCTAssertNil(
            Nav.continuousWrapperScript(for: script, in: .resource(href: AnyURL(string: "chapter1.xhtml")!))
        )
    }

    func testPreservesJSONPayloadVerbatim() {
        let json = #"{"--USER__fontSize":"90%","--USER__appearance":null,"--RS__colCount":"1"}"#
        XCTAssertEqual(
            Nav.continuousWrapperScript(for: "readium.setCSSProperties(\(json));", in: .loadedResources),
            "continuousWrapper.setCSSProperties(\(json));"
        )
    }

    func testIgnoresCurrentResourceScope() {
        let script = #"readium.setCSSProperties({"--USER__fontSize":"140%"});"#
        XCTAssertNil(Nav.continuousWrapperScript(for: script, in: .currentResource))
    }

    func testIgnoresUnknownReflowableCall() {
        // Only setCSSProperties is meaningful to re-target; anything else must
        // not be blindly rewritten to a wrapper method that may not exist.
        XCTAssertNil(Nav.continuousWrapperScript(for: "readium.scrollToId('x');", in: .loadedResources))
    }
}
