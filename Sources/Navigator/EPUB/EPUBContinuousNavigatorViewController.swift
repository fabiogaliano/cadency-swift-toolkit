//
//  Copyright 2025 Readium Foundation. All rights reserved.
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
    public var publication: Publication { viewModel.publication }

    /// Currently applied settings.
    public var settings: EPUBSettings { viewModel.settings }

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

    // MARK: - Private Properties

    private let viewModel: EPUBNavigatorViewModel
    private let config: Configuration
    private let readingOrder: [Link]
    private let loadPositionsByReadingOrder: () async -> ReadResult<[[Locator]]>
    private var positionsByReadingOrder: [[Locator]] = []

    private var webView: WKWebView!
    private var isWrapperLoaded = false

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
    ///   - httpServer: HTTP server used to serve publication resources.
    /// - Throws: `Error.publicationRestricted` if the publication is DRM-protected without
    ///           proper unlocking, or `Error.fixedLayoutNotSupported` if the publication
    ///           is fixed-layout.
    public convenience init(
        publication: Publication,
        initialLocation: Locator?,
        config: Configuration = .init(),
        httpServer: HTTPServer
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

        let viewModel = try EPUBNavigatorViewModel(
            publication: publication,
            config: epubConfig,
            httpServer: httpServer
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
        self.currentLocation = initialLocation
        self.readingOrder = readingOrder
        self.loadPositionsByReadingOrder = positionsByReadingOrder

        super.init(nibName: nil, bundle: nil)

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
        disableJSMessages()
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

    private func setupWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        // Disable Writing tools in iOS 18+
        #if compiler(>=6.0)
            if #available(iOS 18.0, *) {
                configuration.writingToolsBehavior = .none
            }
        #endif

        webView = WKWebView(frame: view.bounds, configuration: configuration)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.backgroundColor = .clear
        webView.isOpaque = false
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.showsVerticalScrollIndicator = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = self

        #if DEBUG && swift(>=5.8)
            if #available(macOS 13.3, iOS 16.4, *) {
                webView.isInspectable = true
            }
        #endif

        view.addSubview(webView)

        enableJSMessages()

        delegate?.navigator(self, setupUserScripts: webView.configuration.userContentController)
    }

    private func initialize() async {
        do {
            positionsByReadingOrder = try await loadPositionsByReadingOrder().get()
        } catch {
            log(.error, DebugError("Failed to load positions.", cause: error))
        }

        await loadWrapper()
    }

    private func loadWrapper() async {
        guard let wrapperURL = Bundle.module.url(forResource: "continuous-wrapper", withExtension: "html", subdirectory: "Assets") else {
            log(.error, "Could not find continuous-wrapper.html")
            return
        }

        do {
            var html = try String(contentsOf: wrapperURL)
            html = html.replacingOccurrences(of: "{{ASSETS_URL}}", with: viewModel.assetsURL.string)

            log(.debug, "Loading continuous wrapper baseURL=\(viewModel.publicationBaseURL.string) assetsURL=\(viewModel.assetsURL.string)")

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

    private var jsMessages: [String: (Any) -> Void] = [:]
    private var jsMessagesEnabled = false

    private var pendingLocationUpdateTask: Task<Void, Never>?

    private func enableJSMessages() {
        guard !jsMessagesEnabled else { return }
        jsMessagesEnabled = true

        registerJSMessage(named: "log") { [weak self] in self?.didLog($0) }
        registerJSMessage(named: "logError") { [weak self] in self?.didLogError($0) }
        registerJSMessage(named: "spreadLoadStarted") { _ in }
        registerJSMessage(named: "spreadLoaded") { [weak self] _ in self?.initialChaptersDidLoad() }
        registerJSMessage(named: "progressionChanged") { [weak self] in self?.progressionDidChange($0) }
        registerJSMessage(named: "chapterMounted") { [weak self] in self?.chapterDidMount($0) }
        registerJSMessage(named: "selectionChanged") { [weak self] in self?.selectionDidChange($0) }
        registerJSMessage(named: "decorationActivated") { [weak self] in self?.decorationDidActivate($0) }
        registerJSMessage(named: "tap") { [weak self] in self?.didTap($0) }
        registerJSMessage(named: "pointerEventReceived") { [weak self] in self?.didReceivePointerEvent($0) }
        registerJSMessage(named: "keyEventReceived") { [weak self] in self?.didReceiveKeyEvent($0) }

        for (name, _) in jsMessages {
            webView.configuration.userContentController.add(self, name: name)
        }
    }

    private func disableJSMessages() {
        guard jsMessagesEnabled else { return }
        jsMessagesEnabled = false
        for name in jsMessages.keys {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
    }

    private func registerJSMessage(named name: String, handler: @escaping (Any) -> Void) {
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
        let spineItems: [[String: Any]] = readingOrder.enumerated().map { index, link in
            [
                "spineIndex": index,
                "href": link.url().string,
                "url": viewModel.url(to: link).string,
                "title": link.title ?? "",
                "link": link.json,
            ]
        }

        let config: [String: Any] = [
            "prefetchBehind": self.config.prefetchBehind,
            "prefetchAhead": self.config.prefetchAhead,
            "maxMounted": self.config.maxMountedChapters,
            "defaultChapterHeight": self.config.defaultChapterHeight,
        ]

        guard
            let spineJSON = serializeJSONString(spineItems),
            let configJSON = serializeJSONString(config)
        else {
            log(.error, "Failed to serialize spine items or config")
            return
        }

        await evaluateScript("continuousWrapper.initialize(\(spineJSON), \(configJSON));")

        // Register decoration templates
        let templates = self.config.decorationTemplates.reduce(into: [:]) { styles, item in
            styles[item.key.rawValue] = item.value.json
        }
        if let templatesJSON = serializeJSONString(templates) {
            await evaluateScript("continuousWrapper.registerDecorationTemplates(\(templatesJSON));")
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

        // Apply pending decorations for this chapter
        Task {
            await applyDecorationsToChapter(at: spineIndex)
        }

        delegate?.navigator(self, didMountChapterAt: spineIndex, href: href)
    }

    private func selectionDidChange(_ body: Any) {
        guard
            let selection = body as? [String: Any],
            let text = try? Locator.Text(json: selection["text"])
        else {
            viewModel.editingActions.selection = nil
            return
        }

        let frame = CGRect(json: selection["rect"]) ?? .zero

        if let location = currentLocation {
            viewModel.editingActions.selection = Selection(
                locator: location.copy(text: { $0 = text }),
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
                let locator = try? Locator(json: json)
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
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self else { return }
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

        guard let json = normalizedLocator.jsonString else {
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
            let locator = try? Locator(json: json)
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
            guard isWrapperLoaded else { return }

            let normalizedDecorations = decorations.map {
                var d = $0
                d.locator = publication.normalizeLocator(d.locator)
                return DiffableDecoration(decoration: d)
            }

            self.decorations[group] = normalizedDecorations

            let decorationData = normalizedDecorations.map { diffable -> [String: Any] in
                let d = diffable.decoration
                return [
                    "id": d.id,
                    "locator": d.locator.json,
                    "style": d.style.id.rawValue,
                    "element": config.decorationTemplates[d.style.id]?.element(d) ?? "",
                ]
            }

            guard
                let groupJSON = serializeJSONString(group),
                let decsJSON = serializeJSONString(decorationData)
            else { return }

            await evaluateScript("continuousWrapper.applyDecorations(\(groupJSON), \(decsJSON));")
        }
    }

    private func applyDecorationsToChapter(at spineIndex: Int) async {
        guard spineIndex < readingOrder.count else { return }
        let href = readingOrder[spineIndex].url()

        for (group, decs) in decorations {
            let chapterDecorations = decs.filter { $0.decoration.locator.href.isEquivalentTo(href) }
            guard !chapterDecorations.isEmpty else { continue }

            let decorationData = chapterDecorations.map { diffable -> [String: Any] in
                let d = diffable.decoration
                return [
                    "id": d.id,
                    "locator": d.locator.json,
                    "style": d.style.id.rawValue,
                    "element": config.decorationTemplates[d.style.id]?.element(d) ?? "",
                ]
            }

            guard
                let groupJSON = serializeJSONString(group),
                let decsJSON = serializeJSONString(decorationData)
            else { continue }

            await evaluateScript("continuousWrapper.applyDecorations(\(groupJSON), \(decsJSON));")
        }
    }

    public func observeDecorationInteractions(inGroup group: String, onActivated: @escaping OnActivatedCallback) {
        var callbacks = decorationCallbacks[group] ?? []
        callbacks.append(onActivated)
        decorationCallbacks[group] = callbacks

        // Mark the group as activable in the wrapper
        Task {
            guard isWrapperLoaded else { return }
            guard let groupJSON = serializeJSONString(group) else { return }
            await evaluateScript("continuousWrapper.setDecorationGroupActivable(\(groupJSON), true);")
        }
    }

    // MARK: - Configurable

    public func submitPreferences(_ preferences: EPUBPreferences) {
        var modifiedPreferences = preferences
        // Always force scroll mode for continuous navigation
        modifiedPreferences.scroll = true

        viewModel.submitPreferences(modifiedPreferences)
        view.backgroundColor = settings.effectiveBackgroundColor.uiColor

        // Update CSS properties in loaded iframes
        Task {
            guard isWrapperLoaded else { return }
            // CSS property application is handled by the iframe documents
            // when they receive the updated settings via their own mechanisms
        }

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

// MARK: - WKScriptMessageHandler

extension EPUBContinuousNavigatorViewController: WKScriptMessageHandler {
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "spreadLoaded", !message.frameInfo.isMainFrame {
            return
        }
        guard let handler = jsMessages[message.name] else { return }
        handler(message.body)
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
