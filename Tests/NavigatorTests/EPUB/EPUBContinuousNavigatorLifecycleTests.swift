//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import Testing
import WebKit

/// Regression tests for the navigator leak: `WKUserContentController` retains
/// its script message handlers and `UIGestureRecognizer` its targets, so
/// registering the navigator directly created retain cycles through the web
/// view that made `deinit` unreachable — every book switch stranded a
/// navigator, its wrapper web view, and its publication route.
struct EPUBContinuousNavigatorLifecycleTests {
    @Test @MainActor func deallocatesOnceReleased() async throws {
        weak var navigator: EPUBContinuousNavigatorViewController?
        weak var webView: WKWebView?

        try autoreleasepool {
            let strongNavigator = try EPUBContinuousNavigatorViewController(
                publication: reflowablePublication(),
                initialLocation: nil
            )
            // viewDidLoad forms the WebKit references under test: the 13
            // message handlers and the double-tap recognizer target.
            strongNavigator.loadViewIfNeeded()
            navigator = strongNavigator
            webView = findWebView(in: strongNavigator.view)
        }

        #expect(webView != nil, "setupWebView() should have installed a wrapper web view")

        // The open kicks off async work (positions load, wrapper load,
        // wrapper init scripts) that transiently retains the navigator;
        // poll until it drains.
        for _ in 0 ..< 100 {
            if navigator == nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(navigator == nil, "the navigator must deallocate once its owner releases it")
        #expect(webView == nil, "the wrapper web view must die with its navigator")
    }
}

// MARK: - Helpers

@MainActor private func reflowablePublication() -> Publication {
    Publication(
        manifest: Manifest(
            metadata: Metadata(title: "Reflowable"),
            readingOrder: [
                Link(href: "chapter1.xhtml", mediaType: .xhtml),
                Link(href: "chapter2.xhtml", mediaType: .xhtml),
            ]
        )
    )
}

@MainActor private func findWebView(in view: UIView) -> WKWebView? {
    var queue: [UIView] = [view]
    while !queue.isEmpty {
        let candidate = queue.removeFirst()
        if let webView = candidate as? WKWebView {
            return webView
        }
        queue.append(contentsOf: candidate.subviews)
    }
    return nil
}
