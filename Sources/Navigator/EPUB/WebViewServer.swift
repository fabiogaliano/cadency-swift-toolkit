//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumInternal
import ReadiumShared
import WebKit

/// A generic `WKURLSchemeHandler` that serves files, directories, and
/// arbitrary resources at named routes using a custom URL scheme (e.g.
/// `readium://`).
@MainActor final class WebViewServer: NSObject, WKURLSchemeHandler, Loggable {
    /// The custom scheme used to serve the content.
    let scheme: String

    /// Format sniffer used to infer the media type of served resources.
    let formatSniffer: FormatSniffer

    init(scheme: String, formatSniffer: FormatSniffer) {
        self.scheme = scheme
        self.formatSniffer = formatSniffer
        super.init()
    }

    #if DEBUG
        /// Optional handler for `[open-trace]` serve diagnostics: one line per
        /// request (queueing delay, resource-cache hit/miss, read time, bytes)
        /// plus cache evictions. `WrapperPreparationEngine` forwards its own
        /// handler here so the app's existing `onDiagnostics` wiring picks
        /// these up without changes.
        var diagnosticHandler: ((String) -> Void)?

        /// Emits one serve trace line. `receivedAt` is the moment WebKit handed
        /// us the scheme task; the gap to `servedAt` includes main-actor
        /// queueing, route matching, cache lookup, and the resource read.
        private func emitServeTrace(
            url: URL,
            receivedAt: Date,
            servedAt: Date = Date(),
            cache: String? = nil,
            bytes: Int = 0,
            outcome: String
        ) {
            guard let diagnosticHandler else { return }
            let total = Int(servedAt.timeIntervalSince(receivedAt) * 1000)
            let t = Int(servedAt.timeIntervalSince1970 * 1000)
            let cachePart = cache.map { " cache=\($0)" } ?? ""
            diagnosticHandler(
                "[open-trace] serve t=\(t) total=\(total)ms\(cachePart) bytes=\(bytes) outcome=\(outcome) path=\(url.path)"
            )
        }
    #endif

    // MARK: - Route registration

    private enum RouteHandler {
        case file(FileURL)
        case directory(FileURL)
        case resources(@MainActor (RelativeURL) async -> (Resource, MediaType)?)
    }

    /// Registered routes, sorted by reverse alphabetical order to ensure
    /// longest-prefix matching of routes sharing a common prefix.
    private var routes: [(path: String, baseURL: AbsoluteURL, handler: RouteHandler)] = []

    /// Serves a single local file at the given route.
    ///
    /// - Returns: The absolute URL (e.g. `readium://assets/fonts/abc/Font.otf`)
    ///   to the served file.
    @discardableResult
    func serve(file: FileURL, at route: String) -> AbsoluteURL {
        let route = normalizedRoute(route)
        let baseURL = AnyURL(string: "\(scheme)://\(route)")!.absoluteURL!
        insertRoute((path: route, baseURL: baseURL, handler: .file(file)))
        return baseURL
    }

    /// Serves a local directory at the given route.
    ///
    /// All files under the directory are accessible.
    ///
    /// - Returns: The absolute base URL (e.g. `readium://assets/`) to the
    ///   served directory.
    @discardableResult
    func serve(directory: FileURL, at route: String) -> AbsoluteURL {
        let route = normalizedRoute(route, isDirectory: true)
        let baseURL = AnyURL(string: "\(scheme)://\(route)")!.absoluteURL!
        insertRoute((path: route, baseURL: baseURL, handler: .directory(directory)))
        return baseURL
    }

    /// Serves resources at the given route using a handler callback.
    ///
    /// The handler receives a relative URL and returns a `Resource`, or
    /// `nil` for 404. Returned resources are automatically wrapped in a
    /// `BufferingResource` cache.
    ///
    /// Returns the base URL (e.g. `readium://{uuid}/`).
    @discardableResult
    func serve(at route: String, handler: @escaping @MainActor (RelativeURL) async -> (Resource, MediaType)?) -> AbsoluteURL {
        let route = normalizedRoute(route, isDirectory: true)
        let baseURL = AnyURL(string: "\(scheme)://\(route)")!.absoluteURL!
        insertRoute((path: route, baseURL: baseURL, handler: .resources(handler)))
        return baseURL
    }

    /// Removes the handler at the given route, along with the resources it
    /// cached.
    func remove(at route: String) {
        let route = normalizedRoute(route)
        routes.removeAll { $0.path.hasPrefix(route) }
        resourceCache.removeRoute(prefix: route)
        #if DEBUG
            diagnosticHandler?("[lifetime] route-removed route=\(route)")
        #endif
    }

    private func normalizedRoute(_ route: String, isDirectory: Bool = false) -> String {
        var r = route.removingPrefix("/")
        if isDirectory {
            r = r.addingSuffix("/")
        }
        return r
    }

    private func insertRoute(_ entry: (path: String, baseURL: AbsoluteURL, handler: RouteHandler)) {
        // Remove any existing route with the same path.
        routes.removeAll { $0.path == entry.path }
        routes.append(entry)
        // Reverse alphabetical order ensures longest-prefix matching:
        // routes sharing a common prefix are grouped with longer ones first.
        routes.sort { $0.path > $1.path }
    }

    // MARK: - Active tasks & caching

    /// Tracks active tasks for cancellation support.
    private var activeTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// Bounded cache of buffered resources keyed by route path +
    /// publication-relative URL. The server is shared process-wide and
    /// distinct publications routinely use identical internal paths
    /// (e.g. `OEBPS/chapter1.xhtml`), so the relative URL alone would let
    /// one publication's bytes answer another's request.
    ///
    /// Reusing the same ``Resource`` across requests lets compressed ZIP
    /// resources benefit from forward-seek optimization instead of
    /// decompressing from offset 0 on every request.
    ///
    /// Oldest entries are evicted when the cache exceeds its capacity.
    private var resourceCache = BoundedResourceCache()

    /// Memoized bytes of static asset files (Readium CSS, fonts, wrapper
    /// assets). Every chapter iframe re-requests the same few assets, and
    /// each request built a fresh `FileResource` + disk read. Safe because
    /// file routes only ever serve immutable bundle files; files that would
    /// push the cache past its budget are served uncached.
    private var assetDataCache: [String: (data: Data, mediaType: MediaType?)] = [:]
    private var assetDataCacheBytes = 0
    private let assetDataCacheBudget = 4 * 1024 * 1024

    /// Removes cached resources matching the given predicate, forcing them to
    /// be re-served on the next request.
    func clearResourceCache(where predicate: (_ route: String, _ href: RelativeURL, _ mediaType: MediaType) -> Bool) {
        resourceCache.remove { key, mediaType in predicate(key.route, key.href, mediaType) }
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask)
        let receivedAt = Date()
        activeTasks[taskID] = Task {
            await serve(urlSchemeTask, receivedAt: receivedAt)
            _ = activeTasks.removeValue(forKey: taskID)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask)
        activeTasks.removeValue(forKey: taskID)?.cancel()
    }

    // MARK: - Serving

    private func serve(_ urlSchemeTask: WKURLSchemeTask, receivedAt: Date) async {
        guard let requestURL = urlSchemeTask.request.url else {
            await fail(urlSchemeTask, with: URLError(.badURL))
            return
        }

        // Find the matching route (longest prefix wins).
        for route in routes {
            switch route.handler {
            case let .file(file):
                guard route.baseURL.isEquivalentTo(requestURL) else {
                    continue
                }
                await serveFile(urlSchemeTask, at: file, requestURL: requestURL, allowCrossOrigin: true, receivedAt: receivedAt)
                return

            case let .directory(directory):
                guard
                    let relativeURL = route.baseURL.relativize(requestURL),
                    let file = directory.resolve(relativeURL)?.fileURL,
                    directory.isParent(of: file)
                else {
                    continue
                }
                await serveFile(urlSchemeTask, at: file, requestURL: requestURL, allowCrossOrigin: true, receivedAt: receivedAt)
                return

            case let .resources(handler):
                guard let relativeURL = route.baseURL.relativize(requestURL) else {
                    continue
                }
                await serveResource(
                    urlSchemeTask,
                    routePath: route.path,
                    relativeURL: relativeURL,
                    handler: handler,
                    requestURL: requestURL,
                    receivedAt: receivedAt
                )
                return
            }
        }

        #if DEBUG
            emitServeTrace(url: requestURL, receivedAt: receivedAt, outcome: "no-route")
        #endif
        await fail(urlSchemeTask, with: URLError(.fileDoesNotExist))
    }

    /// Serves a resource from a handler callback, with caching.
    private func serveResource(
        _ urlSchemeTask: WKURLSchemeTask,
        routePath: String,
        relativeURL: RelativeURL,
        handler: @MainActor (RelativeURL) async -> (Resource, MediaType)?,
        requestURL: URL,
        receivedAt: Date
    ) async {
        // Reuse a cached buffered resource to benefit from forward-seek
        // optimization and read-ahead buffering, or create and cache a new
        // one.
        let cacheKey = BoundedResourceCache.Key(route: routePath, href: relativeURL)
        let resource: Resource
        let mediaType: MediaType
        let cacheState: String
        if let (cachedResource, cachedMediaType) = resourceCache.lookup(cacheKey) {
            resource = cachedResource
            mediaType = cachedMediaType
            cacheState = "hit"
        } else {
            guard let (newResource, newMediaType) = await handler(relativeURL) else {
                #if DEBUG
                    emitServeTrace(url: requestURL, receivedAt: receivedAt, cache: "miss", outcome: "not-found")
                #endif
                await fail(urlSchemeTask, with: URLError(.fileDoesNotExist))
                return
            }
            resource = newResource.buffered(size: BoundedResourceCache.bufferWindow)
            mediaType = newMediaType
            cacheState = "miss"
            // `BufferingResource` caches the length, so the range check in
            // the serve path below won't re-query the underlying resource.
            let estimatedLength = await (try? resource.estimatedLength().get()).flatMap { $0 }
            emitEvictions(resourceCache.set(cacheKey, resource: resource, mediaType: mediaType, estimatedLength: estimatedLength))
        }

        await serveResource(
            resource,
            with: urlSchemeTask,
            mediaType: mediaType,
            requestURL: requestURL,
            receivedAt: receivedAt,
            cacheState: cacheState,
            cacheKey: cacheKey
        )
    }

    private func emitEvictions(_ keys: [BoundedResourceCache.Key]) {
        #if DEBUG
            for key in keys {
                diagnosticHandler?("[open-trace] cache-evict path=\(key.route)\(key.href.string)")
            }
        #endif
    }

    /// Reads a local file and sends it as a response, memoizing its bytes
    /// for later requests.
    ///
    /// Local files are served for the static assets routes (Readium assets
    /// and font files), which publication documents load cross-origin —
    /// hence `allowCrossOrigin`.
    private func serveFile(
        _ urlSchemeTask: WKURLSchemeTask,
        at file: FileURL,
        requestURL: URL,
        allowCrossOrigin: Bool,
        receivedAt: Date
    ) async {
        if let cached = assetDataCache[file.string] {
            await serveData(cached.data, with: urlSchemeTask, mediaType: cached.mediaType, requestURL: requestURL, allowCrossOrigin: allowCrossOrigin, receivedAt: receivedAt, cacheState: "hit")
            return
        }

        let mediaType = mediaTypeFromURL(file)
        switch await FileResource(file: file).read() {
        case let .success(data):
            if assetDataCacheBytes + data.count <= assetDataCacheBudget {
                assetDataCache[file.string] = (data, mediaType)
                assetDataCacheBytes += data.count
            }
            await serveData(data, with: urlSchemeTask, mediaType: mediaType, requestURL: requestURL, allowCrossOrigin: allowCrossOrigin, receivedAt: receivedAt, cacheState: "miss")

        case let .failure(error):
            log(.error, "Failed to read file \(requestURL.path): \(error)")
            #if DEBUG
                emitServeTrace(url: requestURL, receivedAt: receivedAt, cache: "miss", outcome: "read-failed")
            #endif
            await fail(urlSchemeTask, with: URLError(.resourceUnavailable))
        }
    }

    /// Serves in-memory bytes, honoring a byte-range request.
    private func serveData(
        _ data: Data,
        with urlSchemeTask: WKURLSchemeTask,
        mediaType: MediaType?,
        requestURL: URL,
        allowCrossOrigin: Bool,
        receivedAt: Date,
        cacheState: String
    ) async {
        let totalLength = UInt64(data.count)
        if let range = urlSchemeTask.request.byteRange(in: totalLength) {
            let chunk = Data(data[Int(range.lowerBound) ..< Int(range.upperBound)])
            #if DEBUG
                emitServeTrace(url: requestURL, receivedAt: receivedAt, cache: cacheState, bytes: chunk.count, outcome: "206")
            #endif
            await respond(urlSchemeTask, with: chunk, range: range, totalLength: totalLength, mediaType: mediaType, url: requestURL, allowCrossOrigin: allowCrossOrigin)
        } else {
            #if DEBUG
                emitServeTrace(url: requestURL, receivedAt: receivedAt, cache: cacheState, bytes: data.count, outcome: "200")
            #endif
            await respond(urlSchemeTask, with: data, range: nil, totalLength: totalLength, mediaType: mediaType, url: requestURL, allowCrossOrigin: allowCrossOrigin)
        }
    }

    private func serveResource(
        _ resource: Resource,
        with urlSchemeTask: WKURLSchemeTask,
        mediaType: MediaType?,
        requestURL: URL,
        allowCrossOrigin: Bool = false,
        receivedAt: Date,
        cacheState: String? = nil,
        cacheKey: BoundedResourceCache.Key? = nil
    ) async {
        // Try to serve a byte range if the client requested one and the
        // resource length is known.
        if
            let totalLength = await (try? resource.estimatedLength().get()).flatMap({ $0 }),
            let range = urlSchemeTask.request.byteRange(in: totalLength)
        {
            let result = await resource.read(range: range)
            switch result {
            case let .success(data):
                #if DEBUG
                    emitServeTrace(url: requestURL, receivedAt: receivedAt, cache: cacheState, bytes: data.count, outcome: "206")
                #endif
                await respond(urlSchemeTask, with: data, range: range, totalLength: totalLength, mediaType: mediaType, url: requestURL, allowCrossOrigin: allowCrossOrigin)
            case let .failure(error):
                log(.error, "Failed to read resource \(requestURL.path) range \(range): \(error)")
                await fail(urlSchemeTask, with: URLError(.resourceUnavailable))
            }
            return
        }

        // Full read fallback.
        let result = await resource.read()
        switch result {
        case let .success(data):
            if let cacheKey {
                emitEvictions(resourceCache.recordFullServe(cacheKey, bytes: data.count))
            }
            #if DEBUG
                emitServeTrace(url: requestURL, receivedAt: receivedAt, cache: cacheState, bytes: data.count, outcome: "200")
            #endif
            await respond(urlSchemeTask, with: data, range: nil, totalLength: UInt64(data.count), mediaType: mediaType, url: requestURL, allowCrossOrigin: allowCrossOrigin)
        case let .failure(error):
            log(.error, "Failed to read resource \(requestURL.path): \(error)")
            await fail(urlSchemeTask, with: URLError(.resourceUnavailable))
        }
    }

    private func mediaTypeFromURL(_ url: URLConvertible) -> MediaType? {
        guard let ext = url.anyURL.pathExtension else {
            return nil
        }
        return formatSniffer.sniffHints(FormatHints(fileExtension: ext))?.mediaType
    }

    // MARK: - Response helpers

    /// Sends data as a response, optionally as a 206 Partial Content when a
    /// byte range was requested.
    ///
    /// - Parameters:
    ///   - range: The byte range being served, or `nil` for a full 200
    ///     response.
    ///   - totalLength: The total size of the resource (used in
    ///     `Content-Range`).
    private func respond(
        _ urlSchemeTask: WKURLSchemeTask,
        with data: Data,
        range: Range<UInt64>?,
        totalLength: UInt64,
        mediaType: MediaType?,
        url: URL,
        allowCrossOrigin: Bool
    ) async {
        var headers: [String: String] = [
            "Content-Length": "\(data.count)",
            "Accept-Ranges": "bytes",
        ]

        if allowCrossOrigin {
            // Static assets (e.g. fonts declared with
            // `fontFamilyDeclarations`) are served under a different origin
            // than the publication documents referencing them
            // (readium://assets vs readium://{uuid}). Unlike stylesheets or
            // images, font fetches are CORS-gated by WebKit, so fonts never
            // load without this header. Mirrors `allowCors()` in the Kotlin
            // toolkit's WebViewServer. See issue #802.
            headers["Access-Control-Allow-Origin"] = "*"
        }

        if let mediaType {
            headers["Content-Type"] = mediaType.string
        }

        let statusCode: Int
        if let range = range {
            statusCode = 206
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(totalLength)"
        } else {
            statusCode = 200
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            await fail(urlSchemeTask, with: URLError(.unknown))
            return
        }

        // Guard against task cancellation to avoid calling WKURLSchemeTask
        // methods after WebKit has stopped the task.
        guard !Task.isCancelled else { return }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    private func fail(_ urlSchemeTask: WKURLSchemeTask, with error: Error) async {
        guard !Task.isCancelled else { return }
        urlSchemeTask.didFailWithError(error)
    }
}

private extension URLRequest {
    /// Parses an HTTP `Range` header value (RFC 7233) into a byte range.
    func byteRange(in totalLength: UInt64) -> Range<UInt64>? {
        Range(httpRange: value(forHTTPHeaderField: "Range") ?? "", in: totalLength)
    }
}

/// A bounded LRU cache for ``Resource`` instances.
///
/// Lookups refresh recency and eviction is least-recently-used once the
/// estimated retained bytes exceed the budget, so one image-heavy chapter
/// can no longer flush the documents of the mounted window (the previous
/// 8-entry FIFO was smaller than the window itself, up to 7 documents
/// during normal scrolling).
struct BoundedResourceCache {
    /// Cache entries are scoped to the route that produced them: the same
    /// publication-relative href under two routes is two distinct entries.
    struct Key: Hashable {
        let route: String
        let href: RelativeURL
    }

    /// Read-ahead window of the ``BufferingResource`` wrapping every cached
    /// resource — the most a raw resource retains (full reads bypass the
    /// buffer entirely), and the provisional cost of entries whose size
    /// isn't known yet.
    static let bufferWindow = 256 * 1024

    private struct Entry {
        let resource: Resource
        let mediaType: MediaType
        /// Estimated retained bytes. A raw resource (known length) retains
        /// at most the buffer window. An unknown-length resource is
        /// transforming (`estimatedLength()` is nil — e.g. chapter HTML with
        /// CSS injected) and memoizes its full output, so its cost stays
        /// provisional until the first full serve measures it.
        var cost: Int
        var costIsMeasured: Bool
    }

    private let budget: Int
    private var entries: [Key: Entry] = [:]
    /// Least-recently-used first.
    private var order: [Key] = []
    private var totalCost = 0

    init(budget: Int = 8 * 1024 * 1024) {
        self.budget = budget
    }

    mutating func lookup(_ key: Key) -> (Resource, MediaType)? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        return (entry.resource, entry.mediaType)
    }

    /// - Returns: The keys evicted to fit the budget, for diagnostics.
    @discardableResult
    mutating func set(_ key: Key, resource: Resource, mediaType: MediaType, estimatedLength: UInt64?) -> [Key] {
        removeEntry(key)
        let entry = Entry(
            resource: resource,
            mediaType: mediaType,
            cost: estimatedLength.map { min(Int(clamping: $0), Self.bufferWindow) } ?? Self.bufferWindow,
            costIsMeasured: estimatedLength != nil
        )
        entries[key] = entry
        order.append(key)
        totalCost += entry.cost
        return evictOverBudget()
    }

    /// Replaces the provisional cost of a memoizing entry with the bytes its
    /// first full serve actually produced.
    ///
    /// - Returns: The keys evicted to fit the budget, for diagnostics.
    @discardableResult
    mutating func recordFullServe(_ key: Key, bytes: Int) -> [Key] {
        guard var entry = entries[key], !entry.costIsMeasured else { return [] }
        totalCost += bytes - entry.cost
        entry.cost = bytes
        entry.costIsMeasured = true
        entries[key] = entry
        return evictOverBudget()
    }

    /// Removes all entries produced by routes matching the given prefix.
    mutating func removeRoute(prefix: String) {
        remove { key, _ in key.route.hasPrefix(prefix) }
    }

    mutating func remove(where predicate: (Key, MediaType) -> Bool) {
        for key in order where entries[key].map({ predicate(key, $0.mediaType) }) == true {
            removeEntry(key)
        }
    }

    private mutating func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
    }

    private mutating func removeEntry(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        totalCost -= entry.cost
        order.removeAll { $0 == key }
    }

    private mutating func evictOverBudget() -> [Key] {
        var evicted: [Key] = []
        // The most recent entry survives even when it alone exceeds the
        // budget: evicting what's about to be served would re-pay its
        // transform on the very next request.
        while totalCost > budget, order.count > 1 {
            let key = order.removeFirst()
            if let entry = entries.removeValue(forKey: key) {
                totalCost -= entry.cost
                evicted.append(key)
            }
        }
        return evicted
    }
}
