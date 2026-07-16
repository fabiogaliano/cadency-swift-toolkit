//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumInternal
import ReadiumShared
import UIKit
import WebKit

/// Delegate protocol for the continuous scroll EPUB navigator.
@MainActor public protocol EPUBContinuousNavigatorDelegate: VisualNavigatorDelegate, SelectableNavigatorDelegate {
    /// Called when a chapter is mounted in the continuous scroll view.
    func navigator(_ navigator: EPUBContinuousNavigatorViewController, didMountChapterAt index: Int, href: AnyURL)

    /// Called to provide custom HTML for chapter separators.
    /// Return nil to use no separator, or provide custom HTML content.
    func navigator(_ navigator: EPUBContinuousNavigatorViewController, separatorHTMLForChapterAt index: Int, title: String?) -> String?

    /// Called when the viewport is updated.
    func navigator(_ navigator: EPUBContinuousNavigatorViewController, viewportDidChange viewport: EPUBContinuousNavigatorViewController.Viewport?)

    /// Called to customize WebView user scripts.
    func navigator(_ navigator: EPUBContinuousNavigatorViewController, setupUserScripts userContentController: WKUserContentController)

    /// Called when the user double-taps a semantic block (paragraph, heading, list item, …)
    /// in a chapter iframe. The event carries only a `Locator`, a viewport rectangle, and an
    /// optional transient block key — never DOM nodes, ranges, or other Readium internals.
    func navigator(_ navigator: EPUBContinuousNavigatorViewController, didActivateBlock event: EPUBContinuousNavigatorViewController.BlockActivationEvent)
}

public extension EPUBContinuousNavigatorDelegate {
    func navigator(_ navigator: EPUBContinuousNavigatorViewController, didMountChapterAt index: Int, href: AnyURL) {}

    func navigator(_ navigator: EPUBContinuousNavigatorViewController, separatorHTMLForChapterAt index: Int, title: String?) -> String? {
        guard index > 0, let title = title else { return nil }
        return """
        <div style="padding: 20px; text-align: center; font-family: -apple-system, sans-serif; color: #666; border-top: 1px solid #ddd; border-bottom: 1px solid #ddd; margin: 20px 0;">
            <strong>\(title)</strong>
        </div>
        """
    }

    func navigator(_ navigator: EPUBContinuousNavigatorViewController, viewportDidChange viewport: EPUBContinuousNavigatorViewController.Viewport?) {}

    func navigator(_ navigator: EPUBContinuousNavigatorViewController, setupUserScripts userContentController: WKUserContentController) {}

    func navigator(_ navigator: EPUBContinuousNavigatorViewController, didActivateBlock event: EPUBContinuousNavigatorViewController.BlockActivationEvent) {}
}

/// A navigator for reflowable EPUB publications using continuous vertical scrolling.
///
/// This navigator renders the entire publication as a vertically scrollable document
/// by embedding spine items as iframes within a single WKWebView wrapper document.
/// Unlike the paginated `EPUBNavigatorViewController`, this provides a true continuous
/// scrolling experience across the full publication.
///
/// ## Key Features
/// - Continuous vertical scrolling across all chapters
/// - Sliding window of mounted iframes for memory efficiency
/// - Scroll anchoring to prevent visual jumps during layout changes
/// - Full support for locators, decorations, and navigation
///
/// ## Non-goals
/// - Fixed-layout (FXL) EPUB support (use `EPUBNavigatorViewController` instead)
open class EPUBContinuousNavigatorViewController: InputObservableViewController,
    VisualNavigator, SelectableNavigator, DecorableNavigator,
    Configurable, Loggable
{
    public enum Error: Swift.Error {
        /// The provided publication is restricted.
        case publicationRestricted
        /// The publication is fixed-layout, which is not supported.
        case fixedLayoutNotSupported
        /// Failed to serve the publication with the HTTP server.
        case serverFailure(Swift.Error)
        /// The wrapper document failed to load.
        case wrapperLoadFailed
    }

    /// Configuration for the continuous scroll navigator.
    public struct Configuration {
        /// Initial set of setting preferences.
        public var preferences: EPUBPreferences

        /// Provides default fallback values and ranges for the user settings.
        public var defaults: EPUBDefaults

        /// Editing actions which will be displayed in the default text selection menu.
        public var editingActions: [EditingAction]

        /// Number of chapters to preload before the current visible chapter.
        public var prefetchBehind: Int

        /// Number of chapters to preload after the current visible chapter.
        public var prefetchAhead: Int

        /// Maximum number of chapters to keep mounted simultaneously.
        public var maxMountedChapters: Int

        /// Default estimated height for chapters before they're loaded (in points).
        public var defaultChapterHeight: CGFloat

        /// Supported HTML decoration templates.
        public var decorationTemplates: [Decoration.Style.Id: HTMLDecorationTemplate]

        /// Additional font families available in preferences.
        public var fontFamilyDeclarations: [AnyHTMLFontFamilyDeclaration]

        /// Readium CSS reading system settings.
        public var readiumCSSRSProperties: CSSRSProperties

        /// Logs state changes when true.
        public var debugState: Bool

        public init(
            preferences: EPUBPreferences = .empty,
            defaults: EPUBDefaults = EPUBDefaults(),
            editingActions: [EditingAction] = EditingAction.defaultActions,
            prefetchBehind: Int = 1,
            prefetchAhead: Int = 2,
            maxMountedChapters: Int = 7,
            defaultChapterHeight: CGFloat = 800,
            decorationTemplates: [Decoration.Style.Id: HTMLDecorationTemplate] = HTMLDecorationTemplate.defaultTemplates(),
            fontFamilyDeclarations: [AnyHTMLFontFamilyDeclaration] = [],
            readiumCSSRSProperties: CSSRSProperties = CSSRSProperties(),
            debugState: Bool = false
        ) {
            self.preferences = preferences
            self.defaults = defaults
            self.editingActions = editingActions
            self.prefetchBehind = prefetchBehind
            self.prefetchAhead = prefetchAhead
            self.maxMountedChapters = maxMountedChapters
            self.defaultChapterHeight = defaultChapterHeight
            self.decorationTemplates = decorationTemplates
            self.fontFamilyDeclarations = fontFamilyDeclarations
            self.readiumCSSRSProperties = readiumCSSRSProperties
            self.debugState = debugState
        }
    }

    // MARK: - Public Properties

    public weak var delegate: EPUBContinuousNavigatorDelegate?

    /// The publication being rendered.
    public var publication: Publication {
        viewModel.publication
    }

    /// Currently applied settings.
    public var settings: EPUBSettings {
        viewModel.settings
    }

    /// Current location in the publication.
    public private(set) var currentLocation: Locator?

    /// Information about the visible portion of the publication.
    public private(set) var viewport: Viewport? {
        didSet {
            if oldValue != viewport {
                delegate?.navigator(self, viewportDidChange: viewport)
            }
        }
    }

    /// Information about the visible portion of the publication.
    public struct Viewport: Equatable {
        /// Index of the most visible chapter.
        public var activeChapterIndex: Int
        /// Visible reading order resources.
        public var readingOrder: [AnyURL]
        /// Range of visible scroll progressions.
        public var progressions: [AnyURL: ClosedRange<Double>]
        /// Range of visible positions.
        public var positions: ClosedRange<Int>?
    }

    /// A validated double-tap block activation, carried from chapter iframe JavaScript through
    /// this navigator to the delegate. Positional identity only — never a durable block ID.
    public struct BlockActivationEvent: Equatable {
        /// Locator for the activated block, anchored by `locations.cssSelector` with
        /// `text.highlight`/`before`/`after` set for `TextQuoteAnchor` resolution.
        public var locator: Locator

        /// The block's range rectangle in top-level WKWebView viewport coordinates.
        public var rect: CGRect

        /// Transient identity for toggling the same block on/off, derived by the JS layer from
        /// at least the chapter href and CSS selector. Not a persisted identifier.
        public var blockKey: String?

        public init(locator: Locator, rect: CGRect, blockKey: String?) {
            self.locator = locator
            self.rect = rect
            self.blockKey = blockKey
        }
    }

    // MARK: - Private Properties

    private let viewModel: EPUBNavigatorViewModel
    private let config: Configuration
    private let readingOrder: [Link]
    private let loadPositionsByReadingOrder: () async -> ReadResult<[[Locator]]>
    private var positionsByReadingOrder: [[Locator]] = []

    private var webView: WKWebView!
    private var isWrapperLoaded = false

    private lazy var blockDoubleTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: webKitBridge, action: #selector(WebKitBridge.didRecognizeBlockDoubleTap(_:)))
        recognizer.numberOfTapsRequired = 2
        recognizer.numberOfTouchesRequired = 1
        recognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
        ]
        recognizer.delegate = self
        return recognizer
    }()

    #if DEBUG
        public var diagnosticHandler: ((String) -> Void)?
    #endif

    /// Navigation state.
    private enum State: Equatable {
        case initializing
        case loading(pendingLocator: Locator?)
        case idle
        case jumping(pendingLocator: Locator)

        mutating func transition(_ event: Event) -> Bool {
            switch (self, event) {
            case let (_, .load(locator)):
                self = .loading(pendingLocator: locator)
            case (.loading, .loaded):
                self = .idle
            case (.loading, _):
                return false
            case let (.idle, .jump(locator)):
                self = .jumping(pendingLocator: locator)
            case (.jumping, .jumped):
                self = .idle
            case (.jumping, .jump):
                return false
            default:
                return false
            }
            return true
        }
    }

    private var state: State = .initializing {
        didSet {
            if config.debugState {
                log(.debug, "* \(state)")
            }
        }
    }

    /// Currently active chapter index.
    private var activeChapterIndex: Int = 0

    // MARK: - Decorations

    private var decorations: [String: [DiffableDecoration]] = [:]
    private var decorationCallbacks: [String: [DecorableNavigator.OnActivatedCallback]] = [:]

    // MARK: - Initialization

    /// Creates a new continuous scroll navigator.
    ///
    /// - Parameters:
    ///   - publication: Reflowable EPUB publication to render.
    ///   - initialLocation: Starting location in the publication.
    ///   - config: Navigator configuration.
    /// - Throws: `Error.publicationRestricted` if the publication is DRM-protected without
    ///           proper unlocking, or `Error.fixedLayoutNotSupported` if the publication
    ///           is fixed-layout.
    public convenience init(
        publication: Publication,
        initialLocation: Locator?,
        config: Configuration = .init()
    ) throws {
        guard !publication.isRestricted else {
            throw Error.publicationRestricted
        }

        guard publication.metadata.layout != .fixed else {
            throw Error.fixedLayoutNotSupported
        }

        // Create a modified config that forces scroll mode
        var epubConfig = EPUBNavigatorViewController.Configuration(
            preferences: config.preferences,
            defaults: config.defaults,
            editingActions: config.editingActions,
            decorationTemplates: config.decorationTemplates,
            fontFamilyDeclarations: config.fontFamilyDeclarations,
            readiumCSSRSProperties: config.readiumCSSRSProperties,
            debugState: config.debugState
        )

        // Force scroll mode for continuous navigation
        epubConfig.preferences.scroll = true

        // Publication resources must be reachable from pre-warmed web views,
        // whose scheme handler is the engine's shared server — so the view
        // model registers its routes there instead of on a private server.
        let viewModel = EPUBNavigatorViewModel(
            publication: publication,
            readingOrder: publication.readingOrder,
            config: epubConfig,
            sharedServer: WrapperPreparationEngine.shared.server,
            routePrefix: WrapperPreparationEngine.routePrefix
        )

        self.init(
            viewModel: viewModel,
            config: config,
            initialLocation: initialLocation,
            readingOrder: publication.readingOrder,
            positionsByReadingOrder: publication.positionsByReadingOrder
        )
    }

    private init(
        viewModel: EPUBNavigatorViewModel,
        config: Configuration,
        initialLocation: Locator?,
        readingOrder: [Link],
        positionsByReadingOrder: @escaping () async -> ReadResult<[[Locator]]>
    ) {
        self.viewModel = viewModel
        self.config = config
        currentLocation = initialLocation
        self.readingOrder = readingOrder
        loadPositionsByReadingOrder = positionsByReadingOrder

        super.init(nibName: nil, bundle: nil)

        viewModel.delegate = self
        viewModel.editingActions.delegate = self

        setupLegacyInputCallbacks(
            onTap: { [weak self] point in
                guard let self else { return }
                self.delegate?.navigator(self, didTapAt: point)
            },
            onPressKey: { [weak self] event in
                guard let self else { return }
                self.delegate?.navigator(self, didPressKey: event)
            },
            onReleaseKey: { [weak self] event in
                guard let self else { return }
                self.delegate?.navigator(self, didReleaseKey: event)
            }
        )
    }

    @available(*, unavailable)
    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        pendingLocationUpdateTask?.cancel()
        disableJSMessages()
        #if DEBUG
            diagnosticHandler?("[lifetime] navigator-deinit")
        #endif
    }

    // MARK: - View Lifecycle

    override open func viewDidLoad() {
        super.viewDidLoad()

        view.accessibilityTraits.insert(.causesPageTurn)
        view.backgroundColor = settings.effectiveBackgroundColor.uiColor

        setupWebView()

        Task {
            await initialize()
        }
    }

    /// True when this navigator adopted a pre-warmed wrapper whose page is already
    /// booted, so `initialize()` skips the wrapper load entirely.
    private var adoptedWarmWrapper = false

    private func setupWebView() {
        if let warmed = WrapperPreparationEngine.shared.take() {
            webView = warmed
            adoptedWarmWrapper = true

        } else {
            webView = WrapperPreparationEngine.shared.makeWrapperWebView()
        }
        webView.frame = view.bounds
        webView.navigationDelegate = self

        view.addSubview(webView)
        webView.addGestureRecognizer(blockDoubleTapRecognizer)

        enableJSMessages()

        delegate?.navigator(self, setupUserScripts: webView.configuration.userContentController)
    }

    private func didRecognizeBlockDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        // Web-view coordinates are the wrapper document's top-viewport coordinates: the wrapper
        // fills the web view and never scrolls its own viewport (chapters scroll inside it).
        let topViewportPoint = recognizer.location(in: webView)
        guard topViewportPoint.x.isFinite, topViewportPoint.y.isFinite else { return }

        webView.evaluateJavaScript(
            "continuousWrapper.activateBlockAtPoint(\(topViewportPoint.x), \(topViewportPoint.y));"
        ) { [weak self] result, error in
            if let error {
                self?.log(.error, DebugError("Failed to activate the double-tapped block.", cause: error))
                return
            }
            #if DEBUG
                // result: "posted" (block activated) or a miss mode
                // ("none"/"no-chapter-at-point"/"bad-point").
                self?.diagnosticHandler?(
                    "block-double-tap point=(\(topViewportPoint.x), \(topViewportPoint.y)) result=\(result as? String ?? "unknown")"
                )
            #endif
        }
    }

    private func initialize() async {
        #if DEBUG
            let positionsStart = Date().timeIntervalSince1970 * 1000
        #endif
        do {
            positionsByReadingOrder = try await loadPositionsByReadingOrder().get()
        } catch {
            log(.error, DebugError("Failed to load positions.", cause: error))
        }
        #if DEBUG
            let positionsEnd = Date().timeIntervalSince1970 * 1000
            diagnosticHandler?(
                "[open-trace] positionsLoaded t=\(Int(positionsEnd)) dt=\(Int(positionsEnd - positionsStart))ms resources=\(positionsByReadingOrder.count)"
            )
        #endif

        if adoptedWarmWrapper {
            // The pre-warmed page already finished loading and passed the wrapper
            // probe, so go straight to spine initialization. Later wrapper reloads
            // (CSS invalidation, process termination) still use `loadWrapper()`.
            adoptedWarmWrapper = false
            _ = on(.load(currentLocation))
            wrapperDidLoad()
        } else {
            await loadWrapper()
        }
    }

    private func loadWrapper() async {
        guard let wrapperURL = Bundle.module.url(forResource: "continuous-wrapper", withExtension: "html", subdirectory: "Assets") else {
            log(.error, "Could not find continuous-wrapper.html")
            return
        }

        do {
            var html = try String(contentsOf: wrapperURL)
            html = html.replacingOccurrences(of: "{{ASSETS_URL}}", with: viewModel.assetsBaseURL.string)

            log(.debug, "Loading continuous wrapper baseURL=\(viewModel.publicationBaseURL.string) assetsURL=\(viewModel.assetsBaseURL.string)")

            webView.loadHTMLString(html, baseURL: viewModel.publicationBaseURL.url)

            _ = on(.load(currentLocation))
        } catch {
            log(.error, "Failed to load wrapper HTML: \(error)")
        }
    }

    // MARK: - State Management

    @discardableResult
    private func on(_ event: Event) -> Bool {
        assert(Thread.isMainThread)

        if config.debugState {
            log(.debug, "-> on \(event)")
        }

        return state.transition(event)
    }

    private enum Event: Equatable {
        case load(Locator?)
        case loaded
        case jump(Locator)
        case jumped
    }

    // MARK: - JavaScript Communication

    /// Retained by WebKit-owned objects in place of the navigator.
    ///
    /// `WKUserContentController` retains its script message handlers and
    /// `UIGestureRecognizer` retains its targets, so registering the navigator
    /// itself ties its lifetime to the web view's (navigator → webView →
    /// configuration/recognizer → navigator) and makes `deinit` — where handler
    /// removal and, transitively, the publication route removal live —
    /// unreachable, stranding one navigator and wrapper web view per book
    /// switch.
    @MainActor private final class WebKitBridge: NSObject, WKScriptMessageHandler {
        private weak var navigator: EPUBContinuousNavigatorViewController?

        init(navigator: EPUBContinuousNavigatorViewController) {
            self.navigator = navigator
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            navigator?.jsMessages[message.name]?(message.body, message.frameInfo)
        }

        @objc func didRecognizeBlockDoubleTap(_ recognizer: UITapGestureRecognizer) {
            navigator?.didRecognizeBlockDoubleTap(recognizer)
        }
    }

    private lazy var webKitBridge = WebKitBridge(navigator: self)

    private var jsMessages: [String: (Any, WKFrameInfo) -> Void] = [:]
    private var jsMessagesEnabled = false

    private var pendingLocationUpdateTask: Task<Void, Never>?

    private func enableJSMessages() {
        guard !jsMessagesEnabled else { return }
        jsMessagesEnabled = true

        registerJSMessage(named: "log") { [weak self] body, _ in self?.didLog(body) }
        registerJSMessage(named: "logError") { [weak self] body, _ in self?.didLogError(body) }
        registerJSMessage(named: "spreadLoadStarted") { _, _ in }
        registerJSMessage(named: "spreadLoaded") { [weak self] _, frameInfo in
            // Chapter iframes bundle the same scripts as the wrapper; only the wrapper's own
            // spread-loaded signal marks the initial load.
            guard frameInfo.isMainFrame else { return }
            self?.initialChaptersDidLoad()
        }
        registerJSMessage(named: "progressionChanged") { [weak self] body, _ in self?.progressionDidChange(body) }
        registerJSMessage(named: "chapterMounted") { [weak self] body, _ in self?.chapterDidMount(body) }
        registerJSMessage(named: "selectionChanged") { [weak self] body, _ in self?.selectionDidChange(body) }
        registerJSMessage(named: "decorationActivated") { [weak self] body, _ in self?.decorationDidActivate(body) }
        registerJSMessage(named: "tap") { [weak self] body, _ in self?.didTap(body) }
        registerJSMessage(named: "pointerEventReceived") { [weak self] body, _ in self?.didReceivePointerEvent(body) }
        registerJSMessage(named: "keyEventReceived") { [weak self] body, _ in self?.didReceiveKeyEvent(body) }
        registerJSMessage(named: "blockActivated") { [weak self] body, frameInfo in
            self?.didReceiveBlockActivated(body, frameInfo: frameInfo)
        }

        for (name, _) in jsMessages {
            webView.configuration.userContentController.add(webKitBridge, name: name)
        }
    }

    private func disableJSMessages() {
        guard jsMessagesEnabled else { return }
        jsMessagesEnabled = false
        for name in jsMessages.keys {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
    }

    private func registerJSMessage(named name: String, handler: @escaping (Any, WKFrameInfo) -> Void) {
        jsMessages[name] = handler
    }

    @discardableResult
    private func evaluateScript(_ script: String) async -> Result<Any, Swift.Error> {
        guard isWrapperLoaded else {
            return .failure(Error.wrapperLoadFailed)
        }

        if config.debugState {
            log(.trace, "Evaluate script: \(script)")
        }
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error = error {
                    self.log(.error, error)
                    continuation.resume(returning: .failure(error))
                } else {
                    continuation.resume(returning: .success(result ?? ()))
                }
            }
        }
    }

    // MARK: - JavaScript Message Handlers

    private func didLog(_ body: Any) {
        guard let message = body as? String else { return }
        #if DEBUG
            if message.hasPrefix("[goto-trace]") {
                diagnosticHandler?(message)
            }
        #endif
        log(.debug, "JavaScript: \(message)")
    }

    private func didLogError(_ body: Any) {
        guard let error = body as? [String: Any],
              var message = error["message"] as? String
        else { return }
        message = "JavaScript: \(message)"
        log(.error, message)
    }

    private func wrapperDidLoad() {
        guard !isWrapperLoaded else { return }
        isWrapperLoaded = true

        Task {
            await initializeWrapper()
        }
    }

    private func initialChaptersDidLoad() {
        _ = on(.loaded)
    }

    private func initializeWrapper() async {
        // Build spine items configuration
        let spineItems: [JSONValue] = readingOrder.enumerated().map { index, link in
            .object([
                "spineIndex": index.jsonValue,
                "href": link.url().string.jsonValue,
                "url": viewModel.url(to: link).string.jsonValue,
                "title": (link.title ?? "").jsonValue,
                "link": .object(link.jsonObject),
            ])
        }

        let config: [String: JSONValue] = [
            "prefetchBehind": config.prefetchBehind.jsonValue,
            "prefetchAhead": config.prefetchAhead.jsonValue,
            "maxMounted": config.maxMountedChapters.jsonValue,
            "defaultChapterHeight": Double(config.defaultChapterHeight).jsonValue,
        ]

        guard
            let spineJSON = try? spineItems.jsonString(),
            let configJSON = try? config.jsonString()
        else {
            log(.error, "Failed to serialize spine items or config")
            return
        }

        await evaluateScript("continuousWrapper.initialize(\(spineJSON), \(configJSON));")

        // Register decoration templates
        let templates = self.config.decorationTemplates.reduce(into: [String: JSONValue]()) { styles, item in
            styles[item.key.rawValue] = .object(item.value.jsonObject)
        }
        if let templatesJSON = try? templates.jsonString() {
            await evaluateScript("continuousWrapper.registerDecorationTemplates(\(templatesJSON));")
        }

        // Replay decoration groups that were applied before the wrapper finished
        // loading (or before a CSS-triggered wrapper reload), so initial and
        // in-flight decorations survive wrapper (re)initialization.
        for (group, diffables) in decorations {
            await sendDecorations(diffables, in: group)
        }

        // Navigate to initial location if provided
        if let initialLocation = currentLocation {
            await go(to: initialLocation, options: NavigatorGoOptions(animated: false))
        }

        _ = on(.loaded)
    }

    private func progressionDidChange(_ body: Any) {
        guard let data = body as? [String: Any] else { return }

        if let chapterIndex = data["activeChapter"] as? Int {
            activeChapterIndex = chapterIndex
        }

        scheduleCurrentLocationUpdate()
    }

    private func chapterDidMount(_ body: Any) {
        guard
            let data = body as? [String: Any],
            let spineIndex = data["spineIndex"] as? Int,
            let hrefString = data["href"] as? String,
            let href = AnyURL(string: hrefString)
        else { return }

        // The continuous wrapper reapplies each group's retained snapshot to a
        // chapter as it mounts (applyStoredSettingsToIframe), so no native
        // per-chapter reapplication is needed here.
        delegate?.navigator(self, didMountChapterAt: spineIndex, href: href)
    }

    private func selectionDidChange(_ body: Any) {
        guard
            let selection = body as? [String: Any],
            let text = try? Locator.Text(json: JSONValue(selection["text"]))
        else {
            viewModel.editingActions.selection = nil
            return
        }

        let frame = CGRect(json: selection["rect"]) ?? .zero

        // `selection` is already shaped like a Locator JSON object (href, type,
        // locations.cssSelector anchored to the range's containing element), so
        // parsing it directly anchors the resulting Locator to the selection
        // itself and lets it resolve through `rangeFromLocator` on its own -
        // instead of inheriting `currentLocation` (the reading position), which
        // may be a different, non-containing element. Fall back to the old
        // currentLocation-based Locator when the parse fails (e.g. a malformed
        // href, or the script omitting `locations` when no selector resolved).
        let locator = (try? Locator(json: JSONValue(selection))) ?? currentLocation?.copy(text: { $0 = text })

        if let locator = locator {
            viewModel.editingActions.selection = Selection(
                locator: locator,
                frame: frame
            )
        }
    }

    private func decorationDidActivate(_ body: Any) {
        guard
            let data = body as? [String: Any],
            let decorationId = data["id"] as? Decoration.Id,
            let groupName = data["group"] as? String
        else { return }

        let frame = CGRect(json: data["rect"])
        let point = (data["click"] as? [String: Any]).flatMap { click in
            let x = click["x"] as? Double ?? 0
            let y = click["y"] as? Double ?? 0
            return CGPoint(x: x, y: y)
        }

        guard
            let callbacks = decorationCallbacks[groupName].takeIf({ !$0.isEmpty }),
            let decoration = decorations[groupName]?.first(where: { $0.decoration.id == decorationId })?.decoration
        else { return }

        for callback in callbacks {
            callback(OnDecorationActivatedEvent(decoration: decoration, group: groupName, rect: frame, point: point))
        }
    }

    private func didTap(_ body: Any) {
        guard let data = body as? [String: Any] else { return }
        let x = data["x"] as? Double ?? 0
        let y = data["y"] as? Double ?? 0
        let point = CGPoint(x: x, y: y)
        delegate?.navigator(self, didTapAt: point)
    }

    private func didReceivePointerEvent(_ body: Any) {
        guard
            let json = body as? [String: Any],
            let defaultPrevented = json["defaultPrevented"] as? Bool,
            !defaultPrevented,
            (json["interactiveElement"] as? String) == nil
        else { return }

        // Forward to input observers
    }

    private func didReceiveKeyEvent(_ body: Any) {
        guard
            let dict = body as? [String: Any],
            let keyEvent = KeyEvent(dict: dict)
        else { return }

        Task {
            _ = await inputObservers.didReceive(keyEvent)
        }
    }

    /// Strictly validates a `blockActivated` message and forwards it to the delegate.
    private func didReceiveBlockActivated(_ body: Any, frameInfo: WKFrameInfo) {
        switch Self.parseBlockActivationEvent(
            body,
            frameURL: frameInfo.request.url,
            readingOrder: readingOrder,
            urlToLink: { [viewModel] in viewModel.url(to: $0) }
        ) {
        case let .success(event):
            delegate?.navigator(self, didActivateBlock: event)
        case let .failure(rejection):
            log(.warning, rejection.warning)
        }
    }

    /// A `blockActivated` message that failed validation, carrying the warning to log.
    struct BlockActivationRejection: Swift.Error, Equatable {
        let warning: String
    }

    /// Strictly validates a `blockActivated` message body against the publication's reading
    /// order and the sending frame's URL.
    ///
    /// Rejects rather than substituting empty strings or zero rectangles: a malformed message
    /// must never surface as a degraded-but-present block activation, because downstream React
    /// state would then persist a bogus highlight.
    ///
    /// Static and WebKit-free (the frame's URL is passed in, not `WKFrameInfo`) so the whole
    /// validation chain is testable without constructing a navigator.
    static func parseBlockActivationEvent(
        _ body: Any,
        frameURL: URL?,
        readingOrder: [Link],
        urlToLink: (Link) -> AnyURL
    ) -> Result<BlockActivationEvent, BlockActivationRejection> {
        guard let data = body as? [String: Any] else {
            return .failure(.init(warning: "blockActivated: payload is not a dictionary"))
        }

        guard let locator = try? Locator(json: JSONValue(data["locator"])), !locator.href.string.isEmpty else {
            return .failure(.init(warning: "blockActivated: could not parse a valid locator"))
        }

        guard let spineIndex = readingOrder.firstIndexWithHREF(locator.href) else {
            return .failure(.init(warning: "blockActivated: locator href is not in the publication reading order: \(locator.href)"))
        }

        guard MediaType.xhtml.matches(locator.mediaType) else {
            return .failure(.init(warning: "blockActivated: locator type is not XHTML: \(locator.mediaType)"))
        }

        guard
            let cssSelector = locator.locations.cssSelector,
            !cssSelector.isEmpty
        else {
            return .failure(.init(warning: "blockActivated: missing or empty locations.cssSelector"))
        }

        guard
            let highlight = locator.text.highlight,
            !highlight.isEmpty
        else {
            return .failure(.init(warning: "blockActivated: missing or empty text.highlight"))
        }

        guard let rect = parseBlockActivationRect(data["rect"]) else {
            return .failure(.init(warning: "blockActivated: rect is missing, non-finite, or non-positive"))
        }

        // `WKScriptMessage.body` bridges JS `null` to `NSNull`, so an explicit `blockKey: null`
        // arrives as `.some(NSNull())` rather than `.none`; treat it the same as an absent key.
        let blockKey: String?
        switch data["blockKey"] {
        case .none:
            blockKey = nil
        case let .some(rawValue) where rawValue is NSNull:
            blockKey = nil
        case let .some(rawValue):
            guard let key = rawValue as? String, !key.isEmpty else {
                return .failure(.init(warning: "blockActivated: blockKey must be a non-empty string when present"))
            }
            blockKey = key
        }

        // Best-effort origin check: confirm the claimed href actually matches the chapter iframe
        // that sent the message, rather than trusting arbitrary WK message content. Skipped (not
        // rejected) when WebKit doesn't surface a frame URL, since that's a WebKit-side
        // limitation rather than evidence of a malformed message.
        if let frameURL {
            let expectedURL = urlToLink(readingOrder[spineIndex])
            guard AnyURL(url: frameURL).isEquivalentTo(expectedURL) else {
                return .failure(.init(warning: "blockActivated: sending frame \(frameURL) does not match claimed href \(locator.href)"))
            }
        }

        return .success(BlockActivationEvent(locator: locator, rect: rect, blockKey: blockKey))
    }

    /// Strictly parses the `rect` field of a `blockActivated` message.
    ///
    /// Named and implemented separately from `CGRect(json:)` because that helper reads
    /// `left`/`top` keys and defaults missing values to zero for decoration/selection geometry.
    /// The block-activation rect contract (`x`/`y`/`width`/`height`, all finite, width/height
    /// positive) is a different coordinate/validation contract and must reject rather than
    /// default.
    private static func parseBlockActivationRect(_ json: Any?) -> CGRect? {
        guard
            let dict = json as? [String: Any],
            let x = dict["x"] as? Double, x.isFinite,
            let y = dict["y"] as? Double, y.isFinite,
            let width = dict["width"] as? Double, width.isFinite, width > 0,
            let height = dict["height"] as? Double, height.isFinite, height > 0
        else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - Location Updates

    private func updateCurrentLocation() {
        Task {
            guard state == .idle else { return }

            let result = await evaluateScript(
                """
                (function () {
                  try {
                    if (typeof continuousWrapper === 'undefined') return null;
                    var loc = continuousWrapper.findFirstVisibleLocator();
                    return loc ? JSON.stringify(loc) : null;
                  } catch (e) {
                    return null;
                  }
                })();
                """
            )
            guard
                case let .success(value) = result,
                let jsonString = value as? String,
                let jsonData = jsonString.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                let locator = try? Locator(json: JSONValue(json))
            else { return }

            // Enrich locator with position data if available
            var enrichedLocator = locator
            if
                let index = readingOrder.firstIndexWithHREF(locator.href),
                let positions = positionsByReadingOrder.getOrNil(index),
                !positions.isEmpty
            {
                let progression = locator.locations.progression ?? 0
                let positionIndex = Int(ceil(progression * Double(positions.count - 1)))
                enrichedLocator = positions[min(positionIndex, positions.count - 1)].copy(
                    locations: { $0.progression = progression }
                )
            }

            if enrichedLocator != currentLocation {
                currentLocation = enrichedLocator
                delegate?.navigator(self, locationDidChange: enrichedLocator)
            }

            // Update viewport
            viewport = Viewport(
                activeChapterIndex: activeChapterIndex,
                readingOrder: activeChapterIndex < readingOrder.count ? [readingOrder[activeChapterIndex].url()] : [],
                progressions: [:],
                positions: nil
            )
        }
    }

    private func scheduleCurrentLocationUpdate() {
        pendingLocationUpdateTask?.cancel()
        pendingLocationUpdateTask = Task { [weak self] in
            // A cancelled sleep returns immediately; without this bail the
            // debounce degenerates into one locator round-trip per frame.
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, let self else { return }
            self.updateCurrentLocation()
        }
    }

    // MARK: - Navigator Protocol

    public var presentation: VisualNavigatorPresentation {
        VisualNavigatorPresentation(
            readingProgression: settings.readingProgression,
            scroll: true,
            axis: .vertical
        )
    }

    public func go(to locator: Locator, options: NavigatorGoOptions) async -> Bool {
        let normalizedLocator = publication.normalizeLocator(locator)

        guard on(.jump(normalizedLocator)) else { return false }

        guard let json = try? normalizedLocator.jsonString() else {
            _ = on(.jumped)
            return false
        }

        let result = await evaluateScript("continuousWrapper.goTo(\(json))")
        _ = on(.jumped)

        if case .success = result {
            currentLocation = normalizedLocator
            delegate?.navigator(self, didJumpTo: normalizedLocator)
            return true
        }
        return false
    }

    public func go(to link: Link, options: NavigatorGoOptions) async -> Bool {
        guard let locator = await publication.locate(link) else {
            return false
        }
        return await go(to: locator, options: options)
    }

    @discardableResult
    public func goForward(options: NavigatorGoOptions) async -> Bool {
        let result = await evaluateScript("continuousWrapper.scrollForward()")
        if case let .success(value) = result, let success = value as? Bool {
            return success
        }
        return false
    }

    @discardableResult
    public func goBackward(options: NavigatorGoOptions) async -> Bool {
        let result = await evaluateScript("continuousWrapper.scrollBackward()")
        if case let .success(value) = result, let success = value as? Bool {
            return success
        }
        return false
    }

    public func firstVisibleElementLocator() async -> Locator? {
        let result = await evaluateScript(
            """
            (function () {
              try {
                if (typeof continuousWrapper === 'undefined') return null;
                var loc = continuousWrapper.findFirstVisibleLocator();
                return loc ? JSON.stringify(loc) : null;
              } catch (e) {
                return null;
              }
            })();
            """
        )
        guard
            case let .success(value) = result,
            let jsonString = value as? String,
            let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let locator = try? Locator(json: JSONValue(json))
        else { return nil }
        return locator
    }

    // MARK: - SelectableNavigator

    public var currentSelection: Selection? {
        viewModel.editingActions.selection
    }

    public func clearSelection() {
        webView.evaluateJavaScript("window.getSelection().removeAllRanges()")
    }

    // MARK: - DecorableNavigator

    public func supports(decorationStyle style: Decoration.Style.Id) -> Bool {
        config.decorationTemplates.keys.contains(style)
    }

    public func apply(decorations: [Decoration], in group: String) {
        Task {
            let normalizedDecorations = decorations.map {
                var decoration = $0
                decoration.locator = publication.normalizeLocator(decoration.locator)
                return DiffableDecoration(decoration: decoration)
            }

            // Store the group's latest normalized snapshot unconditionally so it
            // survives a not-yet-loaded wrapper; only the JS evaluation is gated.
            // initializeWrapper replays stored groups once the wrapper loads, so
            // initial decorations are never lost.
            self.decorations[group] = normalizedDecorations

            guard isWrapperLoaded else { return }
            await sendDecorations(normalizedDecorations, in: group)
        }
    }

    /// Sends a group's complete decoration snapshot to the continuous wrapper.
    /// The wrapper treats it as the full set for the group across all chapters
    /// and reconciles every loaded chapter against it. A no-op when the wrapper
    /// isn't loaded, since `evaluateScript` gates on `isWrapperLoaded`.
    private func sendDecorations(_ diffables: [DiffableDecoration], in group: String) async {
        let decorationData: [JSONValue] = diffables.map { diffable in
            let d = diffable.decoration
            return .object([
                "id": d.id.jsonValue,
                "locator": .object(d.locator.jsonObject),
                "style": d.style.id.rawValue.jsonValue,
                "element": (config.decorationTemplates[d.style.id]?.element(d) ?? "").jsonValue,
            ])
        }

        guard
            let groupJSON = try? group.jsonString(),
            let decsJSON = try? decorationData.jsonString()
        else { return }

        // evaluateScript already logs evaluation failures.
        _ = await evaluateScript("continuousWrapper.applyDecorations(\(groupJSON), \(decsJSON));")
    }

    public func observeDecorationInteractions(inGroup group: String, onActivated: @escaping OnActivatedCallback) {
        var callbacks = decorationCallbacks[group] ?? []
        callbacks.append(onActivated)
        decorationCallbacks[group] = callbacks

        // Mark the group as activable in the wrapper
        Task {
            guard isWrapperLoaded else { return }
            guard let groupJSON = try? group.jsonString() else { return }
            await evaluateScript("continuousWrapper.setDecorationGroupActivable(\(groupJSON), true);")
        }
    }

    // MARK: - Configurable

    public func submitPreferences(_ preferences: EPUBPreferences) {
        var modifiedPreferences = preferences
        // Always force scroll mode for continuous navigation
        modifiedPreferences.scroll = true

        // The view model applies the new settings and, for non-layout-changing
        // updates (font size, theme, …), calls back through
        // `EPUBNavigatorViewModelDelegate.runScript` so the CSS reaches the
        // mounted chapter iframes and is stored for chapters mounted later.
        viewModel.submitPreferences(modifiedPreferences)
        view.backgroundColor = settings.effectiveBackgroundColor.uiColor

        delegate?.navigator(self, presentationDidChange: presentation)
    }

    public func editor(of preferences: EPUBPreferences) -> EPUBPreferencesEditor {
        viewModel.editor(of: preferences)
    }

    // MARK: - UIAccessibilityAction

    override open func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard !super.accessibilityScroll(direction) else { return true }

        let options = NavigatorGoOptions(animated: false)

        Task {
            switch direction {
            case .down, .right:
                await goForward(options: options)
            case .up, .left:
                await goBackward(options: options)
            default:
                break
            }
        }
        return true
    }
}

// MARK: - UIGestureRecognizerDelegate

extension EPUBContinuousNavigatorViewController: UIGestureRecognizerDelegate {
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === blockDoubleTapRecognizer,
              let otherTap = otherGestureRecognizer as? UITapGestureRecognizer,
              otherTap.numberOfTapsRequired == 2,
              otherTap.numberOfTouchesRequired == 1,
              let otherView = otherTap.view
        else {
            return false
        }

        // Give Cadency's public touch/Pencil recognizer precedence over competing
        // double-tap recognizers in the web view hierarchy. Pointer input is excluded
        // by allowedTouchTypes, preserving mouse/trackpad double-click selection.
        return otherView === webView || otherView.isDescendant(of: webView)
    }
}

// MARK: - WKNavigationDelegate

extension EPUBContinuousNavigatorViewController: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Swift.Error) {
        log(.error, error)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Swift.Error) {
        log(.error, error)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log(.debug, "Wrapper navigation finished")

        webView.evaluateJavaScript(
            """
            (function () {
              var scripts = Array.prototype.slice.call(document.scripts || []).map(function (s) { return s.src || ''; }).filter(Boolean);
              var chapters = document.getElementById('chapters');
              return {
                url: document.URL,
                baseURI: document.baseURI,
                readyState: document.readyState,
                hasContinuousWrapper: (typeof continuousWrapper !== 'undefined'),
                hasWebkitMessageHandlers: !!(window.webkit && window.webkit.messageHandlers),
                scriptCount: scripts.length,
                firstScripts: scripts.slice(0, 5),
                chaptersChildren: chapters ? chapters.children.length : -1
              };
            })();
            """
        ) { [weak self] result, error in
            guard let self else { return }
            if let error = error {
                self.log(.error, "Wrapper probe JS error: \(error)")
                return
            }

            guard let probe = result as? [String: Any] else {
                self.log(.error, "Wrapper probe returned unexpected value: \(String(describing: result))")
                return
            }

            let hasContinuousWrapper = (probe["hasContinuousWrapper"] as? Bool) ?? false
            if self.config.debugState {
                self.log(.debug, "Wrapper probe: \(probe)")
            }

            if hasContinuousWrapper {
                self.wrapperDidLoad()
                return
            }

            let url = (probe["url"] as? String) ?? String(describing: webView.url)
            self.log(.error, "Main document is not the continuous wrapper. url=\(url)")
            self.isWrapperLoaded = false
            self.pendingLocationUpdateTask?.cancel()
            Task { [weak self] in
                await self?.loadWrapper()
            }
        }
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log(.error, "Web content process terminated")
        isWrapperLoaded = false
        pendingLocationUpdateTask?.cancel()
        Task { [weak self] in
            await self?.loadWrapper()
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        var policy: WKNavigationActionPolicy = .allow

        if navigationAction.navigationType == .linkActivated {
            if let url = navigationAction.request.url?.httpURL {
                if let relativeURL = viewModel.publicationBaseURL.relativize(url) {
                    // Internal link
                    Task {
                        if let link = publication.linkWithHREF(relativeURL) {
                            if delegate?.navigator(self, shouldNavigateToLink: link) ?? true {
                                await go(to: link)
                            }
                        }
                    }
                } else {
                    // External link
                    delegate?.navigator(self, presentExternalURL: url.url)
                }
                policy = .cancel
            }
        }

        decisionHandler(policy)
    }
}

// MARK: - EPUBNavigatorViewModelDelegate

extension EPUBContinuousNavigatorViewController: EPUBNavigatorViewModelDelegate {
    /// The prefix of the per-resource CSS call the view model emits for the
    /// paginated navigator. In continuous mode the chapters are iframes inside
    /// the wrapper document, so the call is re-targeted to the wrapper API.
    private nonisolated static let readiumCSSPropertiesCall = "readium.setCSSProperties("

    func epubNavigatorViewModel(_ viewModel: EPUBNavigatorViewModel, runScript script: String, in scope: EPUBScriptScope) {
        guard let wrapperScript = Self.continuousWrapperScript(for: script, in: scope) else {
            log(.warning, "Ignoring unsupported continuous navigator script for scope \(scope): \(script)")
            return
        }

        Task {
            await evaluateScript(wrapperScript)
        }
    }

    /// Re-targets a view-model script from the reflowable per-resource API
    /// (`window.readium`) to the continuous wrapper API (`continuousWrapper`),
    /// which fans the properties out to every mounted iframe and stores them for
    /// chapters mounted later (`window._cssProperties`). Returns `nil` for
    /// scripts that don't apply to continuous mode rather than silently
    /// mis-routing them.
    nonisolated static func continuousWrapperScript(for script: String, in scope: EPUBScriptScope) -> String? {
        switch scope {
        case .loadedResources:
            guard script.hasPrefix(readiumCSSPropertiesCall) else {
                return nil
            }
            return "continuousWrapper." + script.dropFirst("readium.".count)

        case .currentResource, .resource:
            return nil
        }
    }

    func epubNavigatorViewModelInvalidatePaginationView(_ viewModel: EPUBNavigatorViewModel) {
        // Continuous mode has no paginated spreads to rebuild. Layout-changing
        // settings (reading progression, language, vertical text, …) alter the
        // CSS injected into each resource, so reload the wrapper to re-fetch
        // every chapter with the new styles; the pending locator, seeded from
        // `currentLocation`, restores the reading position after reload.
        isWrapperLoaded = false
        pendingLocationUpdateTask?.cancel()
        Task { [weak self] in
            await self?.loadWrapper()
        }
    }

    func epubNavigatorViewModel(
        _ viewModel: EPUBNavigatorViewModel,
        didFailToLoadResourceAt href: RelativeURL,
        withError error: ReadError
    ) {
        DispatchQueue.main.async {
            self.delegate?.navigator(self, didFailToLoadResourceAt: href, withError: error)
        }
    }
}

// MARK: - EditingActionsControllerDelegate

extension EPUBContinuousNavigatorViewController: EditingActionsControllerDelegate {
    func editingActionsDidPreventCopy(_ editingActions: EditingActionsController) {
        delegate?.navigator(self, presentError: .copyForbidden)
    }

    func editingActions(_ editingActions: EditingActionsController, shouldShowMenuForSelection selection: Selection) -> Bool {
        delegate?.navigator(self, shouldShowMenuForSelection: selection) ?? true
    }

    func editingActions(_ editingActions: EditingActionsController, canPerformAction action: EditingAction, for selection: Selection) -> Bool {
        delegate?.navigator(self, canPerformAction: action, for: selection) ?? true
    }
}

// MARK: - KeyEvent Helper

private extension KeyEvent {
    init?(dict: [String: Any]) {
        guard
            let phaseString = dict["phase"] as? String,
            let code = dict["code"] as? String
        else { return nil }

        let phase: Phase = phaseString == "down" ? .down : .up

        let key: Key
        switch code {
        case "Enter": key = .enter
        case "Tab": key = .tab
        case "Space": key = .space
        case "ArrowDown": key = .arrowDown
        case "ArrowLeft": key = .arrowLeft
        case "ArrowRight": key = .arrowRight
        case "ArrowUp": key = .arrowUp
        case "End": key = .end
        case "Home": key = .home
        case "PageDown": key = .pageDown
        case "PageUp": key = .pageUp
        case "Backspace": key = .backspace
        case "Escape": key = .escape
        default:
            guard let char = dict["key"] as? String else { return nil }
            key = .character(char.lowercased())
        }

        var modifiers = KeyModifiers()
        if (dict["control"] as? Bool) ?? false { modifiers.insert(.control) }
        if (dict["command"] as? Bool) ?? false { modifiers.insert(.command) }
        if (dict["shift"] as? Bool) ?? false { modifiers.insert(.shift) }
        if (dict["option"] as? Bool) ?? false { modifiers.insert(.option) }

        self.init(phase: phase, key: key, modifiers: modifiers)
    }
}
