//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import Testing
import WebKit

/// Executes the committed Vite artifacts in a real WKWebView. Source-level
/// tests cannot prove that the IIFE globals initialize in WebKit.
@Suite(.serialized)
struct EPUBBundleRuntimeTests {
    @Test @MainActor func fixedBundleInitializesReadium() async throws {
        let script = try #require(WrapperPreparationEngine.bundledScript("readium-fixed"))
        let harness = BundleHarness(
            script: script,
            html: "<!doctype html><html><head></head><body><p>Fixed page</p></body></html>"
        )
        try await harness.load()

        let initialized = try await harness.evaluate(
            "window.readium && window.readium.isFixedLayout === true"
        )
        #expect(initialized as? Bool == true)
        #expect(harness.messages.contains("spreadLoadStarted"))
    }

    @Test @MainActor func reflowableBundlePostsSelection() async throws {
        let script = try #require(WrapperPreparationEngine.bundledScript("readium-reflowable"))
        let harness = BundleHarness(
            script: "window.readium = window.readium || {};\n\(script)",
            html: "<!doctype html><html><head></head><body><p id=target>Selected text.</p></body></html>"
        )
        try await harness.load()

        _ = try await harness.evaluate(
            """
            readium.link = { href: 'chapter.xhtml' };
            var p = document.getElementById('target');
            var range = document.createRange();
            range.selectNodeContents(p);
            var selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            document.dispatchEvent(new Event('selectionchange'));
            """
        )
        try await harness.waitForMessage(named: "selectionChanged")

        let body = try #require(harness.messageBodies["selectionChanged"] as? [String: Any])
        let text = try #require(body["text"] as? [String: Any])
        #expect(text["highlight"] as? String == "Selected text.")
    }

    @Test @MainActor func fixedWrapperBundlesInitializeTheirPublicAPI() async throws {
        let cases = [
            (
                "readium-fixed-wrapper-one",
                """
                <!doctype html><html><head><meta name="viewport" content=""></head>
                <body><iframe id="page"></iframe></body></html>
                """
            ),
            (
                "readium-fixed-wrapper-two",
                """
                <!doctype html><html><head><meta name="viewport" content=""></head><body>
                <div class="viewport"><iframe id="page-left"></iframe></div>
                <div class="viewport"><iframe id="page-right"></iframe></div>
                <div class="viewport"><iframe id="page-center"></iframe></div>
                </body></html>
                """
            ),
        ]

        for (name, html) in cases {
            let script = try #require(WrapperPreparationEngine.bundledScript(name))
            let harness = BundleHarness(script: script, html: html)
            try await harness.load()

            let initialized = try await harness.evaluate(
                "typeof spread === 'object' && typeof spread.load === 'function' && " +
                    "typeof spread.eval === 'function' && typeof spread.setViewport === 'function'"
            )
            #expect(initialized as? Bool == true, "\(name) must initialize the spread API")
        }
    }
}

@MainActor private final class BundleHarness: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let html: String
    private var didFinish = false
    private var loadError: Error?
    private var processDied = false
    private(set) var messages: [String] = []
    private(set) var messageBodies: [String: Any] = [:]
    private let webView: WKWebView

    init(script: String, html: String) {
        self.html = html
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "spreadLoadStarted")
        configuration.userContentController.add(self, name: "spreadLoaded")
        configuration.userContentController.add(self, name: "selectionChanged")
        webView.navigationDelegate = self
    }

    func load() async throws {
        webView.loadHTMLString(html, baseURL: nil)
        for _ in 0 ..< 1200 {
            if let loadError {
                throw loadError
            }
            if processDied {
                throw BundleHarnessError("web content process died")
            }
            if didFinish {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw BundleHarnessError("timed out waiting for bundle WKWebView")
    }

    func evaluate(_ script: String) async throws -> Any? {
        try await webView.evaluateJavaScript(script)
    }

    func waitForMessage(named name: String) async throws {
        for _ in 0 ..< 100 {
            if messages.contains(name) {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw BundleHarnessError("timed out waiting for \(name)")
    }

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        messages.append(message.name)
        messageBodies[message.name] = message.body
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        didFinish = true
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        loadError = error
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        loadError = error
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        processDied = true
    }
}

private struct BundleHarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}
