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

/// Mid-chapter cold-reopen: the element-exact locator captured for persistence
/// must describe the paragraph actually visible at the top of the *outer*
/// viewport, and feeding it back as the initial location must land on that
/// same paragraph. The chapter iframes are as tall as their content, so a
/// visibility walk measured against the iframe's own window sees the whole
/// chapter as "visible" and anchors to its first block instead.
@Suite(.serialized)
struct EPUBContinuousNavigatorColdRestoreTests {
    @Test @MainActor func exactLocatorAnchorsTheParagraphAtTheOuterViewportTop() async throws {
        let harness = try await Harness(initialLocation: nil)
        defer { harness.tearDown() }

        try await harness.goToMidChapter()
        let groundTruth = try await harness.paragraphAtViewportTop()
        #expect(groundTruth.hasPrefix("PARA-"), "ground-truth probe should hit a fixture paragraph, got: \(groundTruth)")
        #expect(groundTruth != paragraphText(1), "the jump must move away from the chapter start")

        let locator = try #require(await harness.navigator.firstVisibleElementLocator())
        let highlight = try #require(locator.text.highlight, "the exact locator must carry text context")

        #expect(
            highlight.trimmingCharacters(in: .whitespacesAndNewlines) == groundTruth,
            "exact locator anchors \"\(highlight.prefix(40))…\" but the paragraph at the viewport top is \"\(groundTruth.prefix(40))…\""
        )
    }

    @Test @MainActor func exactLocatorKeepsTheOutgoingChapterAtABoundary() async throws {
        let harness = try await Harness(initialLocation: nil)
        defer { harness.tearDown() }

        try await harness.goToChapterBoundary()
        let groundTruth = try await harness.paragraphAtViewportTop()
        let locator = try #require(await harness.navigator.firstVisibleElementLocator())

        #expect(locator.href.string == "chapter1.xhtml")
        #expect(
            locator.text.highlight?.trimmingCharacters(in: .whitespacesAndNewlines) == groundTruth,
            "the exact locator must retain the outgoing chapter text at the viewport top"
        )
    }

    @Test @MainActor func syntheticChapterInputCannotCancelLandingCorrection() async throws {
        let harness = try await Harness(initialLocation: nil)
        defer { harness.tearDown() }

        try await harness.startMidChapterJump()
        let syntheticInputPosition = try await harness.scrollAfterSyntheticChapterInput()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let finalPosition = try await harness.currentScrollY()

        #expect(
            abs(finalPosition - syntheticInputPosition) > 2,
            "a synthetic chapter event cancelled the landing correction at \(syntheticInputPosition)"
        )
    }

    @Test @MainActor func nativeInputStopsLandingCorrection() async throws {
        let harness = try await Harness(initialLocation: nil)
        defer { harness.tearDown() }

        try await harness.startMidChapterJump()
        let userPosition = try await harness.scrollAfterNativeInput()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let finalPosition = try await harness.currentScrollY()

        #expect(
            abs(finalPosition - userPosition) <= 2,
            "landing correction moved the reader after native input (\(userPosition) → \(finalPosition))"
        )
    }

    @Test @MainActor func coldReopenLandsOnTheSameVisibleParagraph() async throws {
        var exactLocator: Locator?
        var groundTruth: String?

        // First session: read to mid-chapter, capture the persistence locator,
        // then tear the navigator down like an app kill would.
        do {
            let harness = try await Harness(initialLocation: nil)
            defer { harness.tearDown() }
            try await harness.goToMidChapter()
            groundTruth = try await harness.paragraphAtViewportTop()
            exactLocator = await harness.navigator.firstVisibleElementLocator()
        }

        let saved = try #require(exactLocator)
        let expectedParagraph = try #require(groundTruth)
        #expect(expectedParagraph != paragraphText(1), "the jump must move away from the chapter start")
        #expect(
            saved.text.highlight?.trimmingCharacters(in: .whitespacesAndNewlines) == expectedParagraph,
            "the locator to persist must already anchor the visible paragraph; selector=\(saved.locations.cssSelector ?? "nil")"
        )

        // Cold reopen: restore through initialLocation, the same path the app's
        // initialLocator prop takes through the deferred-jump state machine.
        let reopened = try await Harness(initialLocation: saved)
        defer { reopened.tearDown() }
        try await reopened.waitForScrollSettle()

        let landed = try await reopened.paragraphAtViewportTop()
        let debug = try await reopened.debugState(selector: saved.locations.cssSelector)
        #expect(
            landed == expectedParagraph,
            "cold reopen landed on \"\(landed.prefix(40))…\" but the reader was at \"\(expectedParagraph.prefix(40))…\" — \(debug)"
        )
    }

    @Test @MainActor func coldReopenWithLargerFontLandsOnTheSameParagraph() async throws {
        var exactLocator: Locator?
        var groundTruth: String?
        var originalHeight = 0.0

        do {
            let harness = try await Harness(initialLocation: nil)
            defer { harness.tearDown() }
            try await harness.goToMidChapter()
            groundTruth = try await harness.paragraphAtViewportTop()
            originalHeight = try await harness.firstChapterHeight()
            exactLocator = await harness.navigator.firstVisibleElementLocator()
        }

        let saved = try #require(exactLocator)
        let expectedParagraph = try #require(groundTruth)

        // A bigger font reflows the chapter, so the persisted pixel progression
        // now points at different text — only the element anchor can land right.
        let reopened = try await Harness(
            initialLocation: saved,
            preferences: EPUBPreferences(fontSize: 1.6)
        )
        defer { reopened.tearDown() }
        try await reopened.waitForScrollSettle()

        let reflowedHeight = try await reopened.firstChapterHeight()
        #expect(
            reflowedHeight > originalHeight * 1.2,
            "the font-size preference must actually reflow the chapter (\(originalHeight) → \(reflowedHeight))"
        )

        let landed = try await reopened.paragraphAtViewportTop()
        let debug = try await reopened.debugState(selector: saved.locations.cssSelector)
        #expect(
            landed == expectedParagraph,
            "reflowed cold reopen landed on \"\(landed.prefix(40))…\" but the reader was at \"\(expectedParagraph.prefix(40))…\" — \(debug)"
        )
    }

    // MARK: - Harness

    @MainActor
    private final class Harness {
        private final class DiagnosticsLog {
            var lines: [String] = []
        }

        let navigator: EPUBContinuousNavigatorViewController
        let webView: WKWebView
        private let window: UIWindow
        private let log: DiagnosticsLog
        private var diagnostics: [String] { log.lines }

        init(initialLocation: Locator?, preferences: EPUBPreferences = .empty) async throws {
            let log = DiagnosticsLog()
            self.log = log
            navigator = try EPUBContinuousNavigatorViewController(
                publication: fixturePublication(),
                initialLocation: initialLocation,
                config: .init(preferences: preferences)
            )
            navigator.diagnosticHandler = { line in
                log.lines.append(line)
            }
            window = UIWindow(frame: viewport)
            window.rootViewController = navigator
            window.makeKeyAndVisible()
            navigator.view.frame = viewport
            navigator.view.layoutIfNeeded()

            guard let webView = findWebView(in: navigator.view) else {
                throw HarnessError("no wrapper web view installed")
            }
            self.webView = webView

            // A go() issued while the navigator is still `.loading` is only
            // deferred; wait until the load completed (the completeLoading
            // trace) and both chapter iframes can answer locator questions.
            try await poll(timeout: 30, description: "load complete + chapters ready") {
                guard self.diagnostics.contains(where: { $0.contains("completeLoading") }) else {
                    return false
                }
                let ready = try await self.evaluate(
                    """
                    (function () {
                      if (typeof continuousWrapper === 'undefined') return false;
                      var iframes = document.querySelectorAll('iframe');
                      if (iframes.length < 2) return false;
                      for (var i = 0; i < iframes.length; i++) {
                        if (!iframes[i].contentWindow || !iframes[i].contentWindow.readium) return false;
                      }
                      return true;
                    })()
                    """
                )
                return (ready as? Bool) == true
            }
        }

        func tearDown() {
            window.isHidden = true
            window.rootViewController = nil
        }

        func startMidChapterJump() async throws {
            let locator = Locator(
                href: AnyURL(string: "chapter1.xhtml")!,
                mediaType: .xhtml,
                locations: .init(progression: 0.55)
            )
            guard await navigator.go(to: locator, options: NavigatorGoOptions(animated: false)) else {
                throw HarnessError("go(to: mid-chapter) was rejected")
            }
            // go() can return with the jump still deferred: the readiness poll
            // sees `readium` before the chapter's load event, so the precise
            // scroll (and the landing correction) may only start once the
            // chapter finishes loading. Wait for the goToScrolled trace so an
            // interrupt targets an active correction, not a pending jump.
            try await poll(timeout: 10, description: "goTo precise scroll") {
                self.diagnostics.contains { $0.contains("goToScrolled") }
            }
        }

        func goToMidChapter() async throws {
            try await startMidChapterJump()
            try await waitForScrollSettle()
            let scrollY = try await currentScrollY()
            guard scrollY > Double(viewport.height) else {
                throw HarnessError("mid-chapter jump did not scroll (scrollY=\(scrollY))")
            }
        }

        func goToChapterBoundary() async throws {
            // Require the boundary to hold on two consecutive samples with
            // identical geometry: a chapter-height settle between this poll and
            // the ground-truth read can otherwise shift the viewport into a
            // spacer, where no paragraph resolves at the top.
            var previous = "unsampled"
            try await poll(timeout: 5, description: "chapter boundary") {
                let result = try await self.evaluate(
                    """
                    (function () {
                      var frames = document.querySelectorAll('iframe');
                      if (frames.length < 2) return null;
                      var first = frames[0];
                      var firstRect = first.getBoundingClientRect();
                      var firstTop = firstRect.top + window.scrollY;
                      window.scrollTo(0, firstTop + firstRect.height - 250);

                      var outgoing = first.getBoundingClientRect();
                      var incoming = frames[1].getBoundingClientRect();
                      var outgoingCoverage = outgoing.bottom;
                      var incomingCoverage = window.innerHeight - Math.max(0, incoming.top);
                      var atBoundary = outgoingCoverage > 0 &&
                        outgoingCoverage < window.innerHeight / 2 &&
                        incomingCoverage > outgoingCoverage;
                      if (!atBoundary) return null;
                      return window.scrollY + '/' + document.documentElement.scrollHeight;
                    })()
                    """
                )
                guard let sample = result as? String else {
                    previous = "unsampled"
                    return false
                }
                defer { previous = sample }
                return sample == previous
            }
        }

        func scrollAfterSyntheticChapterInput() async throws -> Double {
            // Dispatch into the chapter under the viewport center. Events never
            // bubble from an iframe to the outer window, so this reaches the
            // chapter listener directly.
            let result = try await evaluate(
                """
                (function () {
                  var frames = document.querySelectorAll('iframe');
                  var mid = window.innerHeight / 2;
                  for (var i = 0; i < frames.length; i++) {
                    var rect = frames[i].getBoundingClientRect();
                    if (rect.top > mid || rect.bottom <= mid) continue;
                    if (!frames[i].contentDocument) return null;
                    frames[i].contentDocument.dispatchEvent(
                      new MouseEvent('mousedown', { bubbles: true })
                    );
                    window.scrollBy(0, 300);
                    return window.scrollY;
                  }
                  return null;
                })()
                """
            )
            guard let scrollY = result as? Double else {
                throw HarnessError("could not dispatch synthetic chapter input")
            }
            return scrollY
        }

        func scrollAfterNativeInput() async throws -> Double {
            let result = try await evaluate(
                """
                (function () {
                  continuousWrapper.cancelLandingCorrectionFromUserInput();
                  window.scrollBy(0, 300);
                  return window.scrollY;
                })()
                """
            )
            guard let scrollY = result as? Double else {
                throw HarnessError("could not cancel landing correction from native input")
            }
            return scrollY
        }

        func currentScrollY() async throws -> Double {
            try await evaluate("window.scrollY") as? Double ?? 0
        }

        /// Waits until the outer scroll position is nonzero-stable — covers both
        /// the explicit jump and the deferred initial-location restore.
        func waitForScrollSettle() async throws {
            var previous = "unsampled"
            do {
                try await poll(timeout: 30, description: "scroll settle") {
                    // Sample the document height too: a landing correction can
                    // hold the scroll steady while chapter heights still grow.
                    let sample = try await self.evaluate(
                        "window.scrollY + '/' + document.documentElement.scrollHeight"
                    ) as? String ?? "unsampled"
                    defer { previous = sample }
                    return sample == previous && !sample.hasPrefix("0/")
                }
            } catch {
                let debug = (try? await debugState(selector: nil)) ?? "n/a"
                throw HarnessError("timed out waiting for scroll settle — \(debug)")
            }
        }

        /// The trimmed text of the first paragraph still visible at the top of
        /// the outer viewport — the ground truth an exact locator must agree
        /// with. "First whose bottom edge passes the viewport top" mirrors how
        /// a restore re-aligns the anchored element, so a straddling paragraph
        /// counts as the current one on both sides of the round trip.
        func paragraphAtViewportTop() async throws -> String {
            let result = try await evaluate(
                """
                (function () {
                  var iframes = document.querySelectorAll('iframe');
                  for (var i = 0; i < iframes.length; i++) {
                    var rect = iframes[i].getBoundingClientRect();
                    if (rect.top > 0 || rect.bottom <= 0) continue;
                    var doc = iframes[i].contentDocument;
                    if (!doc) return null;
                    var paragraphs = doc.querySelectorAll('p');
                    for (var j = 0; j < paragraphs.length; j++) {
                      if (paragraphs[j].getBoundingClientRect().bottom > -rect.top) {
                        return paragraphs[j].textContent.trim();
                      }
                    }
                    return null;
                  }
                  return null;
                })()
                """
            )
            guard let text = result as? String else {
                throw HarnessError("no paragraph found at the viewport top")
            }
            return text
        }

        /// Snapshot of the geometry a failure needs to explain itself: outer
        /// scroll position, chapter boxes, where the saved selector resolves,
        /// and the navigator's goto trace.
        func debugState(selector: String?) async throws -> String {
            let selectorJSON: String
            if let selector,
               let data = try? JSONSerialization.data(withJSONObject: [selector]),
               let json = String(data: data, encoding: .utf8)
            {
                selectorJSON = "\(json)[0]"
            } else {
                selectorJSON = "null"
            }
            let state = try await evaluate(
                """
                (function () {
                  var out = {
                    scrollY: window.scrollY,
                    docHeight: document.documentElement.scrollHeight,
                    chapters: [],
                  };
                  var iframes = document.querySelectorAll('iframe');
                  for (var i = 0; i < iframes.length; i++) {
                    var rect = iframes[i].getBoundingClientRect();
                    out.chapters.push({ top: rect.top + window.scrollY, height: rect.height });
                  }
                  var selector = \(selectorJSON);
                  if (selector && iframes[0] && iframes[0].contentDocument) {
                    var el = iframes[0].contentDocument.querySelector(selector);
                    out.selector = el
                      ? { top: el.getBoundingClientRect().top, text: el.textContent.slice(0, 8) }
                      : "unresolved";
                  }
                  return JSON.stringify(out);
                })()
                """
            )
            let trace = diagnostics.suffix(6).joined(separator: " | ")
            return "\(state as? String ?? "n/a") trace: \(trace)"
        }

        func firstChapterHeight() async throws -> Double {
            let height = try await evaluate(
                "document.querySelector('iframe').getBoundingClientRect().height"
            )
            return height as? Double ?? 0
        }

        private func evaluate(_ script: String) async throws -> Any? {
            // Wrapper scripts and their state live in the isolated bridge
            // world, not the page world.
            try await withCheckedThrowingContinuation { continuation in
                webView.evaluateJavaScript(script, in: nil, in: WrapperPreparationEngine.contentWorld) { result in
                    switch result {
                    case let .success(value):
                        continuation.resume(returning: value)
                    case let .failure(error):
                        continuation.resume(throwing: error)
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
            throw HarnessError("timed out waiting for \(description)")
        }
    }

    private struct HarnessError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

// MARK: - Fixture

private func paragraphText(_ index: Int) -> String {
    "PARA-\(String(format: "%03d", index)) the quiet library keeps its own steady time, and every shelf remembers the hand that filled it."
}

@MainActor private func fixturePublication() -> Publication {
    func chapter(_ title: String) -> String {
        let paragraphs = (1 ... 200)
            .map { "<p>\(paragraphText($0))</p>" }
            .joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
          <title>\(title)</title>
          <style>p { margin: 0; padding: 6px 0; font-size: 1rem; line-height: 1.5; }</style>
        </head>
        <body>
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
            metadata: Metadata(title: "Cold Restore Fixture"),
            readingOrder: [
                Link(href: "chapter1.xhtml", mediaType: .xhtml),
                Link(href: "chapter2.xhtml", mediaType: .xhtml),
            ]
        ),
        container: container
    )
}

private let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)
