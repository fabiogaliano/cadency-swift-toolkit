//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import WebKit

@MainActor
extension WKWebView {
    func evaluateInBridgeWorld(
        _ script: String,
        completionHandler: @escaping @MainActor (Result<Any, Error>) -> Void
    ) {
        evaluateJavaScript(
            script,
            in: nil,
            in: WrapperPreparationEngine.contentWorld,
            completionHandler: completionHandler
        )
    }

    func callAsyncInBridgeWorld(
        _ functionBody: String,
        completionHandler: @escaping @MainActor (Result<Any, Error>) -> Void
    ) {
        callAsyncJavaScript(
            functionBody,
            in: nil,
            in: WrapperPreparationEngine.contentWorld,
            completionHandler: completionHandler
        )
    }
}
