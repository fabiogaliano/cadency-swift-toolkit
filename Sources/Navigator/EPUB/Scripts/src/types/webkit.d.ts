// Ambient declaration for the WKWebView JS-to-native message bridge that the
// host app injects as a global `webkit` object before any bundle runs. This
// is not the DOM lib's `WebKitNamespace` - Safari/WebKit browsers don't have
// one; it's the native `WKUserContentController` handler map, added by
// `WKWebViewConfiguration.userContentController.add(_:name:)` in the Swift
// navigator, one entry per handler name below.
//
// Handler names are exactly the set found in
// `webkit.messageHandlers.<name>.postMessage(...)` call sites across
// src/**/*.js (grepped, not guessed - see
// docs/tmp/orchestration-005-006-decisions.md, Plan 006 Step 1-2). Payloads
// stay `unknown`: the native `WKScriptMessageHandler` is what actually
// decodes and validates them (Swift DTO validation), so a TS shape here
// would just be an unenforced, driftable guess at the wire format.

interface WebKitMessageHandler {
  postMessage(payload: unknown): void;
}

declare const webkit: {
  messageHandlers: {
    blockActivated: WebKitMessageHandler;
    chapterMounted: WebKitMessageHandler;
    decorationActivated: WebKitMessageHandler;
    keyEventReceived: WebKitMessageHandler;
    log: WebKitMessageHandler;
    logError: WebKitMessageHandler;
    pointerEventReceived: WebKitMessageHandler;
    progressionChanged: WebKitMessageHandler;
    selectionChanged: WebKitMessageHandler;
    spreadLoaded: WebKitMessageHandler;
    spreadLoadStarted: WebKitMessageHandler;
    tap: WebKitMessageHandler;
  };
};
