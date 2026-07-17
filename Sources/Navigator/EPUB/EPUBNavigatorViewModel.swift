//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared
import UIKit

protocol EPUBNavigatorViewModelDelegate: AnyObject {
    func epubNavigatorViewModel(_ viewModel: EPUBNavigatorViewModel, runScript script: String, in scope: EPUBScriptScope)
    func epubNavigatorViewModelInvalidatePaginationView(_ viewModel: EPUBNavigatorViewModel)
    func epubNavigatorViewModel(_ viewModel: EPUBNavigatorViewModel, didFailToLoadResourceAt href: RelativeURL, withError error: ReadError)
}

enum EPUBScriptScope {
    case currentResource
    case loadedResources
    case resource(href: AnyURL)
}

@MainActor final class EPUBNavigatorViewModel: Loggable {
    let publication: Publication
    let config: EPUBNavigatorViewController.Configuration
    let editingActions: EditingActionsController

    /// The base URL for the publication resources.
    private(set) var publicationBaseURL: AbsoluteURL!

    /// The base URL for Readium assets (CSS, scripts, etc.) and fonts.
    let assetsBaseURL: any AbsoluteURL

    /// The server used to serve publication resources and static assets to
    /// the web view.
    let server: WebViewServer

    /// Format sniffer used to infer the media type of resources served with
    /// the `server`.
    let formatSniffer: FormatSniffer

    weak var delegate: EPUBNavigatorViewModelDelegate?

    let readingOrder: ReadingOrder

    convenience init(
        publication: Publication,
        readingOrder: ReadingOrder,
        config: EPUBNavigatorViewController.Configuration
    ) {
        let assetsDirectory = Bundle.module.resourceURL!.fileURL!
            .appendingPath("Assets/Static", isDirectory: true)

        let formatSniffer = DefaultFormatSniffer()
        let server = WebViewServer(scheme: "readium", formatSniffer: formatSniffer)

        // Serve static assets directory.
        let assetsBaseURL = server.serve(directory: assetsDirectory, at: "assets")

        self.init(
            publication: publication,
            readingOrder: readingOrder,
            config: config,
            server: server,
            assetsBaseURL: assetsBaseURL,
            formatSniffer: formatSniffer
        )

        if let url = publication.baseURL {
            // The publication already has an HTTP base URL (e.g. served
            // remotely). Use it directly; the server only needs to serve
            // assets.
            publicationBaseURL = url
        } else {
            // Serve publication resources.
            publicationBaseURL = server.serve(at: UUID().uuidString) { [weak self] in
                await self?.serve(href: $0)
            }
        }
    }

    /// Creates a view model registering its routes on a shared, process-wide
    /// `WebViewServer` instead of a private one.
    ///
    /// The continuous navigator adopts pre-warmed web views whose scheme
    /// handler is the `WrapperPreparationEngine`'s server, fixed at web view
    /// creation — WebKit forbids attaching a handler afterwards. Serving the
    /// assets and the publication under the single `routePrefix` host also
    /// keeps the wrapper page and its chapter iframes same-origin, which the
    /// wrapper scripts rely on for `window.parent` access.
    convenience init(
        publication: Publication,
        readingOrder: ReadingOrder,
        config: EPUBNavigatorViewController.Configuration,
        sharedServer server: WebViewServer,
        routePrefix: String
    ) {
        let assetsDirectory = Bundle.module.resourceURL!.fileURL!
            .appendingPath("Assets/Static", isDirectory: true)

        let assetsBaseURL = server.serve(directory: assetsDirectory, at: "\(routePrefix)/assets")

        self.init(
            publication: publication,
            readingOrder: readingOrder,
            config: config,
            server: server,
            assetsBaseURL: assetsBaseURL,
            formatSniffer: server.formatSniffer
        )

        if let url = publication.baseURL {
            publicationBaseURL = url
        } else {
            let route = "\(routePrefix)/pub/\(UUID().uuidString)"
            publicationBaseURL = server.serve(at: route) { [weak self] in
                await self?.serve(href: $0)
            }
            sharedServerPublicationRoute = route
        }
    }

    /// Publication route registered on a shared server, removed on deinit.
    /// `nil` when the server is private to this view model and dies with it.
    private var sharedServerPublicationRoute: String?

    private init(
        publication: Publication,
        readingOrder: ReadingOrder,
        config: EPUBNavigatorViewController.Configuration,
        server: WebViewServer,
        assetsBaseURL: any AbsoluteURL,
        formatSniffer: FormatSniffer
    ) {
        var config = config

        if let fontsDir = Bundle.module.resourceURL?.fileURL?.appendingPath("Assets/Static/fonts", isDirectory: true) {
            config.fontFamilyDeclarations.append(
                CSSFontFamilyDeclaration(
                    fontFamily: .openDyslexic,
                    fontFaces: [
                        CSSFontFace(
                            file: fontsDir.appendingPath("OpenDyslexic-Regular.otf", isDirectory: false),
                            style: .normal, weight: .standard(.normal)
                        ),
                        CSSFontFace(
                            file: fontsDir.appendingPath("OpenDyslexic-Italic.otf", isDirectory: false),
                            style: .italic, weight: .standard(.normal)
                        ),
                        CSSFontFace(
                            file: fontsDir.appendingPath("OpenDyslexic-Bold.otf", isDirectory: false),
                            style: .normal, weight: .standard(.bold)
                        ),
                        CSSFontFace(
                            file: fontsDir.appendingPath("OpenDyslexic-BoldItalic.otf", isDirectory: false),
                            style: .italic, weight: .standard(.bold)
                        ),
                    ]
                ).eraseToAnyHTMLFontFamilyDeclaration()
            )
        }

        self.publication = publication
        self.readingOrder = readingOrder
        self.config = config
        editingActions = EditingActionsController(
            actions: config.editingActions,
            publication: publication
        )
        self.server = server
        self.assetsBaseURL = assetsBaseURL
        self.formatSniffer = formatSniffer

        preferences = config.preferences
        settings = EPUBSettings(publication: publication, config: config)

        css = ReadiumCSS(
            layout: CSSLayout(),
            rsProperties: config.readiumCSSRSProperties,
            baseURL: assetsBaseURL.appendingPath("readium-css", isDirectory: true),
            fontFamilyDeclarations: config.fontFamilyDeclarations
        )

        css.update(with: settings)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(voiceOverStatusDidChange),
            name: UIAccessibility.voiceOverStatusDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)

        if let route = sharedServerPublicationRoute {
            let server = server
            Task { @MainActor in
                server.remove(at: route)
            }
        }
    }

    func url(to link: Link) -> AnyURL {
        link.url(relativeTo: publicationBaseURL)
    }

    private var needsInvalidatePagination = false
    private func setNeedsInvalidatePagination() {
        guard !needsInvalidatePagination else {
            return
        }
        needsInvalidatePagination = true
        DispatchQueue.main.async { [self] in
            needsInvalidatePagination = false
            delegate?.epubNavigatorViewModelInvalidatePaginationView(self)
        }
    }

    // MARK: - Web View Server

    /// Serves chapter HTML with a `script-src 'none'` CSP when true, so
    /// authored EPUB scripts never run. Set by the continuous navigator
    /// (default off to leave the stock navigator's behavior untouched);
    /// injected user scripts are user-agent scripts and exempt from page CSP.
    var blocksAuthoredScripts = false

    private func serve(href: RelativeURL) async -> (Resource, MediaType)? {
        guard var resource = publication.get(href) else {
            return nil
        }
        let mediaType = await resolveMediaType(for: resource, at: href)
        resource = injectReadiumCSS(in: resource, at: href)
        if blocksAuthoredScripts {
            resource = injectContentSecurityPolicy(in: resource, at: href)
        }
        return (resource, mediaType)
    }

    /// Injects a CSP `<meta>` blocking authored scripts into HTML resources.
    /// A `<meta http-equiv>` policy only applies to content after it, so it
    /// goes at the very start of `<head>`, before any authored content.
    private func injectContentSecurityPolicy<HREF: URLConvertible>(in resource: Resource, at href: HREF) -> Resource {
        guard
            let link = publication.linkWithHREF(href),
            link.mediaType?.isHTML == true
        else {
            return resource
        }

        return resource.mapAsString { [weak self] content in
            let injection = HTMLInjection(
                content: "<meta http-equiv=\"Content-Security-Policy\" content=\"script-src 'none'\"/>",
                target: .head,
                location: .start
            )
            let injected = (try? injection.inject(in: content)) ?? content
            if injected == content {
                // Without a <head> the policy cannot be applied; surface it —
                // this document's authored scripts are only contained by the
                // content-world isolation, not the CSP.
                self?.log(.warning, "Could not inject the script-blocking CSP (no <head>) in \(href)")
            }
            return injected
        }
    }

    /// Resolves the media type to use to serve the given `resource`.
    ///
    /// The media type declared in the manifest takes precedence, before falling
    /// back on the `Resource` properties and sniffing the `href`.
    ///
    /// The manifest takes precedence because a file with a `.xml` extension
    /// might be declared as `application/xhtml+xml` in the OPF.
    private func resolveMediaType(for resource: Resource, at href: RelativeURL) async -> MediaType {
        if let mediaType = publication.linkWithHREF(href)?.mediaType {
            return mediaType
        }
        if let mediaType = await resource.properties().getOrNil()?.mediaType {
            return mediaType
        }

        return href.pathExtension.flatMap { formatSniffer.sniffHints(.init(fileExtension: $0))?.mediaType }
            ?? .binary
    }

    // MARK: - User preferences

    /// Currently applied settings.
    private(set) var settings: EPUBSettings

    /// Last submitted preferences.
    private var preferences: EPUBPreferences

    func submitPreferences(_ preferences: EPUBPreferences) {
        self.preferences = preferences
        applyPreferences()
    }

    private func applyPreferences() {
        let oldSettings = settings
        let newSettings = EPUBSettings(
            preferences: preferences,
            publication: publication,
            config: config
        )

        settings = newSettings
        updateSpread()

        let needsInvalidation: Bool =
            oldSettings.readingProgression != newSettings.readingProgression
                || oldSettings.language != newSettings.language
                || oldSettings.verticalText != newSettings.verticalText
                || oldSettings.scroll != newSettings.scroll
                || oldSettings.spread != newSettings.spread
                || oldSettings.fit != newSettings.fit
                || oldSettings.offsetFirstPage != newSettings.offsetFirstPage

        // We don't commit the CSS changes if we invalidate the pagination, as
        // the resources will be reloaded anyway.
        updateCSS(with: settings, commitNow: !needsInvalidation)

        if needsInvalidation {
            setNeedsInvalidatePagination()
        }
    }

    func editor(of preferences: EPUBPreferences) -> EPUBPreferencesEditor {
        EPUBPreferencesEditor(
            initialPreferences: preferences,
            metadata: publication.metadata,
            defaults: config.defaults
        )
    }

    var readingProgression: ReadingProgression {
        settings.readingProgression
    }

    var theme: Theme {
        settings.theme
    }

    var scroll: Bool {
        settings.scroll
    }

    var verticalText: Bool {
        settings.verticalText
    }

    var spread: Spread {
        settings.spread
    }

    var offsetFirstPage: Bool? {
        settings.offsetFirstPage
    }

    // MARK: Spread

    private(set) var spreadEnabled: Bool = false
    private var viewSize: CGSize?

    func viewSizeWillChange(_ newSize: CGSize) {
        guard viewSize != newSize else {
            return
        }
        viewSize = newSize
        updateSpread()
    }

    private func updateSpread() {
        let size = viewSize ?? .zero
        let isLandscape = size.width > size.height
        let oldEnabled = spreadEnabled

        switch spread {
        case .never:
            spreadEnabled = false
        case .always:
            spreadEnabled = true
        case .auto:
            spreadEnabled = isLandscape
        }

        if oldEnabled != spreadEnabled {
            setNeedsInvalidatePagination()
        }
    }

    // MARK: - Readium CSS

    private var css: ReadiumCSS
    private var servedFonts: [FileURL: AbsoluteURL] = [:]

    func injectReadiumCSS<HREF: URLConvertible>(in resource: Resource, at href: HREF) -> Resource {
        guard
            let link = publication.linkWithHREF(href),
            link.mediaType?.isHTML == true,
            publication.metadata.epubLayout == .reflowable
        else {
            return resource
        }

        return resource.mapAsString { [weak self] content in
            guard let self = self else {
                return content
            }

            do {
                var content = try css.inject(in: content)
                for ff in config.fontFamilyDeclarations {
                    content = try ff.inject(
                        in: content,
                        servingFile: { [server] file in
                            if let url = self.servedFonts[file] {
                                return url
                            }
                            let name = file.lastPathSegment ?? UUID().uuidString
                            let url = server.serve(file: file, at: "assets/fonts/\(name)")
                            self.servedFonts[file] = url
                            return url
                        }
                    )
                }
                return content
            } catch {
                log(.error, error)
                return content
            }
        }
    }

    private func updateCSS(with settings: EPUBSettings, commitNow: Bool) {
        let previous = css
        css.update(with: settings)

        // HTML resources in the cache have the CSS already injected at the time
        // they were first served. Evict them so that any future resource load
        // (e.g. after a screen rotation) reflects the updated CSS instead of
        // the stale cached version. Non-HTML resources (images, audio, etc.)
        // are not affected by CSS changes and can remain cached. On a shared
        // server, scope the eviction to this publication's route — another
        // book's cached documents reflect its own CSS, not ours.
        server.clearResourceCache { route, _, mediaType in
            guard mediaType.isHTML else { return false }
            guard let publicationRoute = sharedServerPublicationRoute else { return true }
            return route.hasPrefix(publicationRoute)
        }

        if commitNow {
            commitCSSChange(from: previous, to: css)
        }
    }

    private func commitCSSChange(from previous: ReadiumCSS, to new: ReadiumCSS) {
        var properties: [String: String?] = [:]
        let rsProperties = new.rsProperties.cssProperties()
        if previous.rsProperties.cssProperties() != rsProperties {
            for (k, v) in rsProperties {
                properties[k] = v
            }
        }
        let userProperties = new.userProperties.cssProperties()
        if previous.userProperties.cssProperties() != userProperties {
            for (k, v) in userProperties {
                properties[k] = v
            }
        }
        if !properties.isEmpty {
            guard
                let data = try? JSONSerialization.data(withJSONObject: properties),
                let json = String(data: data, encoding: .utf8)
            else {
                log(.error, "Failed to serialize CSS properties to JSON")
                return
            }

            delegate?.epubNavigatorViewModel(
                self,
                runScript: "readium.setCSSProperties(\(json));",
                in: .loadedResources
            )
        }
    }

    // MARK: - Accessibility

    private var isVoiceOverRunning = UIAccessibility.isVoiceOverRunning

    @objc private func voiceOverStatusDidChange() {
        // Avoids excessive settings refresh when the status didn't change.
        guard isVoiceOverRunning != UIAccessibility.isVoiceOverRunning else {
            return
        }
        isVoiceOverRunning = UIAccessibility.isVoiceOverRunning

        // Re-apply preferences to force the scroll mode if needed.
        applyPreferences()
    }
}

private extension EPUBSettings {
    init(
        preferences: EPUBPreferences? = nil,
        publication: Publication,
        config: EPUBNavigatorViewController.Configuration
    ) {
        self.init(
            preferences: preferences ?? config.preferences,
            defaults: config.defaults,
            metadata: publication.metadata
        )

        // Force-enables scroll when VoiceOver is running, because pagination
        // breaks the screen reader.
        if UIAccessibility.isVoiceOverRunning {
            scroll = true
        }
    }
}
