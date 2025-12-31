# Core Data Models

> **Purpose**: Reference for key data structures and their relationships

## Publication Hierarchy

```
Publication
├── manifest: Manifest
│   ├── metadata: Metadata
│   │   ├── title: LocalizedString
│   │   ├── authors: [Contributor]
│   │   ├── languages: [String]
│   │   ├── readingProgression: ReadingProgression
│   │   └── ...
│   ├── readingOrder: [Link]
│   ├── resources: [Link]
│   ├── tableOfContents: [Link]
│   └── links: [Link]
├── container: Container
└── services: [PublicationService]
```

---

## Publication

**File**: `Sources/Shared/Publication/Publication.swift`

The main class representing a digital publication.

```swift
public final class Publication {
    public let manifest: Manifest
    public let container: Container

    // Service discovery
    public func findService<T>(_ type: T.Type) -> T?

    // Resource access
    public func get(_ link: Link) -> Resource?
    public func get<T: URLConvertible>(_ href: T) -> Resource?

    // Link search
    public func linkWithRel(_ rel: LinkRelation) -> Link?
    public func linkWithHREF(_ href: String) -> Link?
}
```

**Key Concepts**:
- Immutable after construction (built via `Publication.Builder`)
- Services are discoverable by type
- Resources accessed through container

---

## Manifest

**File**: `Sources/Shared/Publication/Manifest.swift`

The complete publication structure per Readium Web Publication spec.

```swift
public struct Manifest: Hashable, Sendable {
    public let context: [String]
    public let metadata: Metadata
    public let links: [Link]           // Publication-level links
    public let readingOrder: [Link]    // Spine (ordered content)
    public let resources: [Link]       // Supporting resources
    public let tableOfContents: [Link] // TOC entries
    public let subcollections: [String: [PublicationCollection]]
}
```

**Key Concepts**:
- Value type (struct) for thread safety
- `readingOrder` = the "spine" of the publication
- `resources` = images, fonts, stylesheets

---

## Link

**File**: `Sources/Shared/Publication/Link.swift`

A reference to a resource within the publication.

```swift
public struct Link: Hashable, Sendable {
    public let href: String           // URI or URI template
    public let mediaType: MediaType?  // MIME type
    public let templated: Bool        // URI template?
    public let title: String?
    public let rels: [LinkRelation]   // Relationships
    public let properties: Properties // Custom properties
    public let alternates: [Link]     // Alternate versions
    public let children: [Link]       // Nested resources

    // Dimensions (images)
    public let width: Int?
    public let height: Int?

    // Duration (audio/video)
    public let duration: Double?
    public let bitrate: Double?
}
```

**Common Relations** (`LinkRelation`):
- `.cover` - Cover image
- `.contents` - Table of contents
- `.self` - Self-reference
- `.alternate` - Alternative format
- `.search` - Search endpoint

**EPUB-specific Properties**:
- `page: .left | .right | .center` - Spread position
- `layout: .reflowable | .fixed` - Content layout
- `orientation`, `spread`, `overflow`

---

## Locator

**File**: `Sources/Shared/Publication/Locator.swift`

A precise, serializable position within a publication (for bookmarks, highlights).

```swift
public struct Locator: Hashable, Sendable {
    public let href: AnyURL           // Resource being located
    public let mediaType: MediaType
    public let title: String?         // Chapter/section title
    public let locations: Locations   // Position info
    public let text: Text             // Textual context
}

public struct Locations: Hashable, Sendable {
    public let fragments: [String]        // CSS selectors, IDs
    public let progression: Double?       // 0.0-1.0 within resource
    public let totalProgression: Double?  // 0.0-1.0 within publication
    public let position: Int?             // Page/position number
}

public struct Text: Hashable, Sendable {
    public let before: String?    // Text before highlight
    public let highlight: String? // The highlighted text
    public let after: String?     // Text after highlight
}
```

**Use Cases**:
- Bookmarks: `Locator` with just `href` + `locations`
- Highlights: `Locator` with `text` content
- Reading position: `Locator` with `totalProgression`

---

## Metadata

**File**: `Sources/Shared/Publication/Metadata.swift`

Publication-level metadata.

```swift
public struct Metadata: Hashable, Sendable {
    public let identifier: String?
    public let title: LocalizedString
    public let subtitle: LocalizedString?

    // Contributors
    public let authors: [Contributor]
    public let translators: [Contributor]
    public let editors: [Contributor]
    public let narrators: [Contributor]    // Audiobooks

    // Classification
    public let subjects: [Subject]
    public let languages: [String]         // BCP 47 codes

    // Dates
    public let published: Date?
    public let modified: Date?

    // Layout hints
    public let readingProgression: ReadingProgression  // ltr, rtl, ttb, btt
    public let layout: Layout?             // reflowable, fixed, scrolled

    // Audiobook-specific
    public let duration: Double?           // Total seconds
    public let numberOfPages: Int?
}
```

---

## LocalizedString

**File**: `Sources/Shared/Publication/LocalizedString.swift`

Supports single or multiple language versions of text.

```swift
public enum LocalizedString: Hashable, Sendable {
    case nonlocalized(String)
    case localized([String: String])  // language code -> text

    public var string: String  // Best match for user locale
    public func string(forLanguageCode: String?) -> String
}
```

**Example**:
```swift
// Simple
let title = LocalizedString.nonlocalized("Hello World")

// Multi-language
let title = LocalizedString.localized([
    "en": "Hello World",
    "fr": "Bonjour le Monde",
    "ja": "こんにちは世界"
])

title.string  // Returns best match for device locale
```

---

## Contributor

**File**: `Sources/Shared/Publication/Contributor.swift`

Person or organization involved in the publication.

```swift
public struct Contributor: Hashable, Sendable {
    public let name: LocalizedString
    public let identifier: String?  // URI
    public let sortAs: String?      // Sort key
    public let roles: [String]      // creator, author, etc.
    public let position: Double?    // Position in series
    public let links: [Link]        // Discovery links
}
```

---

## Container & Resource

**Files**: `Sources/Shared/Toolkit/Data/Container/`, `Sources/Shared/Toolkit/Data/Resource/`

Abstractions for accessing publication content.

```swift
// Container: indexed access to resources
public protocol Container {
    var sourceURL: AbsoluteURL? { get }
    subscript(_ href: RelativeURL) -> Resource? { get }
    var entries: Set<RelativeURL> { get async }
}

// Resource: streamable content
public protocol Resource {
    var sourceURL: AbsoluteURL? { get }
    func estimatedLength() async -> ReadResult<UInt64?>
    func properties() async -> ReadResult<ResourceProperties>
    func stream(...) async -> ReadResult<...>
    func read(range: Range<UInt64>?) async -> ReadResult<Data>
}
```

---

## Enums

### ReadingProgression
```swift
public enum ReadingProgression: String, Sendable {
    case ltr   // Left-to-right (English, etc.)
    case rtl   // Right-to-left (Arabic, Hebrew)
    case ttb   // Top-to-bottom
    case btt   // Bottom-to-top
    case auto  // Infer from content
}
```

### Layout
```swift
public enum Layout: String, Sendable {
    case reflowable  // Text adapts to viewport
    case fixed       // Fixed pages (FXL EPUB, PDF)
    case scrolled    // Continuous scroll
}
```

### Publication.Profile
```swift
public enum Profile: String, Sendable {
    case epub      // EPUB publication
    case pdf       // PDF document
    case audiobook // Audio publication
    case divina    // Visual narrative (comics)
}
```

---

## Type Relationships Diagram

```
Publication ─────────────────┐
    │                        │
    ├── manifest: Manifest   │
    │       │                │
    │       ├── metadata ────┼── title: LocalizedString
    │       │                │   authors: [Contributor]
    │       │                │   subjects: [Subject]
    │       │                │
    │       ├── readingOrder ┼── [Link]
    │       ├── resources ───┤      │
    │       └── links ───────┘      ├── href: String
    │                               ├── mediaType
    │                               ├── properties: Properties
    │                               └── children: [Link]
    │
    ├── container: Container
    │       │
    │       └── [RelativeURL] ──> Resource
    │                                │
    │                                └── read() -> Data
    │
    └── services: [PublicationService]
            │
            ├── PositionsService
            ├── SearchService
            ├── ContentService
            └── ...
```
