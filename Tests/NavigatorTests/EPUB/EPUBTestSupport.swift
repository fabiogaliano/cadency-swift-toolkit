//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import UIKit
import WebKit

@MainActor
func findWebView(in view: UIView) -> WKWebView? {
    var queue: [UIView] = [view]
    while !queue.isEmpty {
        let candidate = queue.removeFirst()
        if let webView = candidate as? WKWebView {
            return webView
        }
        queue.append(contentsOf: candidate.subviews)
    }
    return nil
}
