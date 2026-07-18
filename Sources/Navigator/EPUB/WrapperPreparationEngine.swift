//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared
import UIKit
import WebKit

// MARK: - Constants

/// Documented, owned constants of the wrapper preparation module.
///
/// Previously these were implicit magic numbers scattered across the preloader
/// and navigator — the 3-second replacement delay in a `DispatchQueue` call, the
/// never-retried failure path. Making them named constants here means they can be
/// referenced in tests and documentation without reverse-engineering the code.
public enum WrapperPreparationConstants {
    /// Delay after `take()` before scheduling the next warm-up, keeping the
    /// critical path of the current book open free of WebView construction
    /// overhead. A pending failure retry (see ``retryBackoffSeconds``) is also
    /// cancelled and folded into this same delay, so a backoff timer can never
    /// build a WebView concurrently inside the measured open window.
    public static let replacementDelaySeconds: TimeInterval = 3.0

    /// Maximum consecutive warm-up failures before the engine stops retrying.
    /// The counter resets on any success or on app foreground.
    public static let maxRetryAttempts: Int = 3

    /// Backoff intervals indexed by attempt number (0-based).
    /// Attempt 0 → 1 s, attempt 1 → 2 s, attempt 2 → 4 s.
    public static let retryBackoffSeconds: [TimeInterval] = [1.0, 2.0, 4.0]
}

// MARK: - Engine

/// Owns the full lifecycle of pre-warmed continuous-wrapper `WKWebView` instances:
/// construction, readiness probing, adoption by a navigator, replacement scheduling,
/// retry-with-backoff on failure, and foreground recovery.
///
/// This is the *single owner* of wrapper preparation. The navigator only *takes* a
/// warm wrapper through ``take()`` and uses ``makeWrapperWebView()`` for its cold
/// fallback — it never constructs the wrapper independently, breaking the prior
/// reciprocal dependency between ``ContinuousWrapperPreloader`` and
/// ``EPUBContinuousNavigatorViewController``.
///
/// ## Seams for testing
///
/// Internal properties ``scheduleDelay``, ``cancelScheduledDelay``,
/// ``webViewFactory``, and ``testWarmUpHandler`` are accessible via
/// `@testable import` so the retry / backoff / foreground state machine can be
/// exercised without live WebKit or real timers.
@MainActor
public final class WrapperPreparationEngine: NSObject, Loggable {
    // MARK: - Singleton

    public static let shared = WrapperPreparationEngine()

    // MARK: - Observable state (internal for @testable assertions)

    /// The mutually-exclusive lifecycle states of the warm wrapper. Replaces the
    /// prior pair of `isReady`/`isWarming` booleans, which could in principle
    /// disagree; a single value makes the three legal states explicit.
    enum State {
        case idle
        case warming
        case ready
    }

    /// The process-wide scheme-handler server backing every wrapper web view.
    /// Created eagerly (cheap — no WebKit processes involved) so
    /// ``makeWrapperWebView()`` can register it on configurations even before
    /// ``start()`` is called. Web views can only receive a scheme handler at
    /// creation, so the navigator's view model must register its publication
    /// routes on this same instance for adopted wrappers to reach them.
    let server = WebViewServer(scheme: "readium", formatSniffer: DefaultFormatSniffer())

    /// Route host shared by the wrapper assets and publication resources.
    /// A custom scheme's origin is `scheme://host`, so a single host keeps
    /// the wrapper page and its chapter iframes same-origin
    /// (`readium://continuous`), which the wrapper scripts rely on for
    /// `window.parent` access.
    public static let routePrefix = "continuous"

    /// The isolated `WKContentWorld` holding every injected script and every
    /// native message handler. Authored EPUB JS runs in the page world, which
    /// after this isolation sees neither `webkit.messageHandlers` nor
    /// `continuousWrapper`/`readium` — it cannot spoof bridge messages or
    /// drive the wrapper API through `window.parent`. Same-origin JS interop
    /// between the wrapper and chapter iframes keeps working because both
    /// sides live in this same world (guarantees pinned by
    /// `ContentWorldBridgeSemanticsTests`).
    public static let contentWorld = WKContentWorld.world(name: "cadency")

    /// Whether ``start()`` has been called. Warm-ups are gated on it so the
    /// engine never builds WebKit processes before the app opts in.
    var isStarted = false

    var warmedWebView: WKWebView?
    private(set) var state: State = .idle
    private(set) var retryCount = 0

    /// Derived flags kept so the navigator and tests read the same surface as
    /// before the ``State`` refactor.
    var isReady: Bool {
        state == .ready
    }

    var isWarming: Bool {
        state == .warming
    }

    private var retryToken: AnyObject?
    private var replacementToken: AnyObject?
    private var foregroundObserver: NSObjectProtocol?

    /// Set when ``take()`` finds a warm-up still in flight: a book open is now
    /// racing that warm-up, so if it fails, the retry is deferred to
    /// ``WrapperPreparationConstants/replacementDelaySeconds`` instead of the
    /// short backoff — otherwise the backoff timer could rebuild a WebView
    /// inside the measured open window that ``take()``'s retry cancellation
    /// exists to protect.
    private var warmingOverlapsOpen = false

    // MARK: - Injectable seams

    /// Schedules a closure to run after `delay` seconds. Returns a cancellation
    /// token understood by ``cancelScheduledDelay``.
    ///
    /// Production default: `DispatchQueue.main.asyncAfter`.
    /// Tests replace this with a controllable clock.
    var scheduleDelay: (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> AnyObject = { delay, action in
        let item = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return item as AnyObject
    }

    /// Cancels a token previously returned by ``scheduleDelay``.
    var cancelScheduledDelay: (_ token: AnyObject) -> Void = { token in
        (token as? DispatchWorkItem)?.cancel()
    }

    /// Creates a WKWebView for the wrapper. Tests replace this to avoid WebKit
    /// process spin-up. When `nil`, ``makeWrapperWebView()`` is used.
    var webViewFactory: (() -> WKWebView)?

    enum TestWarmUpResult {
        case pending
        case succeeded
        case failed(reason: String)
    }

    /// Replaces the WebKit load in tests while driving the same success and
    /// failure transitions as the production navigation delegate.
    var testWarmUpHandler: (@MainActor () -> TestWarmUpResult)?

    // MARK: - Init

    /// Creates an engine instance.
    ///
    /// - Parameter observeAppLifecycle: Pass `false` in tests to avoid
    ///   UIApplication notification registration.
    init(observeAppLifecycle: Bool = true) {
        super.init()
        if observeAppLifecycle {
            observeForeground()
        }
    }

    deinit {
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API

    /// Starts the preparation engine.
    ///
    /// Call once at app launch (from `ReadingSurfaceModule.OnCreate`). Wrapper
    /// resources are served by the engine's own ``server`` — no external HTTP
    /// server is needed.
    ///
    /// Calling again while a wrapper is warm or warming is a no-op.
    public func start() {
        isStarted = true
        warmUp()
    }

    /// Returns a fully booted wrapper WebView, or `nil` when none is ready yet.
    ///
    /// A still-warming instance is kept for the next open — the caller falls
    /// back to the cold load path. Taking one schedules a replacement warm-up
    /// after ``WrapperPreparationConstants/replacementDelaySeconds``, keeping the
    /// current book-open's critical path free of WebView construction overhead.
    public func take() -> WKWebView? {
        // A real book open is starting. Any pending failure retry must be
        // cancelled now, before it fires: its backoff timer (1/2/4 s) could
        // otherwise elapse inside the measured cold-open window and build a
        // WKWebView concurrently with the navigator's cold load. The next
        // warm-up is rescheduled off the critical path below.
        if let token = retryToken { cancelScheduledDelay(token) }
        retryToken = nil

        guard state == .ready, let webView = warmedWebView else {
            if state == .warming {
                warmingOverlapsOpen = true
            }
            scheduleReplacementWarmUp()
            return nil
        }

        warmedWebView = nil
        state = .idle
        webView.navigationDelegate = nil

        scheduleReplacementWarmUp()
        return webView
    }

    /// Schedules the next warm-up after ``WrapperPreparationConstants/replacementDelaySeconds``,
    /// replacing any previously scheduled one. Keeps WebView construction off
    /// the current open's critical path.
    private func scheduleReplacementWarmUp() {
        if let token = replacementToken { cancelScheduledDelay(token) }
        replacementToken = scheduleDelay(WrapperPreparationConstants.replacementDelaySeconds) { [weak self] in
            self?.warmUp()
        }
    }

    // MARK: - WebView factory

    /// Builds a wrapper `WKWebView` with the configuration shared by both the
    /// warm path (engine pre-warms at app launch) and the cold path (navigator
    /// creates on demand when no warm wrapper is available).
    ///
    /// This is the **single factory** — the navigator never independently
    /// constructs a wrapper WebView.
    public func makeWrapperWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(server, forURLScheme: server.scheme)
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        #if compiler(>=6.0)
            if #available(iOS 18.0, *) {
                configuration.writingToolsBehavior = .none
            }
        #endif

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.backgroundColor = .clear
        webView.isOpaque = false
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.showsVerticalScrollIndicator = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        #if DEBUG && swift(>=5.8)
            if #available(macOS 13.3, iOS 16.4, *) {
                webView.isInspectable = true
            }
        #endif

        // Give each chapter iframe the reflowable Readium API (`window.readium`)
        // by injecting the reflowable script into sub-frames only. Without this,
        // chapter documents have no `getDecorations` / selection support and the
        // wrapper's `applyDecorationsToIframe` silently no-ops. The guard
        // ensures the main wrapper frame keeps its own `window.readium`.
        if let reflowable = Self.reflowableScript {
            let subframeOnly = "if (window.top !== window.self) {\n\(reflowable)\n}"
            webView.configuration.userContentController.addUserScript(
                WKUserScript(
                    source: subframeOnly,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false,
                    in: Self.contentWorld
                )
            )
        }

        // The wrapper's own scripts are injected into the isolated world
        // rather than loaded via `<script>` tags in continuous-wrapper.html —
        // a page `<script>` runs in the page world, which cannot see the
        // world-registered message handlers. Order matters and mirrors the
        // former HTML: seed, bundle, shim.
        for source in [Self.wrapperSeedScript, Self.wrapperScript, Self.wrapperShimScript] {
            if let source {
                webView.configuration.userContentController.addUserScript(
                    WKUserScript(
                        source: source,
                        injectionTime: .atDocumentEnd,
                        forMainFrameOnly: true,
                        in: Self.contentWorld
                    )
                )
            }
        }

        return webView
    }

    /// The reflowable Readium script injected into chapter iframes. Loaded once
    /// from the bundle and reused across all wrapper WebViews.
    private static let reflowableScript: String? = bundledScript("readium-reflowable")

    /// Marks the wrapper's main frame as non-reflowable for the shared Readium
    /// script paths; formerly an inline `<script>` in continuous-wrapper.html.
    private static let wrapperSeedScript: String? =
        "window.readium = window.readium || { isFixedLayout: true };"

    private static let wrapperScript: String? = bundledScript("readium-continuous-wrapper")

    private static let wrapperShimScript: String? = bundledScript("readium-continuous-wrapper-shim")

    private static func bundledScript(_ name: String) -> String? {
        Bundle.module
            .url(forResource: name, withExtension: "js", subdirectory: "Assets/Static/scripts")
            .flatMap { try? String(contentsOf: $0) }
    }

    // MARK: - Warm-up lifecycle (internal for @testable)

    /// Attempts to warm up a wrapper WebView. No-op when already warm, already
    /// warming, or when the engine hasn't been started via ``start()``.
    @discardableResult
    func warmUp() -> Bool {
        guard state == .idle, isStarted else { return false }
        state = .warming

        if let handler = testWarmUpHandler {
            switch handler() {
            case .pending:
                break
            case .succeeded:
                warmUpDidSucceed()
            case let .failed(reason):
                warmUpDidFail(reason: reason)
            }
            return true
        }

        loadWrapperIntoFreshWebView()
        return true
    }

    /// Production path: resolves bundle resources, serves static assets, creates
    /// a WebView, and loads the wrapper HTML. On any guard failure the warming
    /// flag is cleared — no retry (the guard failures are deterministic, not
    /// transient).
    private func loadWrapperIntoFreshWebView() {
        guard
            let staticAssets = Bundle.module.resourceURL?.fileURL?
            .appendingPath("Assets/Static", isDirectory: true),
            let wrapperURL = Bundle.module.url(forResource: "continuous-wrapper", withExtension: "html", subdirectory: "Assets"),
            let html = try? String(contentsOf: wrapperURL)
        else {
            state = .idle
            return
        }

        let assetsURL = server.serve(directory: staticAssets, at: "\(Self.routePrefix)/assets")

        let webView = webViewFactory?() ?? makeWrapperWebView()
        webView.navigationDelegate = self
        // The wrapper only resolves absolute URLs, so the base URL's sole job is
        // giving the page the `readium://continuous` origin that chapter iframes
        // will be served from.
        webView.loadHTMLString(html, baseURL: assetsURL.url)
        warmedWebView = webView
    }

    /// Called when the readiness probe confirms `continuousWrapper` is defined.
    func warmUpDidSucceed() {
        state = .ready
        retryCount = 0
        warmingOverlapsOpen = false

        #if DEBUG
            diagnosticLog("warm-up succeeded — wrapper ready")
        #endif
    }

    /// Called on any warm-up failure. Discards the current WebView and schedules
    /// a retry with exponential backoff if under the attempt limit.
    func warmUpDidFail(reason: String) {
        let discarded = warmedWebView
        warmedWebView = nil
        state = .idle

        #if DEBUG
            diagnosticLog(
                "warm-up failed (attempt \(retryCount + 1)/\(WrapperPreparationConstants.maxRetryAttempts)): "
                    + "\(reason). Discarding WebView \(String(describing: discarded))"
            )
        #endif

        retryCount += 1

        guard retryCount <= WrapperPreparationConstants.maxRetryAttempts else {
            #if DEBUG
                diagnosticLog("max retries exhausted — giving up until foreground or take()")
            #endif
            return
        }

        let delay: TimeInterval
        if warmingOverlapsOpen {
            // This failure belongs to a warm-up a live book open is racing;
            // retry off the open's critical path, like a replacement would.
            warmingOverlapsOpen = false
            delay = WrapperPreparationConstants.replacementDelaySeconds
        } else {
            let backoffIndex = min(retryCount - 1, WrapperPreparationConstants.retryBackoffSeconds.count - 1)
            delay = WrapperPreparationConstants.retryBackoffSeconds[backoffIndex]
        }

        if let token = retryToken { cancelScheduledDelay(token) }
        retryToken = scheduleDelay(delay) { [weak self] in
            self?.warmUp()
        }
    }

    // MARK: - Foreground recovery

    private func observeForeground() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // NotificationCenter dispatches on .main but the closure isn't
            // @MainActor-isolated, so hop back to satisfy the actor.
            Task { @MainActor in
                self?.handleAppWillEnterForeground()
            }
        }
    }

    /// Resets the retry counter and triggers a fresh warm-up when nothing is
    /// warm or warming. Exposed as `internal` so tests can call it directly
    /// without posting a notification.
    func handleAppWillEnterForeground() {
        retryCount = 0
        warmingOverlapsOpen = false

        // Cancel any pending retry — foreground is a fresh start.
        if let token = retryToken { cancelScheduledDelay(token) }
        retryToken = nil

        if state == .idle {
            #if DEBUG
                diagnosticLog("app foregrounded with no warm wrapper — starting fresh warm-up")
            #endif
            warmUp()
        }
    }

    // MARK: - Diagnostics

    #if DEBUG
        /// Optional handler for diagnostic messages. `ReadingSurfaceView` sets
        /// this (DEBUG only) to forward engine diagnostics to the JS diagnostics
        /// event; the engine is a singleton, so the most recently mounted view
        /// wins. Forwarded to the shared `server` so its serve traces reach the
        /// same channel without additional app wiring.
        public var diagnosticHandler: ((String) -> Void)? {
            didSet {
                server.diagnosticHandler = diagnosticHandler
            }
        }

        private func diagnosticLog(_ message: String) {
            let msg = "[WrapperPreparationEngine] \(message)"
            log(.debug, msg)
            diagnosticHandler?(msg)
        }
    #endif
}

// MARK: - WKNavigationDelegate

extension WrapperPreparationEngine: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        guard webView === warmedWebView else { return }

        webView.evaluateInBridgeWorld(
            "typeof continuousWrapper !== 'undefined'"
        ) { [weak self] result in
            guard let self, webView === self.warmedWebView else { return }
            if case let .success(value) = result, (value as? Bool) == true {
                self.warmUpDidSucceed()
            } else {
                self.warmUpDidFail(reason: "readiness probe failed — continuousWrapper not defined")
            }
        }
    }

    public func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        guard webView === warmedWebView else { return }
        warmUpDidFail(reason: "didFail: \(error.localizedDescription)")
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        guard webView === warmedWebView else { return }
        warmUpDidFail(reason: "didFailProvisionalNavigation: \(error.localizedDescription)")
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === warmedWebView else { return }
        warmUpDidFail(reason: "WebContent process terminated")
    }
}
