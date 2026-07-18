//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import XCTest

@MainActor
final class EPUBNavigatorViewModelTests: XCTestCase {
    func testScriptBlockingProxiesRemotePublicationResources() {
        let server = WebViewServer(scheme: "readium", formatSniffer: DefaultFormatSniffer())
        let model = EPUBNavigatorViewModel(
            publication: remotePublication(),
            readingOrder: [],
            config: .init(),
            sharedServer: server,
            routePrefix: WrapperPreparationEngine.routePrefix,
            proxiesRemoteResources: true
        )

        XCTAssertTrue(
            model.publicationBaseURL.string.hasPrefix("readium://\(WrapperPreparationEngine.routePrefix)/pub/"),
            "Script blocking must serve remote resources through the local route so its CSP reaches every document."
        )
    }

    func testAllowedRemoteScriptsKeepTheRemotePublicationBaseURL() {
        let server = WebViewServer(scheme: "readium", formatSniffer: DefaultFormatSniffer())
        let model = EPUBNavigatorViewModel(
            publication: remotePublication(),
            readingOrder: [],
            config: .init(),
            sharedServer: server,
            routePrefix: WrapperPreparationEngine.routePrefix
        )

        XCTAssertEqual(model.publicationBaseURL.string, "https://example.com/books/")
    }

    private func remotePublication() -> Publication {
        Publication(
            manifest: Manifest(
                metadata: Metadata(title: "Remote"),
                links: [Link(href: "https://example.com/books/manifest.json", rel: .`self`)]
            )
        )
    }
}
