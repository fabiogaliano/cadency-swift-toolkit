//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import Testing

/// The serve cache must behave as an LRU with a retained-bytes budget:
/// lookups refresh recency, known-length (raw) entries cost at most the
/// buffer window, unknown-length (transforming) entries stay provisional
/// until their first full serve measures the memoized size, and removing
/// a route drops every entry it produced.
struct BoundedResourceCacheTests {
    private let resource = DataResource(string: "bytes")

    private func key(_ href: String, route: String = "pub/") -> BoundedResourceCache.Key {
        BoundedResourceCache.Key(route: route, href: RelativeURL(string: href)!)
    }

    @Test func lookupRefreshesRecency() {
        var cache = BoundedResourceCache(budget: 1000)
        cache.set(key("a.xhtml"), resource: resource, mediaType: .xhtml, estimatedLength: 400)
        cache.set(key("b.xhtml"), resource: resource, mediaType: .xhtml, estimatedLength: 400)
        #expect(cache.lookup(key("a.xhtml")) != nil)

        let evicted = cache.set(key("c.xhtml"), resource: resource, mediaType: .xhtml, estimatedLength: 400)
        #expect(evicted == [key("b.xhtml")])
        #expect(cache.lookup(key("a.xhtml")) != nil)
        #expect(cache.lookup(key("b.xhtml")) == nil)
    }

    @Test func evictsLeastRecentlyUsedWhenOverBudget() {
        var cache = BoundedResourceCache(budget: 1000)
        cache.set(key("a.xhtml"), resource: resource, mediaType: .xhtml, estimatedLength: 400)
        cache.set(key("b.xhtml"), resource: resource, mediaType: .xhtml, estimatedLength: 400)
        let evicted = cache.set(key("c.xhtml"), resource: resource, mediaType: .xhtml, estimatedLength: 400)
        #expect(evicted == [key("a.xhtml")])
    }

    @Test func knownLengthCostIsCappedAtTheBufferWindow() {
        // Two entries whose underlying resources are far larger than the
        // window (e.g. big images) must both fit: each retains at most the
        // buffer window, not its full length.
        var cache = BoundedResourceCache(budget: 2 * BoundedResourceCache.bufferWindow)
        cache.set(key("huge-1.png"), resource: resource, mediaType: .png, estimatedLength: 50_000_000)
        let evicted = cache.set(key("huge-2.png"), resource: resource, mediaType: .png, estimatedLength: 50_000_000)
        #expect(evicted.isEmpty)
        #expect(cache.lookup(key("huge-1.png")) != nil)
    }

    @Test func fullServeMeasuresProvisionalCost() {
        var cache = BoundedResourceCache(budget: 1000)
        cache.set(key("a.xhtml"), resource: resource, mediaType: .xhtml, estimatedLength: nil)
        // Provisional cost (the buffer window) exceeds the budget, but a
        // single entry always survives.
        #expect(cache.lookup(key("a.xhtml")) != nil)

        #expect(cache.recordFullServe(key("a.xhtml"), bytes: 300).isEmpty)
        #expect(cache.set(key("b.xhtml"), resource: resource, mediaType: .xhtml, estimatedLength: 400).isEmpty)
        // 300 + 400 + 400 exceeds the budget: the measured entry is now the
        // least recently used and goes first.
        let evicted = cache.set(key("c.xhtml"), resource: resource, mediaType: .xhtml, estimatedLength: 400)
        #expect(evicted == [key("a.xhtml")])
    }

    @Test func fullServeMeasuresOnlyOnce() {
        var cache = BoundedResourceCache(budget: 1000)
        cache.set(key("a.xhtml"), resource: resource, mediaType: .xhtml, estimatedLength: nil)
        cache.recordFullServe(key("a.xhtml"), bytes: 100)

        // A later (cached) serve of the same entry must not re-account it.
        #expect(cache.recordFullServe(key("a.xhtml"), bytes: 999_999).isEmpty)
        cache.set(key("b.xhtml"), resource: resource, mediaType: .xhtml, estimatedLength: 400)
        #expect(cache.set(key("c.xhtml"), resource: resource, mediaType: .xhtml, estimatedLength: 400).isEmpty)
    }

    @Test func newestEntrySurvivesEvenWhenAloneOverBudget() {
        var cache = BoundedResourceCache(budget: 1000)
        cache.set(key("giant.xhtml"), resource: resource, mediaType: .xhtml, estimatedLength: nil)
        #expect(cache.recordFullServe(key("giant.xhtml"), bytes: 5000).isEmpty)
        #expect(cache.lookup(key("giant.xhtml")) != nil)
    }

    @Test func replacingAKeyDoesNotDoubleCountItsCost() {
        var cache = BoundedResourceCache(budget: 1000)
        cache.set(key("a.xhtml"), resource: resource, mediaType: .xhtml, estimatedLength: 600)
        cache.set(key("a.xhtml"), resource: resource, mediaType: .xhtml, estimatedLength: 600)
        #expect(cache.set(key("b.xhtml"), resource: resource, mediaType: .xhtml, estimatedLength: 400).isEmpty)
    }

    @Test func removeRouteDropsOnlyThatRoutesEntries() {
        var cache = BoundedResourceCache(budget: 1000)
        cache.set(key("ch1.xhtml", route: "continuous/pub/aaa/"), resource: resource, mediaType: .xhtml, estimatedLength: 100)
        cache.set(key("ch1.xhtml", route: "continuous/pub/bbb/"), resource: resource, mediaType: .xhtml, estimatedLength: 100)

        cache.removeRoute(prefix: "continuous/pub/aaa")

        #expect(cache.lookup(key("ch1.xhtml", route: "continuous/pub/aaa/")) == nil)
        #expect(cache.lookup(key("ch1.xhtml", route: "continuous/pub/bbb/")) != nil)
    }

    @Test func removeWhereFiltersByKeyAndMediaType() {
        var cache = BoundedResourceCache(budget: 1000)
        cache.set(key("ch1.xhtml"), resource: resource, mediaType: .xhtml, estimatedLength: 100)
        cache.set(key("cover.png"), resource: resource, mediaType: .png, estimatedLength: 100)

        cache.remove { _, mediaType in mediaType.isHTML }

        #expect(cache.lookup(key("ch1.xhtml")) == nil)
        #expect(cache.lookup(key("cover.png")) != nil)
    }
}
