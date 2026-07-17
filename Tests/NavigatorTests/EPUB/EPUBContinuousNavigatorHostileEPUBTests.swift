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
                      return !!(f && f.contentDocument &&
                        f.contentDocument.querySelector('p'));
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
            let probe = (try? await evaluate(
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
        init(_ description: String) { self.description = description }
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

    func chapter(_ title: String) -> String {
        let paragraphs = (1 ... 30).map { "<p>Paragraph \($0) of \(title).</p>" }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>\(title)</title></head>
        <body>
        \(hostileScript)
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
        )
    )

    return Publication(
        manifest: Manifest(
            metadata: Metadata(title: "Hostile Fixture"),
            readingOrder: [
                Link(href: "chapter1.xhtml", mediaType: .xhtml),
                Link(href: "chapter2.xhtml", mediaType: .xhtml),
            ]
        ),
        container: container
    )
}

private let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)

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
