# Design Patterns

> **Purpose**: Key design patterns and conventions used throughout the codebase

## 1. Service Architecture

**Pattern**: Pluggable services discovered by type

**Location**: `Sources/Shared/Publication/Services/`

Publications are extended with composable services registered during construction:

```swift
// Service protocol
public protocol PublicationService {
    var links: [Link] { get }
    func get<T: URLConvertible>(_ href: T) -> Resource?
}

// Service discovery
let searchService = publication.findService(SearchService.self)
let results = searchService?.search(query: "text")

// Service registration (during parsing)
let builder = Publication.Builder(manifest: manifest, container: container)
builder.servicesBuilder.set(SearchService.self) { context in
    StringSearchService(publication: context.publication)
}
```

**Services Available**:
- `PositionsService` - Calculate page positions
- `SearchService` - Full-text search
- `ContentService` - Content extraction
- `LocatorService` - Position normalization
- `CoverService` - Cover image handling
- `ContentProtectionService` - DRM/rights

**Why This Pattern**:
- Format-specific behavior without subclassing
- Easy to add custom services
- Lazy initialization
- Testable via protocol mocking

---

## 2. Builder Pattern

**Pattern**: Construct immutable objects through mutable builder

**Location**: `Publication.Builder`, `PublicationServicesBuilder`

```swift
// Building a Publication
let builder = Publication.Builder(manifest: manifest, container: container)

// Apply transformations
builder.apply(someTransform)
builder.servicesBuilder.set(MyService.self, factory: myFactory)

// Build immutable publication
let publication = builder.build()
```

**Why This Pattern**:
- Complex construction logic
- Optional components
- Immutable result objects
- Chain transformations

---

## 3. Protocol-Oriented Design

**Pattern**: Define behavior through protocols, not inheritance

**Location**: Throughout, especially Navigator

```swift
// Base protocol
public protocol Navigator {
    var currentLocation: Locator? { get }
    func go(to locator: Locator) async -> Bool
    func goForward() async -> Bool
    func goBackward() async -> Bool
}

// Extended protocols
public protocol VisualNavigator: Navigator {
    func goLeft() async -> Bool
    func goRight() async -> Bool
    var presentation: VisualNavigatorPresentation { get }
}

public protocol SelectableNavigator: Navigator {
    var currentSelection: Selection? { get }
}

// Composition
class EPUBNavigatorViewController: UIViewController,
    VisualNavigator,
    SelectableNavigator,
    DecorableNavigator { ... }
```

**Why This Pattern**:
- Multiple behaviors via composition
- Clear interface contracts
- Easy mocking for tests
- No diamond inheritance problems

---

## 4. Delegate Pattern

**Pattern**: Callbacks via delegate protocols

**Location**: Navigator delegates, authentication

```swift
public protocol NavigatorDelegate: AnyObject {
    func navigator(_ navigator: Navigator, didJumpTo locator: Locator)
    func navigator(_ navigator: Navigator, presentError error: NavigatorError)
    func navigator(_ navigator: Navigator, shouldNavigateTo link: Link) -> Bool
}

// Usage
class MyReaderVC: UIViewController, NavigatorDelegate {
    func navigator(_ navigator: Navigator, didJumpTo locator: Locator) {
        saveReadingPosition(locator)
    }
}
```

**Why This Pattern**:
- Decouple event handling
- Optional method implementation
- Familiar iOS pattern
- Weak reference prevents cycles

---

## 5. Value Types (Structs)

**Pattern**: Immutable value types for data models

**Location**: All core models (Manifest, Link, Locator, Metadata)

```swift
public struct Locator: Hashable, Sendable {
    public let href: AnyURL
    public let mediaType: MediaType
    public let locations: Locations
    public let text: Text

    // Immutable copy with modifications
    public func copy(
        title: String? = nil,
        locations: Locations? = nil
    ) -> Locator
}
```

**Why This Pattern**:
- Thread-safe by default (Sendable)
- Predictable behavior (no shared state)
- Value equality (Hashable)
- Copy-on-write efficiency

---

## 6. Container Abstraction

**Pattern**: Uniform access to different storage types

**Location**: `Sources/Shared/Toolkit/Data/Container/`

```swift
public protocol Container {
    var sourceURL: AbsoluteURL? { get }
    subscript(_ href: RelativeURL) -> Resource? { get }
    var entries: Set<RelativeURL> { get async }
}

// Implementations
class ZIPContainer: Container { ... }          // ZIP archives
class DirectoryContainer: Container { ... }   // File system
class SingleResourceContainer: Container { ... } // Single file
class CompositeContainer: Container { ... }   // Multiple sources
class TransformingContainer: Container { ... } // Apply transformations
```

**Why This Pattern**:
- Abstract storage details
- Combine sources (local + remote)
- Lazy resource loading
- Transparent encryption/compression

---

## 7. State Machine (Validation)

**Pattern**: Explicit state transitions for complex logic

**Location**: `Sources/LCP/License/LicenseValidation.swift`

```swift
enum State {
    case start
    case validateLicense
    case fetchStatus
    case validateStatus
    case checkLicenseStatus
    case requestPassphrase
    case validateIntegrity
    case registerDevice
    case valid(ValidatedDocuments)
    case failure(Error)
}

// Transition function
func transition(from state: State) async -> State {
    switch state {
    case .start:
        return .validateLicense
    case .validateLicense:
        // Parse license document
        return .fetchStatus
    // ... more transitions
    }
}
```

**Why This Pattern**:
- Complex validation logic
- Clear state progression
- Easy to debug (log state changes)
- Testable state transitions

---

## 8. Factory Pattern

**Pattern**: Create objects without exposing creation logic

**Location**: Service factories, parser factories

```swift
typealias PublicationServiceFactory = (PublicationServiceContext) -> PublicationService?

class PublicationServicesBuilder {
    func set<T>(_ type: T.Type, factory: @escaping PublicationServiceFactory)
}

// Usage during parsing
servicesBuilder.set(PositionsService.self) { context in
    EPUBPositionsService(
        manifest: context.manifest,
        container: context.container
    )
}
```

**Why This Pattern**:
- Deferred creation (lazy)
- Context-dependent creation
- Easy to swap implementations
- Registration at parse time, creation at use time

---

## 9. Weak Reference Wrapper

**Pattern**: Prevent retain cycles with weak wrapper

**Location**: `Sources/Shared/Toolkit/Weak.swift`

```swift
public class Weak<T: AnyObject> {
    public weak var value: T?
    public init(_ value: T) { self.value = value }
}

// Usage in services
class MyService: PublicationService {
    private let publicationRef: Weak<Publication>

    var publication: Publication? { publicationRef.value }
}
```

**Why This Pattern**:
- Break circular references
- Services reference Publication weakly
- Generic, reusable wrapper

---

## 10. Decorator Pattern (Decorations)

**Pattern**: Add visual decorations without modifying core

**Location**: `Sources/Navigator/Decorator/`

```swift
public protocol DecorableNavigator: Navigator {
    func apply(decorations: [Decoration], in group: String)
}

public struct Decoration {
    public let id: ID
    public let locator: Locator
    public let style: Style

    public enum Style {
        case highlight(tint: UIColor, isActive: Bool)
        case underline(tint: UIColor)
        case custom(id: String, config: [String: Any])
    }
}

// Usage
navigator.apply(decorations: [
    Decoration(id: "1", locator: locator, style: .highlight(tint: .yellow))
], in: "highlights")
```

**Why This Pattern**:
- Separate decoration concerns
- Group by feature (search, highlights, bookmarks)
- Efficient diffing and updates
- Navigator-agnostic interface

---

## 11. URI Template (RFC 6570)

**Pattern**: Parameterized URLs for search, pagination

**Location**: `Sources/Shared/Toolkit/URL/URITemplate.swift`

```swift
let link = Link(
    href: "search{?query,page}",
    templated: true
)

let url = link.url(parameters: [
    "query": "search term",
    "page": "2"
])
// Result: search?query=search%20term&page=2
```

**Why This Pattern**:
- Standardized URL templating
- OPDS search endpoints
- Service endpoints (positions, search)
- Client-side parameter substitution

---

## 12. Composite Pattern

**Pattern**: Treat collections and individuals uniformly

**Location**: Parsers, containers

```swift
// CompositePublicationParser tries each parser in order
class CompositePublicationParser: PublicationParser {
    let parsers: [PublicationParser]

    func parse(asset: Asset) async throws -> Publication.Builder {
        for parser in parsers {
            if let result = try? await parser.parse(asset: asset) {
                return result
            }
        }
        throw ParserError.formatNotSupported
    }
}

// DefaultPublicationParser = Composite of all parsers
let defaultParser = CompositePublicationParser(parsers: [
    EPUBParser(),
    PDFParser(),
    AudioParser(),
    ImageParser(),
    ReadiumWebPubParser()
])
```

**Why This Pattern**:
- Single interface for multiple formats
- Easy to add new parsers
- Order determines priority
- First successful parse wins
