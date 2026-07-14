//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared
import WebKit

/// Pre-warms a continuous-wrapper `WKWebView` so a book open can adopt a page whose
/// WebContent process, wrapper HTML and JS are already booted — the dominant cost of a
/// cold open. The warmed page is book-agnostic: the spine only arrives later through
/// `continuousWrapper.initialize()`. Same-origin access to chapter iframes holds because
/// warming serves the shared `readium` assets endpoint first, which starts the HTTP
/// server and pins its port for the lifetime of the process.
@MainActor
public final class ContinuousWrapperPreloader: NSObject {
    public static let shared = ContinuousWrapperPreloader()

    private var httpServer: HTTPServer?
    private var warmedWebView: WKWebView?
    private var isReady = false

    override private init() {}

    /// Starts booting a wrapper web view in the background. Call once at app launch;
    /// calling again while an instance is warm or warming is a no-op.
    public func warmUp(httpServer: HTTPServer) {
        self.httpServer = httpServer
        guard warmedWebView == nil else { return }

        guard
            let staticAssets = Bundle.module.resourceURL?.fileURL?
            .appendingPath("Assets/Static", isDirectory: true),
            let assetsURL = try? httpServer.serve(at: "readium", contentsOf: staticAssets),
            let wrapperURL = Bundle.module.url(forResource: "continuous-wrapper", withExtension: "html", subdirectory: "Assets"),
            var html = try? String(contentsOf: wrapperURL)
        else { return }

        html = html.replacingOccurrences(of: "{{ASSETS_URL}}", with: assetsURL.string)

        let webView = EPUBContinuousNavigatorViewController.makeWrapperWebView()
        webView.navigationDelegate = self
        // The wrapper only resolves absolute URLs, so the base URL's sole job is giving
        // the page the localhost origin that chapter iframes will be served from.
        webView.loadHTMLString(html, baseURL: assetsURL.url)
        warmedWebView = webView
    }

    /// Returns a fully booted wrapper web view, or nil when none is ready yet — the
    /// caller then falls back to the cold load path (a still-warming instance is kept
    /// for the next open). Taking one schedules a replacement warm-up off the critical
    /// path of the current open.
    func take() -> WKWebView? {
        guard isReady, let webView = warmedWebView else { return nil }
        warmedWebView = nil
        isReady = false
        webView.navigationDelegate = nil

        if let httpServer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.warmUp(httpServer: httpServer)
            }
        }
        return webView
    }

    private func discardWarmedWebView() {
        warmedWebView = nil
        isReady = false
    }
}

extension ContinuousWrapperPreloader: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        webView.evaluateJavaScript("typeof continuousWrapper !== 'undefined'") { [weak self] result, _ in
            guard let self, webView === self.warmedWebView else { return }
            if (result as? Bool) == true {
                self.isReady = true
            } else {
                self.discardWarmedWebView()
            }
        }
    }

    public func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError _: Error) {
        guard webView === warmedWebView else { return }
        discardWarmedWebView()
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) {
        guard webView === warmedWebView else { return }
        discardWarmedWebView()
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === warmedWebView else { return }
        discardWarmedWebView()
    }
}
