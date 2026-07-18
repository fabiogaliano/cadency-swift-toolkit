//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import Testing
import UIKit
import WebKit

/// End-to-end bridge-isolation guarantees (S1) in the real continuous
/// navigator wiring — not the generic WebKit semantics
/// (`ContentWorldBridgeSemanticsTests`) but the actual handlers, wrapper, and
/// chapter serving.
///
/// A chapter authored to attack the bridge (reaches for every message handler,
/// grabs `window.parent.continuousWrapper`, dispatches synthetic gestures)
/// must fail on two independent layers: the `script-src 'none'` CSP stops the
/// authored script from running at all, and — even with scripts allowed — the
/// page world where authored JS lives has no access to the world-registered
/// handlers or the wrapper API.
///
/// The CSP claim is also checked for a scripted SVG content document. The
/// HTML-only `<meta>` injection cannot reach SVG, and a CSP does not inherit
/// into framed documents fetched over the scheme, so the chapter embeds the
/// SVG in an iframe — only the response-header CSP on the SVG's own response
/// can stop its script.
///
/// The authored script records what it saw into DOM attributes on the chapter's
/// `<html>`. The DOM is shared across content worlds (only JS scopes are
/// isolated), so the harness reads those attributes back through
/// `iframe.contentDocument` from the bridge world without needing the chapter
/// frame's page-world `WKFrameInfo`.
@Suite(.serialized)
struct EPUBContinuousNavigatorHostileEPUBTests {
    @Test @MainActor func cspStopsAuthoredScriptsFromRunning() async throws {
        let harness = try await Harness(allowsAuthoredScripts: false)
        defer { harness.tearDown() }

        let ran = try await harness.chapterAttribute("data-hostile-ran")
        #expect(ran == nil, "the script-src 'none' CSP must stop the authored chapter script from running")

        // The harness already waited for the SVG document to load (its static
        // marker attribute), so an absent `ran` flag means the script was
        // blocked, not that the document never arrived.
        #expect(
            try await harness.svgAttribute("data-hostile-ran") == nil,
            "the response-header CSP must stop scripts in SVG content documents, which the HTML-only <meta> cannot reach"
        )

        #expect(harness.spy.blockActivations.isEmpty)
        #expect(harness.spy.taps.isEmpty)
        #expect(harness.navigator.currentSelection == nil, "a spoofed selection must not surface as a real selection")
    }

    @Test @MainActor func authoredScriptsCannotReachTheBridge() async throws {
        // Scripts explicitly allowed (CSP off) so the authored script runs and
        // actually attempts the attack — isolating the content-world defense
        // from the CSP defense.
        let harness = try await Harness(allowsAuthoredScripts: true)
        defer { harness.tearDown() }

        let ran = try await harness.chapterAttribute("data-hostile-ran")
        #expect(ran == "1", "with scripts allowed the authored script must run, or the attack check is vacuous")

        #expect(
            try await harness.svgAttribute("data-hostile-ran") == "1",
            "with scripts allowed the SVG script must run, or the SVG CSP check is vacuous"
        )

        #expect(
            try await harness.chapterAttribute("data-hostile-handlers") == "absent",
            "authored page-world JS must not see webkit.messageHandlers"
        )
        #expect(
            try await harness.chapterAttribute("data-hostile-wrapper") == "absent",
            "authored JS must not reach the wrapper API through window.parent"
        )
        #expect(
            try await harness.chapterAttribute("data-hostile-reached") == "0",
            "no spoof attempt found a live bridge to post on"
        )

        // And nothing it did surfaced as a real navigator event.
        #expect(harness.spy.blockActivations.isEmpty)
        #expect(harness.spy.taps.isEmpty)
        #expect(harness.navigator.currentSelection == nil, "a spoofed selection must not surface as a real selection")
    }

    @Test @MainActor func liveBundleBuildsAndPostsBlockActivation() async throws {
        let harness = try await Harness(allowsAuthoredScripts: false)
        defer { harness.tearDown() }

        let result = try await harness.activateFirstParagraphBlock()
        #expect(result == "posted")
        try await harness.waitForBlockActivation()

        let activation = try #require(harness.spy.blockActivations.first)
        #expect(activation.locator.href.string == "chapter1.xhtml")
        #expect(activation.locator.text.highlight == "Paragraph 1 of Chapter 1.")
    }

    @Test @MainActor func liveBundlePostsSelectionFromChapter() async throws {
        let harness = try await Harness(allowsAuthoredScripts: false)
        defer { harness.tearDown() }

        try await harness.selectFirstParagraph()
        try await harness.waitForSelection()

        #expect(harness.navigator.currentSelection?.locator.text.highlight == "Paragraph 1 of Chapter 1.")
    }

    @Test @MainActor func liveBundleRendersDecorationThroughWrapperShim() async throws {
        let harness = try await Harness(allowsAuthoredScripts: false)
        defer { harness.tearDown() }

        let href = try #require(AnyURL(string: "chapter1.xhtml"))
        let locator = Locator(
            href: href,
            mediaType: .xhtml,
            locations: .init(
                otherLocations: ["cssSelector": .string("body > p:nth-of-type(1)")]
            ),
            text: .init(highlight: "Paragraph 1 of Chapter 1.")
        )
        harness.navigator.apply(
            decorations: [Decoration(id: "live-decoration", locator: locator, style: .highlight())],
            in: "live-bundle"
        )

        try await harness.waitForDecoration()
    }

    // MARK: - Harness

    @MainActor
    private final class Harness {
        let navigator: EPUBContinuousNavigatorViewController
        let webView: WKWebView
        let spy = DelegateSpy()
        private let window: UIWindow
        private let diagnostics = DiagnosticsLog()

        final class DiagnosticsLog {
            var lines: [String] = []
        }

        init(allowsAuthoredScripts: Bool) async throws {
            navigator = try EPUBContinuousNavigatorViewController(
                publication: hostilePublication(),
                initialLocation: nil,
                config: .init(allowsAuthoredScripts: allowsAuthoredScripts)
            )
            navigator.delegate = spy
            let log = diagnostics
            navigator.diagnosticHandler = { log.lines.append($0) }
            window = UIWindow(frame: viewport)
            window.rootViewController = navigator
            window.makeKeyAndVisible()
            navigator.view.frame = viewport
            navigator.view.layoutIfNeeded()

            guard let webView = findWebView(in: navigator.view) else {
                throw HarnessError("no wrapper web view installed")
            }
            self.webView = webView

            // The first WebKit process of a fresh simulator run can take well
            // over a minute to spin up.
            try await poll(timeout: 150, description: "chapter iframe ready") {
                let ready = try await self.evaluate(
                    """
                    (function () {
                      if (typeof continuousWrapper === 'undefined') return false;
                      var f = document.querySelector('iframe');
                      if (!(f && f.contentDocument &&
                        f.contentDocument.querySelector('p'))) return false;
                      var svg = f.contentDocument.querySelector('iframe');
                      return !!(svg && svg.contentDocument &&
                        svg.contentDocument.documentElement.getAttribute('data-hostile-svg'));
                    })()
                    """
                )
                return (ready as? Bool) == true
            }
            // Give the authored script (when allowed) a beat to run and attack.
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        func tearDown() {
            window.isHidden = true
            window.rootViewController = nil
        }

        func activateFirstParagraphBlock() async throws -> String? {
            try await evaluate(
                """
                (function () {
                  var f = document.querySelector('iframe.chapter-iframe');
                  var p = f && f.contentDocument && f.contentDocument.querySelector('p');
                  if (!p) return 'missing-paragraph';
                  var fr = f.getBoundingClientRect();
                  var pr = p.getBoundingClientRect();
                  return continuousWrapper.activateBlockAtPoint(
                    fr.left + pr.left + Math.min(10, pr.width / 2),
                    fr.top + pr.top + Math.min(10, pr.height / 2)
                  );
                })()
                """
            ) as? String
        }

        func waitForBlockActivation() async throws {
            try await poll(timeout: 10, description: "block activation message") {
                !self.spy.blockActivations.isEmpty
            }
        }

        func selectFirstParagraph() async throws {
            _ = try await evaluate(
                """
                (function () {
                  var f = document.querySelector('iframe.chapter-iframe');
                  var doc = f && f.contentDocument;
                  var p = doc && doc.querySelector('p');
                  if (!p) return false;
                  var range = doc.createRange();
                  range.selectNodeContents(p);
                  var selection = f.contentWindow.getSelection();
                  selection.removeAllRanges();
                  selection.addRange(range);
                  doc.dispatchEvent(new Event('selectionchange'));
                  return true;
                })()
                """
            )
        }

        func waitForSelection() async throws {
            try await poll(timeout: 10, description: "selection bridge message") {
                self.navigator.currentSelection != nil
            }
        }

        func waitForDecoration() async throws {
            try await poll(timeout: 10, description: "decoration rendered in chapter") {
                let rendered = try await self.evaluate(
                    """
                    (function () {
                      var f = document.querySelector('iframe.chapter-iframe');
                      return !!(f && f.contentDocument &&
                        f.contentDocument.querySelector('[data-style="highlight"]'));
                    })()
                    """
                )
                return (rendered as? Bool) == true
            }
        }

        /// Reads an attribute the authored script wrote on the chapter's
        /// `<html>`. Runs in the bridge world, reaching the shared DOM through
        /// `iframe.contentDocument`.
        func chapterAttribute(_ name: String) async throws -> String? {
            let result = try await evaluate(
                """
                (function () {
                  var f = document.querySelector('iframe');
                  if (!f || !f.contentDocument) return null;
                  return f.contentDocument.documentElement.getAttribute('\(name)');
                })()
                """
            )
            if result is NSNull { return nil }
            return result as? String
        }

        /// Reads an attribute the SVG's script wrote on its own root, reached
        /// through the shared DOM: chapter iframe → embedded SVG iframe.
        func svgAttribute(_ name: String) async throws -> String? {
            let result = try await evaluate(
                """
                (function () {
                  var f = document.querySelector('iframe');
                  if (!f || !f.contentDocument) return null;
                  var svg = f.contentDocument.querySelector('iframe');
                  if (!svg || !svg.contentDocument) return null;
                  return svg.contentDocument.documentElement.getAttribute('\(name)');
                })()
                """
            )
            if result is NSNull { return nil }
            return result as? String
        }

        func evaluate(_ script: String) async throws -> Any? {
            try await withCheckedThrowingContinuation { continuation in
                webView.evaluateJavaScript(
                    script,
                    in: nil,
                    in: WrapperPreparationEngine.contentWorld
                ) { result in
                    switch result {
                    case let .success(value): continuation.resume(returning: value)
                    case let .failure(error): continuation.resume(throwing: error)
                    }
                }
            }
        }

        private func poll(
            timeout: TimeInterval,
            description: String,
            until condition: () async throws -> Bool
        ) async throws {
            let deadline = Date(timeIntervalSinceNow: timeout)
            while Date() < deadline {
                if try await condition() { return }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            let probe = await (try? evaluate(
                """
                (function () {
                  var f = document.querySelector('iframe');
                  return JSON.stringify({
                    wrapper: typeof continuousWrapper,
                    iframes: document.querySelectorAll('iframe').length,
                    hasDoc: !!(f && f.contentDocument),
                    ps: (f && f.contentDocument) ? f.contentDocument.querySelectorAll('p').length : -1
                  });
                })()
                """
            )) as? String ?? "n/a"
            let trace = diagnostics.lines.suffix(6).joined(separator: " | ")
            throw HarnessError("timed out waiting for \(description) — probe=\(probe) trace=\(trace)")
        }
    }

    private struct HarnessError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }
}

// MARK: - Delegate spy

@MainActor final class DelegateSpy: EPUBContinuousNavigatorDelegate {
    var blockActivations: [EPUBContinuousNavigatorViewController.BlockActivationEvent] = []
    var taps: [CGPoint] = []

    func navigator(_: EPUBContinuousNavigatorViewController, didActivateBlock event: EPUBContinuousNavigatorViewController.BlockActivationEvent) {
        blockActivations.append(event)
    }

    func navigator(_: VisualNavigator, didTapAt point: CGPoint) {
        taps.append(point)
    }

    func navigator(_: Navigator, presentError _: NavigatorError) {}
}

// MARK: - Fixture

@MainActor private func hostilePublication() -> Publication {
    // The authored chapter probes every bridge surface and records what it saw
    // in DOM attributes, then fires synthetic gestures the wrapper listeners
    // would consume if it could counterfeit user input.
    // The document is served as XHTML, so the script body — which contains `<`
    // and `&&` — must be CDATA-wrapped or the whole document fails to parse.
    let hostileScript = """
    <script>
    //<![CDATA[
      (function () {
        var html = document.documentElement;
        html.setAttribute('data-hostile-ran', '1');
        var reached = '0';
        try {
          var mh = window.webkit && window.webkit.messageHandlers;
          html.setAttribute('data-hostile-handlers', mh ? 'present' : 'absent');
          if (mh) {
            var names = ['blockActivated','selectionChanged','tap','decorationActivated',
              'pointerEventReceived','keyEventReceived','progressionChanged','chapterMounted',
              'spreadLoaded','log','logError'];
            for (var i = 0; i < names.length; i++) {
              if (mh[names[i]]) { reached = '1'; try { mh[names[i]].postMessage({ spoof: true }); } catch (e) {} }
            }
          }
        } catch (e) {
          html.setAttribute('data-hostile-handlers', 'threw');
        }
        try {
          var w = window.parent && window.parent.continuousWrapper;
          html.setAttribute('data-hostile-wrapper', w ? 'present' : 'absent');
          if (w) { reached = '1'; }
        } catch (e) {
          html.setAttribute('data-hostile-wrapper', 'threw');
        }
        html.setAttribute('data-hostile-reached', reached);
        try {
          // A full synthetic tap sequence: without the isTrusted gate in the
          // gesture listeners, the click would post a real `tap` message.
          var p = document.querySelector('p') || document.body;
          p.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, isPrimary: true, clientX: 10, clientY: 10 }));
          p.dispatchEvent(new PointerEvent('pointerup', { bubbles: true, isPrimary: true, clientX: 10, clientY: 10 }));
          p.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX: 10, clientY: 10 }));
        } catch (e) {}
      })();
    //]]>
    </script>
    """

    // A scripted SVG content document. The static `data-hostile-svg` marker
    // proves the document loaded and parsed even when its script is blocked.
    let hostileSVG = """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" data-hostile-svg="static">
      <rect width="100" height="100" fill="#eee"/>
      <script>document.documentElement.setAttribute('data-hostile-ran', '1');</script>
    </svg>
    """

    func chapter(_ title: String) -> String {
        let paragraphs = (1 ... 30).map { "<p>Paragraph \($0) of \(title).</p>" }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>\(title)</title></head>
        <body>
        \(hostileScript)
        <iframe src="hostile.svg" style="width:100px;height:100px"></iframe>
        \(paragraphs)
        </body>
        </html>
        """
    }

    let container = CompositeContainer(
        SingleResourceContainer(
            resource: DataResource(string: chapter("Chapter 1")),
            at: AnyURL(string: "chapter1.xhtml")!
        ),
        SingleResourceContainer(
            resource: DataResource(string: chapter("Chapter 2")),
            at: AnyURL(string: "chapter2.xhtml")!
        ),
        SingleResourceContainer(
            resource: DataResource(string: hostileSVG),
            at: AnyURL(string: "hostile.svg")!
        )
    )

    return Publication(
        manifest: Manifest(
            metadata: Metadata(title: "Hostile Fixture"),
            readingOrder: [
                Link(href: "chapter1.xhtml", mediaType: .xhtml),
                Link(href: "chapter2.xhtml", mediaType: .xhtml),
            ],
            resources: [
                Link(href: "hostile.svg", mediaType: .svg),
            ]
        ),
        container: container
    )
}

private let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)
