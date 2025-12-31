# JavaScript Integration

> **Purpose**: WebView JavaScript for EPUB rendering, gestures, and communication

## Overview

EPUB content is rendered in WKWebView with injected JavaScript that handles:
- Pagination and scrolling
- Gesture recognition
- Text selection
- Decoration rendering
- Swift ↔ JS communication

## File Locations

### Source Files (Development)
```
Sources/Navigator/EPUB/Scripts/src/
├── index.js                    # Main entry
├── index-reflowable.js         # Reflowable pagination
├── index-fixed.js              # Fixed-layout support
├── index-fixed-wrapper-one.js  # Single-page FXL
├── index-fixed-wrapper-two.js  # Two-page FXL spread
├── index-continuous-wrapper.js # Continuous scroll (NEW)
├── utils.js                    # Error handling, observers
├── dom.js                      # DOM utilities
├── gestures.js                 # Touch/mouse handling
├── keyboard.js                 # Keyboard events
├── selection.js                # Text selection
├── rect.js                     # Bounding rectangles
├── decorator.js                # Highlight rendering
└── fixed-page.js               # FXL page handling
```

### Built Files (Bundle)
```
Sources/Navigator/EPUB/Assets/Static/scripts/
├── readium-reflowable.js
├── readium-fixed.js
├── readium-continuous-wrapper.js
├── readium-continuous-wrapper-shim.js
├── readium-fixed-wrapper-one.js
└── readium-fixed-wrapper-two.js
```

### Build System
```
Sources/Navigator/EPUB/Scripts/
├── webpack.config.js           # Webpack bundling
├── package.json
└── src/                        # Source files
```

---

## Swift ↔ JavaScript Communication

### Swift to JavaScript

```swift
// Execute JavaScript
webView.evaluateJavaScript("readium.scrollToId('chapter1')")

// With completion
webView.evaluateJavaScript("readium.getSelection()") { result, error in
    if let selection = result as? [String: Any] {
        // Handle selection
    }
}
```

### JavaScript to Swift

Using WKScriptMessageHandler:

```swift
// Swift side
webView.configuration.userContentController.add(self, name: "readium")

func userContentController(_ controller: WKUserContentController,
                          didReceive message: WKScriptMessage) {
    guard let body = message.body as? [String: Any],
          let event = body["event"] as? String else { return }

    switch event {
    case "tap":
        handleTap(body)
    case "selection":
        handleSelection(body)
    case "progress":
        handleProgress(body)
    }
}
```

```javascript
// JavaScript side
window.webkit.messageHandlers.readium.postMessage({
    event: "tap",
    x: 100,
    y: 200
});
```

---

## Reflowable EPUB JavaScript

**File**: `index-reflowable.js`

### Pagination

```javascript
// readium-reflowable.js (conceptual)

class ReadiumReflowable {
    constructor() {
        this.pageWidth = window.innerWidth;
        this.columnCount = 1;
    }

    // Calculate total columns
    get totalColumns() {
        const body = document.body;
        const scrollWidth = body.scrollWidth;
        return Math.ceil(scrollWidth / this.pageWidth);
    }

    // Navigate to page
    goToPage(pageIndex) {
        const offset = pageIndex * this.pageWidth;
        document.scrollingElement.scrollLeft = offset;
    }

    // Calculate current page
    get currentPage() {
        const scrollLeft = document.scrollingElement.scrollLeft;
        return Math.floor(scrollLeft / this.pageWidth);
    }
}
```

### Scroll Position Mapping

```javascript
// Map CSS selector to position
function getPositionForSelector(selector) {
    const element = document.querySelector(selector);
    if (!element) return null;

    const rect = element.getBoundingClientRect();
    const column = Math.floor(rect.left / pageWidth);
    const progression = column / totalColumns;

    return { column, progression };
}

// Map position to visible element
function getVisibleElementAtPosition(progression) {
    const targetScroll = progression * document.body.scrollWidth;

    // Find element at scroll position
    const elements = document.querySelectorAll('[id]');
    for (const el of elements) {
        const rect = el.getBoundingClientRect();
        if (rect.left >= 0 && rect.left < pageWidth) {
            return el;
        }
    }
}
```

---

## Continuous Scroll JavaScript (NEW)

**File**: `index-continuous-wrapper.js`

### HTML Structure

```html
<!-- continuous-wrapper.html -->
<div id="chapters-container">
    <!-- Chapter 1: Mounted iframe -->
    <div class="chapter-wrapper" data-index="0" data-state="loaded">
        <iframe src="chapter1.xhtml"></iframe>
    </div>

    <!-- Chapter 2: Unmounted spacer -->
    <div class="chapter-wrapper" data-index="1" data-state="spacer">
        <div class="spacer" style="height: 1500px"></div>
    </div>

    <!-- Chapter 3: Mounted iframe -->
    <div class="chapter-wrapper" data-index="2" data-state="loaded">
        <iframe src="chapter3.xhtml"></iframe>
    </div>
</div>
```

### Chapter State Machine

```javascript
// Chapter states
const ChapterState = {
    SPACER: 'spacer',    // Not loaded, shows spacer
    LOADING: 'loading',  // Loading content
    LOADED: 'loaded',    // Fully rendered
    ERROR: 'error'       // Failed to load
};

class ContinuousWrapper {
    constructor() {
        this.chapters = [];          // Chapter metadata
        this.heights = new Map();    // index -> height
        this.mountedRange = { start: 0, end: 0 };
        this.maxMounted = 7;
    }

    // Mount chapter (load iframe)
    async mountChapter(index) {
        const wrapper = this.getWrapper(index);
        wrapper.dataset.state = ChapterState.LOADING;

        const iframe = document.createElement('iframe');
        iframe.src = this.chapters[index].href;

        // Wait for load
        await new Promise(resolve => {
            iframe.onload = resolve;
        });

        // Track height
        this.observeHeight(index, iframe);
        wrapper.dataset.state = ChapterState.LOADED;
    }

    // Unmount chapter (replace with spacer)
    unmountChapter(index) {
        const wrapper = this.getWrapper(index);
        const height = this.heights.get(index) || this.defaultHeight;

        wrapper.innerHTML = `<div class="spacer" style="height: ${height}px"></div>`;
        wrapper.dataset.state = ChapterState.SPACER;
    }
}
```

### Height Tracking

```javascript
// Track chapter heights with ResizeObserver
observeHeight(index, iframe) {
    const observer = new ResizeObserver(entries => {
        const height = entries[0].contentRect.height;
        const oldHeight = this.heights.get(index);

        if (height !== oldHeight) {
            this.heights.set(index, height);
            this.applyHeightChange(index, oldHeight, height);
        }
    });

    observer.observe(iframe.contentDocument.body);
}

// Apply height change with scroll anchoring
applyHeightChange(index, oldHeight, newHeight) {
    const delta = newHeight - (oldHeight || this.defaultHeight);

    // If chapter is above viewport, adjust scroll
    if (index < this.getCenterChapterIndex()) {
        this.withProgrammaticScroll(() => {
            window.scrollBy(0, delta);
        });
    }
}
```

### Scroll Anchoring

```javascript
// Prevent visual jumps during height changes
let programmaticScrollActive = false;

function withProgrammaticScroll(fn) {
    programmaticScrollActive = true;
    fn();
    requestAnimationFrame(() => {
        programmaticScrollActive = false;
    });
}

function isProgrammaticScrollActive() {
    return programmaticScrollActive;
}

// Detect center chapter for sliding window
function computeCenterChapterIndex() {
    const viewportCenter = window.scrollY + window.innerHeight / 2;
    let accumulatedHeight = 0;

    for (let i = 0; i < chapters.length; i++) {
        accumulatedHeight += heights.get(i) || defaultHeight;
        if (accumulatedHeight > viewportCenter) {
            return i;
        }
    }
    return chapters.length - 1;
}
```

### Visibility Detection

```javascript
// IntersectionObserver for chapter visibility
const visibilityObserver = new IntersectionObserver(
    entries => {
        entries.forEach(entry => {
            const index = parseInt(entry.target.dataset.index);
            if (entry.isIntersecting) {
                onChapterVisible(index);
            } else {
                onChapterHidden(index);
            }
        });
    },
    { rootMargin: '100% 0px' }  // Preload margin
);

function onChapterVisible(index) {
    // Ensure chapter is mounted
    if (getState(index) === ChapterState.SPACER) {
        mountChapter(index);
    }
}
```

---

## Gesture Handling

**File**: `gestures.js`

```javascript
// Touch gesture detection
class GestureHandler {
    constructor() {
        this.startX = 0;
        this.startY = 0;
        this.startTime = 0;
    }

    onTouchStart(event) {
        this.startX = event.touches[0].clientX;
        this.startY = event.touches[0].clientY;
        this.startTime = Date.now();
    }

    onTouchEnd(event) {
        const endX = event.changedTouches[0].clientX;
        const endY = event.changedTouches[0].clientY;
        const deltaX = endX - this.startX;
        const deltaY = endY - this.startY;
        const duration = Date.now() - this.startTime;

        // Tap detection
        if (Math.abs(deltaX) < 10 && Math.abs(deltaY) < 10 && duration < 300) {
            this.handleTap(endX, endY);
            return;
        }

        // Swipe detection
        if (Math.abs(deltaX) > 50 && Math.abs(deltaX) > Math.abs(deltaY)) {
            if (deltaX > 0) {
                this.handleSwipeRight();
            } else {
                this.handleSwipeLeft();
            }
        }
    }

    handleTap(x, y) {
        window.webkit.messageHandlers.readium.postMessage({
            event: 'tap',
            x: x,
            y: y,
            width: window.innerWidth,
            height: window.innerHeight
        });
    }
}
```

---

## Text Selection

**File**: `selection.js`

```javascript
// Handle text selection
document.addEventListener('selectionchange', () => {
    const selection = window.getSelection();

    if (selection.isCollapsed) {
        notifySelectionCleared();
        return;
    }

    const range = selection.getRangeAt(0);
    const text = selection.toString();
    const rect = range.getBoundingClientRect();

    window.webkit.messageHandlers.readium.postMessage({
        event: 'selection',
        text: text,
        before: getTextBefore(range, 50),
        after: getTextAfter(range, 50),
        rect: {
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height
        },
        cssSelector: getCSSSelector(range.startContainer)
    });
});

function getCSSSelector(element) {
    // Build unique CSS selector path
    const path = [];
    while (element && element.nodeType === Node.ELEMENT_NODE) {
        let selector = element.tagName.toLowerCase();
        if (element.id) {
            selector = '#' + element.id;
            path.unshift(selector);
            break;
        }
        // Add :nth-child for uniqueness
        const siblings = element.parentNode.children;
        const index = Array.from(siblings).indexOf(element) + 1;
        selector += `:nth-child(${index})`;
        path.unshift(selector);
        element = element.parentNode;
    }
    return path.join(' > ');
}
```

---

## Decoration Rendering

**File**: `decorator.js`

```javascript
// Render highlights and annotations
class Decorator {
    constructor() {
        this.groups = new Map();  // group name -> decorations
    }

    apply(groupName, decorations) {
        // Remove existing decorations for group
        this.clear(groupName);

        // Create decoration elements
        decorations.forEach(decoration => {
            const element = this.createDecoration(decoration);
            document.body.appendChild(element);
        });

        this.groups.set(groupName, decorations);
    }

    createDecoration(decoration) {
        const { locator, style } = decoration;

        // Find target range
        const range = this.locatorToRange(locator);
        if (!range) return null;

        // Get bounding rectangles (may span multiple lines)
        const rects = range.getClientRects();

        // Create highlight wrapper
        const container = document.createElement('div');
        container.className = 'readium-decoration';
        container.dataset.decorationId = decoration.id;

        // Create box for each rect
        Array.from(rects).forEach(rect => {
            const box = document.createElement('div');
            box.className = 'decoration-box';
            box.style.cssText = `
                position: absolute;
                left: ${rect.left}px;
                top: ${rect.top}px;
                width: ${rect.width}px;
                height: ${rect.height}px;
                background-color: ${style.tint};
                opacity: 0.3;
                pointer-events: none;
            `;
            container.appendChild(box);
        });

        return container;
    }

    locatorToRange(locator) {
        // Use CSS selector or text matching
        const { cssSelector, textBefore, textAfter } = locator.locations;

        if (cssSelector) {
            return this.rangeFromSelector(cssSelector);
        }

        // Fallback: text matching
        return this.rangeFromText(locator.text);
    }
}
```

---

## CSS Injection

### Readium CSS

**Location**: `Sources/Navigator/EPUB/Assets/Static/readium-css/`

Pre-built CSS framework injected into every EPUB:

```css
/* readium-css (excerpt) */
:root {
    --USER__fontSize: 100%;
    --USER__fontFamily: Original, serif;
    --USER__textColor: inherit;
    --USER__backgroundColor: transparent;
    --USER__lineHeight: 1.5;
}

body {
    font-size: var(--USER__fontSize);
    font-family: var(--USER__fontFamily);
    color: var(--USER__textColor);
    background-color: var(--USER__backgroundColor);
    line-height: var(--USER__lineHeight);
}
```

### Preference Application

```swift
// Swift side: Set CSS variables
func applyPreferences(_ prefs: EPUBPreferences) {
    var css = ":root {"

    if let fontSize = prefs.fontSize {
        css += "--USER__fontSize: \(fontSize * 100)%;"
    }
    if let fontFamily = prefs.fontFamily {
        css += "--USER__fontFamily: \(fontFamily.name);"
    }
    // ... more preferences

    css += "}"

    webView.evaluateJavaScript("readium.setUserStyle(`\(css)`)")
}
```

---

## Build Process

```bash
# In Sources/Navigator/EPUB/Scripts/
npm install
npm run build

# Outputs to Assets/Static/scripts/
```

### Webpack Configuration

```javascript
// webpack.config.js
module.exports = {
    entry: {
        'readium-reflowable': './src/index-reflowable.js',
        'readium-fixed': './src/index-fixed.js',
        'readium-continuous-wrapper': './src/index-continuous-wrapper.js',
        // ...
    },
    output: {
        path: path.resolve(__dirname, '../Assets/Static/scripts'),
        filename: '[name].js'
    },
    mode: 'production'
};
```
