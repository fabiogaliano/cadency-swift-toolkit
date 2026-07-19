//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import Foundation
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
            html: "<!doctype html><html><head></head><body><p>Before context words.</p><p id=target>Selected text.</p><p>After context words.</p></body></html>"
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
        let locations = try #require(body["locations"] as? [String: Any])
        let rect = try #require(body["rect"] as? [String: Any])
        #expect(text["highlight"] as? String == "Selected text.")
        #expect(text["before"] as? String == "context words.")
        #expect(text["after"] as? String == "After context words")
        #expect(locations["cssSelector"] as? String == "#target")

        let expectedRect = try #require(
            try await harness.evaluate(
                "JSON.stringify(window.getSelection().getRangeAt(0).getBoundingClientRect().toJSON())"
            ) as? String
        )
        let expected = try #require(
            try JSONSerialization.jsonObject(with: Data(expectedRect.utf8)) as? [String: Double]
        )
        for field in ["left", "top", "width", "height", "right", "bottom"] {
            #expect(rect[field] as? Double == expected[field])
        }
    }

    @Test @MainActor func reflowableSelectionSurvivesSelectorAndRectFailures() async throws {
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
            range.getBoundingClientRect = function () { throw new Error('rect failure'); };
            p.getAttribute = function () { throw new Error('selector failure'); };
            var selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            document.dispatchEvent(new Event('selectionchange'));
            """
        )
        try await harness.waitForMessage(named: "selectionChanged")
        try await harness.waitForMessage(named: "logError", count: 2)

        let body = try #require(harness.messageBodies["selectionChanged"] as? [String: Any])
        let text = try #require(body["text"] as? [String: Any])
        #expect(text["highlight"] as? String == "Selected text.")
        #expect(body["rect"] == nil)
        #expect(body["locations"] == nil)
    }

    @Test @MainActor func reflowableBundleClassifiesInteractiveAncestors() async throws {
        let script = try #require(WrapperPreparationEngine.bundledScript("readium-reflowable"))
        let harness = BundleHarness(
            script: "window.readium = window.readium || {};\n\(script)",
            html: """
            <!doctype html><html><head></head><body>
            <p id="ordinary"><span id="ordinary-child">Ordinary text</span></p>
            <p><a href="#"><em id="link-child">Linked text</em></a></p>
            <div contenteditable="true"><span id="editable-child">Editable text</span></div>
            </body></html>
            """
        )
        try await harness.load()

        let outcomes = try #require(
            try await harness.evaluate(
                """
                (function () {
                  function activate(id) {
                    var rect = document.getElementById(id).getBoundingClientRect();
                    return readium.activateBlockAtLocalPoint(
                      rect.left + Math.max(1, rect.width / 2),
                      rect.top + Math.max(1, rect.height / 2)
                    );
                  }
                  readium.link = { href: 'chapter.xhtml' };
                  return [
                    activate('ordinary-child'),
                    activate('link-child'),
                    activate('editable-child'),
                    readium.activateBlockAtLocalPoint(-1, -1),
                    readium.activateBlockAtLocalPoint(319, 639)
                  ];
                })()
                """
            ) as? [String]
        )

        #expect(outcomes == ["posted", "none", "none", "none", "none"])
        try await harness.waitForMessage(named: "blockActivated")
        let body = try #require(harness.messageBodies["blockActivated"] as? [String: Any])
        let locator = try #require(body["locator"] as? [String: Any])
        let locations = try #require(locator["locations"] as? [String: Any])
        #expect(locations["cssSelector"] as? String == "#ordinary")
    }

    @Test @MainActor func reflowableBundlePostsImageTargetMetadata() async throws {
        let script = try #require(WrapperPreparationEngine.bundledScript("readium-reflowable"))
        let capturePointerListener = """
        window.__capturedPointerDown = null;
        (function () {
          var addEventListener = document.addEventListener.bind(document);
          document.addEventListener = function (name, listener, options) {
            if (name === 'pointerdown' && window.__capturedPointerDown === null) {
              window.__capturedPointerDown = listener;
            }
            return addEventListener(name, listener, options);
          };
        })();
        """
        let harness = BundleHarness(
            script: "\(capturePointerListener)\nwindow.readium = window.readium || {};\n\(script)",
            html: """
            <!doctype html><html><head></head><body>
            <figure><img id="alt-first" width="20" height="20" src="https://example.com/first.png" alt=" Alt caption " title="Title caption" aria-label=" Image label "><figcaption>Figure caption</figcaption></figure>
            <img id="alt-empty" width="20" height="20" src="https://example.com/empty.png" alt="" title="Suppressed title">
            <svg id="svg-title" width="20" height="20"><title>SVG title</title><desc>Suppressed description</desc></svg>
            <svg id="svg-desc" width="20" height="20"><desc>SVG description</desc></svg>
            <figure><img id="figure-caption" width="20" height="20" src="https://example.com/figure.png"><figcaption>Figure caption</figcaption></figure>
            </body></html>
            """
        )
        try await harness.load()
        let listenerReady = try await harness.evaluate(
            "window.dispatchEvent(new Event('DOMContentLoaded')); " +
                "typeof window.__capturedPointerDown === 'function';"
        )
        #expect(listenerReady as? Bool == true)

        let cases: [(id: String, caption: String?)] = [
            ("alt-first", "Alt caption"),
            ("alt-empty", nil),
            ("svg-title", "SVG title"),
            ("svg-desc", "SVG description"),
            ("figure-caption", "Figure caption"),
        ]
        for (index, item) in cases.enumerated() {
            _ = try await harness.evaluate(
                """
                readium.link = { href: 'chapter.xhtml' };
                window.__capturedPointerDown({
                  isTrusted: true,
                  target: document.getElementById('\(item.id)'),
                  pointerId: \(index + 1),
                  pointerType: 'touch',
                  isPrimary: true,
                  clientX: 10,
                  clientY: 10,
                  buttons: 1,
                  defaultPrevented: false,
                  altKey: false,
                  ctrlKey: false,
                  shiftKey: false,
                  metaKey: false
                });
                """
            )
            try await harness.waitForMessage(named: "pointerEventReceived", count: index + 1)

            let body = try #require(harness.messageBodies["pointerEventReceived"] as? [String: Any])
            let target = try #require(body["targetElement"] as? [String: Any])
            if let caption = item.caption {
                #expect(target["caption"] as? String == caption)
            } else {
                #expect(target["caption"] is NSNull)
            }
            if item.id == "alt-first" {
                #expect(target["accessibilityLabel"] as? String == "Image label")
            }
            if item.id == "svg-title" {
                #expect(target["src"] is NSNull)
                #expect((target["html"] as? String)?.contains("<svg") == true)
            }
        }

        let body = try #require(harness.messageBodies["pointerEventReceived"] as? [String: Any])
        let target = try #require(body["targetElement"] as? [String: Any])
        #expect(target["tag"] as? String == "img")
        #expect(target["src"] as? String == "https://example.com/figure.png")
        #expect(target["resourceHref"] as? String == "chapter.xhtml")
        #expect(target["cssSelector"] as? String == "#figure-caption")
        let frame = try #require(target["frame"] as? [String: Any])
        #expect((frame["width"] as? Double ?? 0) > 0)
        #expect((frame["height"] as? Double ?? 0) > 0)
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
        webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 640),
            configuration: configuration
        )
        super.init()
        configuration.userContentController.add(self, name: "spreadLoadStarted")
        configuration.userContentController.add(self, name: "spreadLoaded")
        configuration.userContentController.add(self, name: "selectionChanged")
        configuration.userContentController.add(self, name: "logError")
        configuration.userContentController.add(self, name: "blockActivated")
        configuration.userContentController.add(self, name: "pointerEventReceived")
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

    func waitForMessage(named name: String, count: Int = 1) async throws {
        for _ in 0 ..< 100 {
            if messages.filter({ $0 == name }).count >= count {
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
