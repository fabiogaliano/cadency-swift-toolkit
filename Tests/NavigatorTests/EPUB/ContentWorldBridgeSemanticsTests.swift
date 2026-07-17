//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import Testing
import WebKit

/// Pins the WebKit `WKContentWorld` guarantees the bridge-isolation design
/// (S1) is built on. If any of these fail on a new iOS/WebKit version, the
/// isolation architecture — not just an implementation detail — is broken:
///
/// 1. A script injected into a named world in a same-origin iframe publishes
///    globals that the *same world* in the main frame can reach through
///    `contentWindow` (the wrapper ↔ chapter interop path).
/// 2. The page world (where authored EPUB JS runs) sees neither the world's
///    globals nor its message handlers, so it cannot post spoofed bridge
///    messages.
/// 3. DOM events cross worlds — and synthetic ones arrive `isTrusted ==
///    false`, which is what the gesture path keys on to reject counterfeit
///    "user" input.
/// 4. A document CSP of `script-src 'none'` kills authored scripts but not
///    world-injected user scripts, so chapter docs can be locked down without
///    breaking the engine.
@Suite(.serialized)
struct ContentWorldBridgeSemanticsTests {
    @Test @MainActor func crossFrameWorldSemantics() async throws {
        let world = WKContentWorld.world(name: "cadency-spike")
        let harness = Harness(worldName: "cadency-spike", userScripts: [
            // World script for every frame. Sets a world-visible flag first so
            // "script didn't run" and "postMessage didn't deliver" are
            // distinguishable failures.
            WKUserScript(
                source: """
                window.__worldTag = (window.top === window.self) ? "main" : "sub";
                if (window.top === window.self) {
                  document.addEventListener("spike-evt", (e) => {
                    window.webkit.messageHandlers.spikeChannel.postMessage(
                      "evt:" + (e.isTrusted ? "trusted" : "untrusted")
                    );
                  });
                }
                try {
                  window.webkit.messageHandlers.spikeChannel.postMessage(
                    "world-ready:" + window.__worldTag
                  );
                } catch (e) {
                  window.__worldPostFailed = String(e);
                }
                """,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false,
                in: world
            ),
        ])

        // Authored scripts (main frame and same-origin iframe) both attempt to
        // post on the world-registered channel, exactly like a hostile EPUB.
        // The iframe is a real same-origin document served over the custom
        // scheme, mirroring how chapter iframes load in production.
        try await harness.load(pages: [
            "/main.html": """
            <!DOCTYPE html><html><body>
            <script>
              try { window.webkit.messageHandlers.spikeChannel.postMessage("spoof-main"); } catch (e) {}
            </script>
            <iframe src="/chapter.html"></iframe>
            </body></html>
            """,
            "/chapter.html": """
            <!DOCTYPE html><html><body>
            <script>
              try { window.webkit.messageHandlers.spikeChannel.postMessage("spoof-iframe"); } catch (e) {}
              window.__authoredIframeRan = true;
            </script>
            <p>chapter</p>
            </body></html>
            """,
        ])

        // Sanity: the document is ours and the world script actually ran.
        let domProbe = try await harness.evaluate(
            "document.querySelectorAll('iframe').length", in: .page
        )
        #expect(domProbe as? Int == 1, "the loaded document must contain the test iframe")

        let worldRan = try await harness.evaluate("typeof window.__worldTag", in: world)
        #expect(worldRan as? String == "string", "the world user script must have run in the main frame")

        let postFailure = try await harness.evaluate("window.__worldPostFailed ?? null", in: world)
        #expect(postFailure == nil || postFailure is NSNull, "world postMessage must not throw")

        try await harness.poll("world scripts ready in both frames") {
            harness.collector.messages.contains("world-ready:main")
                && harness.collector.messages.contains("world-ready:sub")
        }

        // 1. Same world, cross frame: the main frame reaches the iframe's
        // world globals through contentWindow.
        let crossFrameTag = try await harness.evaluate(
            "document.querySelector('iframe').contentWindow.__worldTag", in: world
        )
        #expect(crossFrameTag as? String == "sub")

        // 2. The page world sees neither world globals nor the world handler,
        // and the authored spoof attempts never reached the collector.
        let pageWorldTag = try await harness.evaluate("typeof window.__worldTag", in: .page)
        #expect(pageWorldTag as? String == "undefined")

        let pageWorldHandler = try await harness.evaluate(
            "String(typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.spikeChannel))",
            in: .page
        )
        #expect(pageWorldHandler as? String == "undefined")

        let authoredRan = try await harness.evaluate(
            "document.querySelector('iframe').contentWindow.__authoredIframeRan === true",
            in: .page
        )
        #expect(authoredRan as? Bool == true, "the authored iframe script must actually have run for the spoof check to mean anything")
        #expect(!harness.collector.messages.contains("spoof-main"))
        #expect(!harness.collector.messages.contains("spoof-iframe"))

        // 3. Synthetic DOM events cross into the world but arrive untrusted.
        _ = try await harness.evaluate(
            "document.dispatchEvent(new CustomEvent('spike-evt')); true", in: .page
        )
        try await harness.poll("synthetic event observed by world listener") {
            harness.collector.messages.contains("evt:untrusted")
        }
        #expect(!harness.collector.messages.contains("evt:trusted"))
    }

    @Test @MainActor func cspBlocksAuthoredScriptsButNotWorldScripts() async throws {
        let world = WKContentWorld.world(name: "cadency-spike-csp")
        let harness = Harness(worldName: "cadency-spike-csp", userScripts: [
            WKUserScript(
                source: """
                window.__worldRanUnderCSP = true;
                try {
                  window.webkit.messageHandlers.spikeChannel.postMessage("world-under-csp");
                } catch (e) {
                  window.__worldPostFailed = String(e);
                }
                """,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true,
                in: world
            ),
        ])

        try await harness.load(pages: [
            "/main.html": """
            <!DOCTYPE html><html><head>
            <meta http-equiv="Content-Security-Policy" content="script-src 'none'">
            </head><body>
            <script>window.__authoredRan = true;</script>
            </body></html>
            """,
        ])

        let worldRan = try await harness.evaluate("window.__worldRanUnderCSP === true", in: world)
        #expect(worldRan as? Bool == true, "the world user script must run despite the document CSP")

        try await harness.poll("world script posted despite document CSP") {
            harness.collector.messages.contains("world-under-csp")
        }

        let authoredRan = try await harness.evaluate("typeof window.__authoredRan", in: .page)
        #expect(authoredRan as? String == "undefined", "script-src 'none' must block authored inline scripts")
    }
}

// MARK: - Helpers

private struct HarnessError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

@MainActor private final class MessageCollector: NSObject, WKScriptMessageHandler {
    private(set) var messages: [String] = []

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? String {
            messages.append(body)
        }
    }
}

/// Serves the test documents over a custom scheme — the same mechanics the
/// production wrapper and chapter iframes use (`loadHTMLString` with an https
/// base URL stalls in the UIApplication-less xctest environment).
private final class SpikeSchemeHandler: NSObject, WKURLSchemeHandler {
    let pages: [String: String]

    init(pages: [String: String]) {
        self.pages = pages
    }

    func webView(_: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let url = urlSchemeTask.request.url!
        guard let html = pages[url.path] else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let data = Data(html.utf8)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8", "Content-Length": String(data.count)]
        )!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_: WKWebView, stop _: WKURLSchemeTask) {}
}

/// Owns the web view, keeps it alive for the duration of the test, and makes
/// load completion and content-process death explicit instead of inferred
/// from timeouts.
@MainActor private final class Harness: NSObject, WKNavigationDelegate {
    let collector = MessageCollector()
    private let userScripts: [WKUserScript]
    private let worldName: String
    private var schemeHandler: SpikeSchemeHandler?
    private(set) var webView: WKWebView!
    private var didFinishLoad = false
    private var loadError: Error?
    private var processDied = false

    init(worldName: String, userScripts: [WKUserScript]) {
        self.worldName = worldName
        self.userScripts = userScripts
        super.init()
    }

    func load(pages: [String: String]) async throws {
        let handler = SpikeSchemeHandler(pages: pages)
        schemeHandler = handler

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: "spike")
        configuration.userContentController.add(
            collector,
            contentWorld: WKContentWorld.world(name: worldName),
            name: "spikeChannel"
        )
        for script in userScripts {
            configuration.userContentController.addUserScript(script)
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self

        webView.load(URLRequest(url: URL(string: "spike://test/main.html")!))
        // The first WKWebView of a fresh simulator run can take over a minute
        // to spin up its WebKit processes; the timeout must absorb that.
        try await poll("navigation didFinish", timeout: 120) {
            if let error = self.loadError {
                throw HarnessError("navigation failed: \(error)")
            }
            return self.didFinishLoad
        }
    }

    func evaluate(_ javaScript: String, in world: WKContentWorld) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(javaScript, in: nil, in: world) { result in
                switch result {
                case let .success(value):
                    continuation.resume(returning: value)
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func poll(
        _ what: String,
        timeout: TimeInterval = 30,
        until condition: @MainActor () throws -> Bool
    ) async throws {
        for _ in 0 ..< Int(timeout * 10) {
            if processDied {
                throw HarnessError("web content process died while waiting for: \(what)")
            }
            if try condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw HarnessError("timed out waiting for: \(what)")
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        didFinishLoad = true
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
