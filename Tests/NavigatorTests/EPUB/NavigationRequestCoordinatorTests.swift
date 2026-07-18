//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import Testing

@Suite @MainActor
struct NavigationRequestCoordinatorTests {
    @Test func supersedingARequestSettlesTheOlderCallerFalse() {
        let coordinator = NavigationRequestCoordinator<String>()
        var results: [Bool] = []
        let first = coordinator.begin("A") { results.append($0) }
        let second = coordinator.begin("B") { results.append($0) }

        #expect(results == [false])
        #expect(!coordinator.isCurrent(first))
        #expect(coordinator.isCurrent(second))
        #expect(coordinator.locator(for: second) == "B")
    }

    @Test func resolvesTheLatestCallerExactlyOnce() {
        let coordinator = NavigationRequestCoordinator<String>()
        var results: [Bool] = []
        let request = coordinator.begin("A") { results.append($0) }

        coordinator.resolve(request, result: true)
        coordinator.resolve(request, result: false)

        #expect(results == [true])
    }

    @Test func cancellationAndTeardownSettleEveryPendingCallerFalse() {
        let coordinator = NavigationRequestCoordinator<String>()
        var results: [Bool] = []
        let first = coordinator.begin("A") { results.append($0) }
        coordinator.cancel(first)
        let second = coordinator.begin("B") { results.append($0) }
        coordinator.cancelAll()

        #expect(results == [false, false])
        #expect(!coordinator.isCurrent(second))
    }
}
