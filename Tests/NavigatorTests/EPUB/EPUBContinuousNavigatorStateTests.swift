//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import Testing

/// The navigation state machine must never silently drop a jump requested
/// before loading completes: the initial (restore) location and any `go()`
/// during load become the pending locator, executed on load completion.
enum EPUBContinuousNavigatorStateTests {
    typealias State = EPUBContinuousNavigatorViewController.State

    struct Loading {
        @Test func loadCarriesTheInitialLocator() {
            var state = State.initializing
            let accepted = state.transition(.load(locator("restore.xhtml")))
            #expect(accepted)
            #expect(state == .loading(pendingLocator: locator("restore.xhtml")))
        }

        @Test func loadWithoutLocatorCarriesNone() {
            var state = State.initializing
            let accepted = state.transition(.load(nil))
            #expect(accepted)
            #expect(state == .loading(pendingLocator: nil))
        }

        @Test func jumpDuringLoadingIsDeferredNotRejected() {
            var state = State.loading(pendingLocator: nil)
            let accepted = state.transition(.jump(locator("toc-target.xhtml")))
            #expect(accepted)
            #expect(state == .loading(pendingLocator: locator("toc-target.xhtml")))
        }

        @Test func latestJumpDuringLoadingWins() {
            var state = State.loading(pendingLocator: locator("restore.xhtml"))
            let accepted = state.transition(.jump(locator("deep-link.xhtml")))
            #expect(accepted)
            #expect(state == .loading(pendingLocator: locator("deep-link.xhtml")))
        }

        @Test func loadedLeavesLoading() {
            var state = State.loading(pendingLocator: locator("restore.xhtml"))
            let accepted = state.transition(.loaded)
            #expect(accepted)
            #expect(state == .idle)
        }

        @Test func jumpedIsRejectedWhileLoading() {
            var state = State.loading(pendingLocator: nil)
            let accepted = state.transition(.jumped)
            #expect(!accepted)
            #expect(state == .loading(pendingLocator: nil))
        }
    }

    struct Jumping {
        @Test func idleAcceptsJump() {
            var state = State.idle
            let accepted = state.transition(.jump(locator("ch2.xhtml")))
            #expect(accepted)
            #expect(state == .jumping(pendingLocator: locator("ch2.xhtml")))
        }

        @Test func concurrentJumpIsRejected() {
            var state = State.jumping(pendingLocator: locator("ch2.xhtml"))
            let accepted = state.transition(.jump(locator("ch3.xhtml")))
            #expect(!accepted)
            #expect(state == .jumping(pendingLocator: locator("ch2.xhtml")))
        }

        @Test func jumpedReturnsToIdle() {
            var state = State.jumping(pendingLocator: locator("ch2.xhtml"))
            let accepted = state.transition(.jumped)
            #expect(accepted)
            #expect(state == .idle)
        }
    }

    struct Reload {
        /// A wrapper reload (CSS invalidation, process termination) can hit any
        /// state; the reload's locator becomes the pending restore target.
        @Test(arguments: [
            State.idle,
            State.jumping(pendingLocator: locator("ch2.xhtml")),
            State.loading(pendingLocator: nil),
        ])
        func loadFromAnyStateCarriesTheRestoreLocator(from: State) {
            var state = from
            let accepted = state.transition(.load(locator("current.xhtml")))
            #expect(accepted)
            #expect(state == .loading(pendingLocator: locator("current.xhtml")))
        }

        /// The in-flight jump's completion must not corrupt a reload that
        /// interrupted it.
        @Test func staleJumpedDuringReloadIsRejected() {
            var state = State.loading(pendingLocator: locator("current.xhtml"))
            let accepted = state.transition(.jumped)
            #expect(!accepted)
            #expect(state == .loading(pendingLocator: locator("current.xhtml")))
        }
    }

    struct Initializing {
        @Test func jumpBeforeLoadIsRejected() {
            var state = State.initializing
            let accepted = state.transition(.jump(locator("ch2.xhtml")))
            #expect(!accepted)
            #expect(state == .initializing)
        }

        @Test func loadedBeforeLoadIsRejected() {
            var state = State.initializing
            let accepted = state.transition(.loaded)
            #expect(!accepted)
            #expect(state == .initializing)
        }
    }
}

// MARK: - Helpers

private func locator(_ href: String) -> Locator {
    Locator(
        href: AnyURL(string: href)!,
        mediaType: .xhtml,
        locations: .init(progression: 0.42)
    )
}
