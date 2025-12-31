# Navigator Deep Dive

> **Purpose**: Detailed reference for the Navigator module and rendering system

## Navigator Protocol Hierarchy

```
                        Navigator (base)
                            │
            ┌───────────────┼───────────────┐
            │               │               │
     VisualNavigator   AudioNavigator    (Future)
            │
    ┌───────┴───────┐
    │               │
SelectableNavigator DecorableNavigator
```

## Core Protocols

### Navigator (Base)

**File**: `Sources/Navigator/Navigator.swift`

```swift
public protocol Navigator: AnyObject {
    /// Current reading position
    var currentLocation: Locator? { get }

    /// Navigate to a specific location
    func go(to locator: Locator) async -> Bool

    /// Navigate to a link in the publication
    func go(to link: Link, parameters: HREFParameters) async -> Bool

    /// Move forward in reading order
    func goForward() async -> Bool

    /// Move backward in reading order
    func goBackward() async -> Bool
}
```

### VisualNavigator

**File**: `Sources/Navigator/VisualNavigator.swift`

Extends Navigator for visual content (EPUB, PDF, CBZ):

```swift
public protocol VisualNavigator: Navigator {
    /// Current presentation settings
    var presentation: VisualNavigatorPresentation { get }

    /// Navigate left (may differ from backward in RTL)
    func goLeft() async -> Bool

    /// Navigate right
    func goRight() async -> Bool

    /// First visible element for current spread
    func firstVisibleElementLocator() async -> Locator?

    /// Input event handling
    var inputObservable: InputObservable { get }
}

public struct VisualNavigatorPresentation {
    public let readingProgression: ReadingProgression
    public let scroll: Bool              // Scrolling vs. pagination
    public let axis: Axis                // Horizontal or vertical
}
```

### SelectableNavigator

**File**: `Sources/Navigator/SelectableNavigator.swift`

Text selection support:

```swift
public protocol SelectableNavigator: Navigator {
    /// Currently selected text
    var currentSelection: Selection? { get }

    /// Clear selection
    func clearSelection()
}

public struct Selection {
    public let locator: Locator    // Location of selection
    public let frame: CGRect?      // Visual bounds
}
```

### DecorableNavigator

**File**: `Sources/Navigator/Decorator/DecorableNavigator.swift`

Overlay decorations (highlights, annotations):

```swift
public protocol DecorableNavigator: Navigator {
    /// Apply decorations in a named group
    func apply(decorations: [Decoration], in group: String)
}

public struct Decoration: Hashable {
    public let id: ID
    public let locator: Locator
    public let style: Style

    public enum Style: Hashable {
        case highlight(tint: UIColor, isActive: Bool)
        case underline(tint: UIColor)
        case custom(id: String, config: [String: Any])
    }
}
```

---

## EPUB Navigator Implementations

### EPUBNavigatorViewController (Paginated)

**File**: `Sources/Navigator/EPUB/EPUBNavigatorViewController.swift`

The standard paginated EPUB reader:

```swift
public class EPUBNavigatorViewController: UIViewController,
    VisualNavigator, SelectableNavigator, DecorableNavigator {

    public init(
        publication: Publication,
        config: Configuration,
        httpServer: HTTPServer
    )

    public struct Configuration {
        public var preferences: EPUBPreferences
        public var defaults: EPUBDefaults
        public var decorationTemplates: [String: HTMLDecorationTemplate]
        public var fontFamilyDeclarations: [FontFamilyDeclaration]
        public var preloadPreviousPositionCount: Int
        public var preloadNextPositionCount: Int
    }
}
```

**Architecture**:
```
EPUBNavigatorViewController
├── PaginationView (UICollectionView)
│   ├── EPUBSpreadView (cell 1)
│   │   └── WKWebView
│   ├── EPUBSpreadView (cell 2)
│   │   └── WKWebView
│   └── ...
├── HTTPServer (serves resources)
└── EPUBNavigatorDelegate
```

### EPUBContinuousNavigatorViewController (Continuous Scroll)

**File**: `Sources/Navigator/EPUB/EPUBContinuousNavigatorViewController.swift`

**NEW**: Vertical continuous scrolling mode:

```swift
public class EPUBContinuousNavigatorViewController: UIViewController,
    VisualNavigator, SelectableNavigator, DecorableNavigator {

    public init(
        publication: Publication,
        config: Configuration,
        httpServer: HTTPServer
    )

    public struct Configuration {
        public var preferences: EPUBPreferences
        public var prefetchBehind: Int      // Chapters to preload before
        public var prefetchAhead: Int       // Chapters to preload after
        public var maxMountedChapters: Int  // Total iframes cap
        public var defaultChapterHeight: CGFloat
    }
}
```

**Architecture**:
```
EPUBContinuousNavigatorViewController
├── WKWebView (single, scrollable)
│   ├── continuous-wrapper.html
│   │   ├── Chapter iframe 1
│   │   ├── Chapter spacer (unmounted)
│   │   ├── Chapter iframe 3
│   │   └── ...
│   └── JavaScript orchestration
├── HTTPServer (serves resources)
└── Scroll anchoring system
```

**Key Concepts**:
- Single WKWebView with embedded iframes
- Sliding window: Only N chapters mounted at once
- Spacers replace unmounted chapters (preserve scroll position)
- ResizeObserver tracks chapter heights
- IntersectionObserver detects visible chapters

---

## PDF Navigator

**File**: `Sources/Navigator/PDF/PDFNavigatorViewController.swift`

```swift
public class PDFNavigatorViewController: UIViewController,
    VisualNavigator, SelectableNavigator {

    public init(
        publication: Publication,
        config: Configuration
    )

    public struct Configuration {
        public var preferences: PDFPreferences
        public var editingActions: [EditingAction]
    }
}
```

**Architecture**:
```
PDFNavigatorViewController
├── PDFDocumentView
│   └── PDFView (PDFKit)
├── PDFDocumentHolder
└── PDFTapGestureController
```

---

## Audio Navigator

**File**: `Sources/Navigator/Audiobook/AudioNavigator.swift`

```swift
public class AudioNavigator: Navigator {
    public init(
        publication: Publication,
        config: Configuration
    )

    /// Playback state
    public var playbackInfo: MediaPlaybackInfo { get }

    /// Control playback
    public func play()
    public func pause()
    public func seek(to time: TimeInterval)

    public struct Configuration {
        public var preferences: AudioPreferences
    }
}

public struct MediaPlaybackInfo {
    public let resourceIndex: Int
    public let state: State          // paused, loading, playing
    public let time: TimeInterval
    public let duration: TimeInterval
    public let progress: Double
    public let buffered: TimeInterval
}
```

---

## CBZ Navigator

**File**: `Sources/Navigator/CBZ/CBZNavigatorViewController.swift`

```swift
public class CBZNavigatorViewController: UIViewController, VisualNavigator {
    public init(
        publication: Publication,
        httpServer: HTTPServer
    )
}
```

**Architecture**:
```
CBZNavigatorViewController
├── UIPageViewController
│   ├── ImageViewController (page 1)
│   ├── ImageViewController (page 2)
│   └── ...
└── HTTPServer
```

---

## Preferences System

### EPUBPreferences

**File**: `Sources/Navigator/EPUB/Preferences/EPUBPreferences.swift`

```swift
public struct EPUBPreferences: Hashable {
    // Typography
    public var fontFamily: FontFamily?
    public var fontSize: Double?           // em or %
    public var fontWeight: Double?
    public var lineHeight: Double?
    public var letterSpacing: Double?
    public var paragraphSpacing: Double?
    public var hyphens: Bool?

    // Appearance
    public var theme: Theme?               // light, dark, sepia
    public var textColor: Color?
    public var backgroundColor: Color?
    public var imageFilter: ImageFilter?   // darken, invert

    // Layout
    public var columnCount: ColumnCount?   // auto, 1, 2
    public var scroll: Bool?               // scroll vs. paginate
    public var spread: Spread?             // auto, never, always
    public var pageMargins: Double?

    // Content
    public var publisherStyles: Bool?      // Use publisher CSS
    public var readingProgression: ReadingProgression?
    public var language: Language?
}
```

### Using Preferences

```swift
// Create preferences
var prefs = EPUBPreferences()
prefs.fontSize = 1.2
prefs.theme = .dark
prefs.scroll = true

// Apply to navigator
navigator.submitPreferences(prefs)

// React to changes
navigator.delegate.navigator(navigator, preferencesDidChange: prefs)
```

---

## Input Handling

### Input Observable

**File**: `Sources/Navigator/Input/InputObservable.swift`

```swift
public protocol InputObservable {
    func addObserver<T: InputObserver>(_ observer: T) -> ObserverToken
    func removeObserver(for token: ObserverToken)
}

// Key events
public protocol KeyObserver: InputObserver {
    func didPressKey(_ event: KeyEvent) -> Bool
}

// Pointer events (touch/mouse)
public protocol ActivatePointerObserver: InputObserver {
    func didActivate(at point: CGPoint, event: PointerEvent) -> Bool
}

public protocol DragPointerObserver: InputObserver {
    func didDrag(from: CGPoint, to: CGPoint, event: PointerEvent) -> Bool
}
```

### Key Events

```swift
public struct KeyEvent {
    public let key: Key
    public let modifiers: KeyModifiers
    public let characters: String?
}

public struct Key: Hashable {
    public static let arrowLeft = Key(...)
    public static let arrowRight = Key(...)
    public static let space = Key(...)
    // ...
}

public struct KeyModifiers: OptionSet {
    public static let shift = KeyModifiers(...)
    public static let control = KeyModifiers(...)
    public static let option = KeyModifiers(...)
    public static let command = KeyModifiers(...)
}
```

---

## Decoration System

### Applying Decorations

```swift
// Create decorations for highlights
let decorations = highlights.map { highlight in
    Decoration(
        id: .init(highlight.id),
        locator: highlight.locator,
        style: .highlight(tint: highlight.color, isActive: false)
    )
}

// Apply to navigator
navigator.apply(decorations: decorations, in: "highlights")

// Clear group
navigator.apply(decorations: [], in: "highlights")
```

### Custom Decoration Templates

**File**: `Sources/Navigator/EPUB/HTMLDecorationTemplate.swift`

```swift
public struct HTMLDecorationTemplate {
    public let layout: Layout
    public let width: Width
    public let element: String    // HTML wrapper
    public let stylesheet: String // CSS

    public enum Layout {
        case boxes   // Wrap each text box
        case bounds  // Single wrapper for bounds
    }
}

// Example: Custom note icon
let noteTemplate = HTMLDecorationTemplate(
    layout: .bounds,
    width: .page,
    element: "<div class='note-icon'>📝</div>",
    stylesheet: ".note-icon { position: absolute; right: 10px; }"
)

config.decorationTemplates["note"] = noteTemplate
```

---

## Delegate Callbacks

### NavigatorDelegate

```swift
public protocol NavigatorDelegate: AnyObject {
    /// Location changed
    func navigator(_ navigator: Navigator, didJumpTo locator: Locator)

    /// Error occurred
    func navigator(_ navigator: Navigator, presentError error: NavigatorError)

    /// External link tapped
    func navigator(_ navigator: Navigator, shouldNavigateTo link: Link) -> Bool

    /// Content loaded
    func navigator(_ navigator: Navigator, didLoadWith locator: Locator)
}
```

### VisualNavigatorDelegate

```swift
public protocol VisualNavigatorDelegate: NavigatorDelegate {
    /// Tap outside content
    func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint)

    /// Key pressed
    func navigator(_ navigator: VisualNavigator, didPressKey event: KeyEvent) -> Bool

    /// Presentation changed
    func navigator(_ navigator: VisualNavigator, presentationDidChange presentation: VisualNavigatorPresentation)
}
```

### SelectableNavigatorDelegate

```swift
public protocol SelectableNavigatorDelegate: NavigatorDelegate {
    /// Selection changed
    func navigator(_ navigator: SelectableNavigator, selectionDidChange selection: Selection?)

    /// Customize selection menu
    func navigator(_ navigator: SelectableNavigator,
                   canPerformAction action: EditingAction,
                   for selection: Selection) -> Bool
}
```

---

## Common Patterns

### Navigate to Chapter

```swift
// By table of contents link
if let tocLink = publication.tableOfContents.first {
    await navigator.go(to: tocLink)
}

// By locator
let locator = Locator(href: "chapter1.xhtml", mediaType: .html)
await navigator.go(to: locator)
```

### Save/Restore Position

```swift
// Save
if let location = navigator.currentLocation {
    let json = location.jsonString
    UserDefaults.standard.set(json, forKey: "readingPosition")
}

// Restore
if let json = UserDefaults.standard.string(forKey: "readingPosition"),
   let locator = Locator(jsonString: json) {
    await navigator.go(to: locator)
}
```

### Handle Selection

```swift
class ReaderVC: UIViewController, SelectableNavigatorDelegate {
    func navigator(_ navigator: SelectableNavigator,
                   selectionDidChange selection: Selection?) {
        if let selection = selection {
            showHighlightMenu(for: selection)
        }
    }
}
```
