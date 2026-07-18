//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// Owns the one navigation request whose result may still reach a caller.
/// Replacing it always settles the previous caller before accepting the next.
@MainActor
final class NavigationRequestCoordinator<Locator> {
    typealias Completion = (Bool) -> Void

    private struct Request {
        let id: UUID
        let locator: Locator
        let completion: Completion?
    }

    private var request: Request?

    @discardableResult
    func begin(_ locator: Locator, completion: Completion? = nil, id: UUID = UUID()) -> UUID {
        cancelAll()
        request = Request(id: id, locator: locator, completion: completion)
        return id
    }

    var currentID: UUID? { request?.id }
    var currentLocator: Locator? { request?.locator }

    func locator(for id: UUID) -> Locator? {
        guard request?.id == id else { return nil }
        return request?.locator
    }

    func isCurrent(_ id: UUID) -> Bool {
        request?.id == id
    }

    func resolve(_ id: UUID, result: Bool) {
        guard let request, request.id == id else { return }
        self.request = nil
        request.completion?(result)
    }

    func cancel(_ id: UUID) {
        resolve(id, result: false)
    }

    func cancelAll() {
        guard let request else { return }
        self.request = nil
        request.completion?(false)
    }
}
