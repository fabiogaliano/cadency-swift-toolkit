//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import WebKit
import XCTest

/// Lifecycle unit tests for ``WrapperPreparationEngine`` exercised through its
/// public/internal interface with an injected clock and test warm-up handler —
/// no live WebKit needed for retry, backoff, foreground recovery, or take logic.
@MainActor
class WrapperPreparationEngineTests: XCTestCase {

    // MARK: - Helpers

    /// A controllable clock that records scheduled delays and lets the test fire them.
    @MainActor
    private final class TestClock {
        struct ScheduledAction {
            let delay: TimeInterval
            let action: @MainActor () -> Void
            let token: Token
        }

        final class Token {}

        @MainActor init() {}

        private(set) var scheduled: [ScheduledAction] = []
        private(set) var cancelledTokens: [ObjectIdentifier] = []

        func scheduleDelay(_ delay: TimeInterval, action: @escaping @MainActor () -> Void) -> AnyObject {
            let token = Token()
            scheduled.append(ScheduledAction(delay: delay, action: action, token: token))
            return token as AnyObject
        }

        func cancelScheduledDelay(_ token: AnyObject) {
            if let t = token as? Token {
                cancelledTokens.append(ObjectIdentifier(t))
            }
        }

        /// Fires the most recently scheduled action (simulates the delay elapsing).
        func fireLatest() {
            guard let last = scheduled.last else { return }
            last.action()
        }

        /// Fires all scheduled actions in order.
        func fireAll() {
            for entry in scheduled {
                entry.action()
            }
        }

        /// Returns delays of actions that were NOT cancelled.
        var activeDelays: [TimeInterval] {
            let cancelled = Set(cancelledTokens)
            return scheduled.filter { !cancelled.contains(ObjectIdentifier($0.token)) }
                .map(\.delay)
        }
    }

    /// Minimal HTTPServer stub — the engine only needs a non-nil reference.
    @MainActor
    private final class StubHTTPServer: HTTPServer {
        nonisolated func serve(at endpoint: HTTPServerEndpoint, handler: HTTPRequestHandler) throws -> HTTPURL {
            HTTPURL(string: "http://127.0.0.1:8080/\(endpoint)")!
        }

        nonisolated func transformResources(at endpoint: HTTPServerEndpoint, with transformer: @escaping ResourceTransformer) throws {}

        nonisolated func remove(at endpoint: HTTPServerEndpoint) throws {}
    }

    /// Creates a fresh engine with test seams wired up.
    @MainActor
    private func makeEngine(
        clock: TestClock? = nil,
        preparesWebView: Bool = false
    ) -> (engine: WrapperPreparationEngine, clock: TestClock) {
        let clock = clock ?? TestClock()
        let engine = WrapperPreparationEngine(observeAppLifecycle: false)
        engine.scheduleDelay = clock.scheduleDelay
        engine.cancelScheduledDelay = clock.cancelScheduledDelay
        if preparesWebView {
            let dummyWebView = WKWebView()
            engine.testWarmUpHandler = { [weak engine] in
                engine?.warmedWebView = dummyWebView
                return .pending
            }
        } else {
            engine.testWarmUpHandler = { .pending }
        }
        engine.httpServer = StubHTTPServer()
        return (engine, clock)
    }

    // MARK: - Warm-up state transitions

    func testWarmUpSetsWarmingState() {
        let (engine, _) = makeEngine()
        XCTAssertTrue(engine.warmUp())
        XCTAssertTrue(engine.isWarming)
        XCTAssertFalse(engine.isReady)
    }

    func testWarmUpIsNoOpWhenAlreadyWarming() {
        let (engine, _) = makeEngine()
        XCTAssertTrue(engine.warmUp())
        XCTAssertFalse(engine.warmUp(), "Second warmUp while warming should be a no-op")
    }

    func testWarmUpIsNoOpWhenAlreadyReady() {
        let (engine, _) = makeEngine()
        engine.warmUp()
        engine.warmUpDidSucceed()
        XCTAssertFalse(engine.warmUp(), "warmUp when already ready should be a no-op")
    }

    func testWarmUpIsNoOpWithoutHTTPServer() {
        let engine = WrapperPreparationEngine(observeAppLifecycle: false)
        engine.testWarmUpHandler = { .pending }
        // No httpServer set
        XCTAssertFalse(engine.warmUp())
        XCTAssertFalse(engine.isWarming)
    }

    // MARK: - Success

    func testSuccessfulWarmUpSetsReady() {
        let (engine, _) = makeEngine()
        engine.warmUp()
        engine.warmUpDidSucceed()

        XCTAssertTrue(engine.isReady)
        XCTAssertFalse(engine.isWarming)
        XCTAssertEqual(engine.retryCount, 0)
    }

    func testSuccessResetsRetryCount() {
        let (engine, clock) = makeEngine()
        var results: [WrapperPreparationEngine.TestWarmUpResult] = [
            .failed(reason: "test failure"),
            .succeeded,
        ]
        engine.testWarmUpHandler = {
            results.isEmpty ? .pending : results.removeFirst()
        }

        engine.start(httpServer: StubHTTPServer())
        XCTAssertEqual(engine.retryCount, 1)

        clock.fireLatest()

        XCTAssertEqual(engine.retryCount, 0, "Success should reset retry count")
    }

    // MARK: - Failure and retry with backoff

    func testFirstFailureSchedulesRetryAt1Second() {
        let (engine, clock) = makeEngine()
        engine.testWarmUpHandler = { .failed(reason: "test failure") }

        engine.start(httpServer: StubHTTPServer())

        XCTAssertFalse(engine.isWarming)
        XCTAssertFalse(engine.isReady)
        XCTAssertEqual(engine.retryCount, 1)
        XCTAssertEqual(clock.activeDelays, [1.0])
    }

    func testSecondFailureSchedulesRetryAt2Seconds() {
        let (engine, clock) = makeEngine()
        var results: [WrapperPreparationEngine.TestWarmUpResult] = [
            .failed(reason: "fail 1"),
            .failed(reason: "fail 2"),
        ]
        engine.testWarmUpHandler = {
            results.isEmpty ? .pending : results.removeFirst()
        }

        engine.start(httpServer: StubHTTPServer())
        clock.fireLatest()

        XCTAssertEqual(engine.retryCount, 2)
        XCTAssertEqual(clock.activeDelays.last, 2.0)
    }

    func testFourthFailureExhaustsRetries() {
        let (engine, clock) = makeEngine()
        var results: [WrapperPreparationEngine.TestWarmUpResult] = [
            .failed(reason: "fail 1"),
            .failed(reason: "fail 2"),
            .failed(reason: "fail 3"),
            .failed(reason: "fail 4"),
        ]
        engine.testWarmUpHandler = {
            results.isEmpty ? .pending : results.removeFirst()
        }

        engine.start(httpServer: StubHTTPServer())
        clock.fireLatest()
        clock.fireLatest()
        XCTAssertEqual(clock.activeDelays.last, 4.0)

        let scheduledBefore = clock.scheduled.count
        clock.fireLatest()

        XCTAssertEqual(engine.retryCount, 4)
        XCTAssertEqual(clock.scheduled.count, scheduledBefore,
                       "No retry should be scheduled after max attempts exhausted")
        XCTAssertFalse(engine.isWarming)
        XCTAssertFalse(engine.isReady)
    }

    // MARK: - take()

    func testTakeReturnsNilWhenNotReady() {
        let (engine, _) = makeEngine()
        XCTAssertNil(engine.take())
    }

    func testTakeReturnsNilWhileWarming() {
        let (engine, _) = makeEngine()
        engine.warmUp()
        XCTAssertNil(engine.take(), "Should not return a still-warming WebView")
    }

    func testTakeReturnsWebViewWhenReady() {
        let (engine, _) = makeEngine(preparesWebView: true)
        engine.warmUp()
        let sentinel = engine.warmedWebView
        engine.warmUpDidSucceed()

        let taken = engine.take()
        XCTAssertNotNil(taken)
        XCTAssertTrue(taken === sentinel)
        XCTAssertFalse(engine.isReady)
        XCTAssertNil(engine.warmedWebView)
    }

    func testTakeSchedulesReplacementAfterDelay() {
        let (engine, clock) = makeEngine(preparesWebView: true)
        engine.warmUp()
        engine.warmUpDidSucceed()

        _ = engine.take()

        // The replacement should be scheduled at the documented delay
        XCTAssertEqual(clock.activeDelays.last,
                       WrapperPreparationConstants.replacementDelaySeconds)
    }

    func testTakeCancelsPendingRetryAndReschedulesOffCriticalPath() {
        let (engine, clock) = makeEngine()
        engine.testWarmUpHandler = { .failed(reason: "warm-up failed") }

        // A warm-up failure leaves a retry scheduled at the 1 s backoff.
        engine.start(httpServer: StubHTTPServer())
        XCTAssertEqual(clock.activeDelays, [1.0])

        // A real open begins while that retry is still pending. Nothing is warm,
        // so the caller falls back to the cold path — but the retry must not be
        // allowed to fire inside the open window.
        XCTAssertNil(engine.take())

        XCTAssertFalse(clock.cancelledTokens.isEmpty,
                       "Pending retry token should be cancelled by take()")
        XCTAssertFalse(clock.activeDelays.contains(1.0),
                       "The 1 s retry should no longer be active after take()")
        XCTAssertEqual(clock.activeDelays.last,
                       WrapperPreparationConstants.replacementDelaySeconds,
                       "The next warm-up should be rescheduled off the critical path")
    }

    func testTakeReschedulesWarmUpEvenWhenNothingWarm() {
        let (engine, clock) = makeEngine()

        // Idle engine, no retry pending: take() still returns nil but arms a
        // replacement warm-up so a natural open remains a recovery trigger.
        XCTAssertNil(engine.take())
        XCTAssertEqual(clock.activeDelays.last,
                       WrapperPreparationConstants.replacementDelaySeconds)
    }

    func testWarmingFailureAfterTakeDefersRetryToReplacementDelay() {
        let (engine, clock) = makeEngine()
        engine.warmUp()

        // A book open starts while the warm-up is still in flight…
        XCTAssertNil(engine.take())

        // …and the in-flight warm-up then fails: its retry must not use the
        // short backoff, which would rebuild a WebView inside the open window.
        engine.warmUpDidFail(reason: "failed during live open")

        XCTAssertEqual(engine.retryCount, 1)
        XCTAssertEqual(clock.activeDelays.last,
                       WrapperPreparationConstants.replacementDelaySeconds)
    }

    func testWarmingFailureWithoutOverlappingOpenUsesBackoff() {
        let (engine, clock) = makeEngine(preparesWebView: true)
        engine.warmUp()
        XCTAssertNil(engine.take()) // arms the overlap deferral while warming
        engine.warmUpDidSucceed()   // success must clear it

        _ = engine.take()
        engine.warmUp()
        engine.warmUpDidFail(reason: "later, unrelated failure")

        XCTAssertEqual(clock.activeDelays.last, 1.0,
                       "A failure with no live open racing it uses the normal backoff")
    }

    // MARK: - Foreground recovery

    func testForegroundResetsRetryCount() {
        let (engine, _) = makeEngine()
        engine.warmUp()
        engine.warmUpDidFail(reason: "fail 1")
        engine.warmUpDidFail(reason: "fail 2") // retryCount = 2
        XCTAssertEqual(engine.retryCount, 2)

        engine.handleAppWillEnterForeground()
        XCTAssertEqual(engine.retryCount, 0)
    }

    func testForegroundTriggersWarmUpWhenNotWarmOrWarming() {
        let (engine, _) = makeEngine()

        // Exhaust retries so nothing is warm or warming
        engine.warmUp()
        engine.warmUpDidFail(reason: "fail 1")
        engine.warmUpDidFail(reason: "fail 2")
        engine.warmUpDidFail(reason: "fail 3")
        engine.warmUpDidFail(reason: "fail 4")
        XCTAssertFalse(engine.isWarming)
        XCTAssertFalse(engine.isReady)

        engine.handleAppWillEnterForeground()

        XCTAssertTrue(engine.isWarming, "Foreground should have triggered a fresh warm-up")
        XCTAssertEqual(engine.retryCount, 0)
    }

    func testForegroundDoesNotWarmUpWhenAlreadyReady() {
        let (engine, _) = makeEngine()
        engine.warmUp()
        engine.warmUpDidSucceed()
        XCTAssertTrue(engine.isReady)

        engine.handleAppWillEnterForeground()

        // Should stay ready, not start a second warm-up
        XCTAssertTrue(engine.isReady)
        XCTAssertFalse(engine.isWarming)
    }

    func testForegroundCancelsPendingRetry() {
        let (engine, clock) = makeEngine()
        engine.warmUp()
        engine.warmUpDidFail(reason: "test") // schedules retry

        engine.handleAppWillEnterForeground()

        // The old retry token should have been cancelled
        XCTAssertFalse(clock.cancelledTokens.isEmpty,
                       "Foreground should cancel any pending retry token")
        // A new warm-up should have started directly (not via the old retry)
        XCTAssertTrue(engine.isWarming)
    }

    // MARK: - start()

    func testStartSetsHTTPServerAndWarmsUp() {
        let engine = WrapperPreparationEngine(observeAppLifecycle: false)
        engine.testWarmUpHandler = { .pending }

        engine.start(httpServer: StubHTTPServer())

        XCTAssertNotNil(engine.httpServer)
        XCTAssertTrue(engine.isWarming)
    }

    func testStartIsNoOpWhenAlreadyWarmingAndKeepsFirstServer() {
        let engine = WrapperPreparationEngine(observeAppLifecycle: false)
        engine.testWarmUpHandler = { .pending }
        let firstServer = StubHTTPServer()

        engine.start(httpServer: firstServer)
        XCTAssertTrue(engine.isWarming)

        engine.start(httpServer: StubHTTPServer())

        XCTAssertTrue(engine.isWarming)
        XCTAssertTrue((engine.httpServer as? StubHTTPServer) === firstServer)
    }

    // MARK: - Constants sanity

    func testBackoffIntervalsMatchMaxRetries() {
        // The backoff array should have enough entries for maxRetryAttempts
        // (clamped, so having fewer is fine — but having zero would break retry).
        XCTAssertGreaterThan(WrapperPreparationConstants.retryBackoffSeconds.count, 0)
        XCTAssertGreaterThan(WrapperPreparationConstants.maxRetryAttempts, 0)
    }
}
