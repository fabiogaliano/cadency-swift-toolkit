# Architecture Overview

> **Purpose**: High-level architecture and module relationships for the Readium Swift Toolkit

## Module Hierarchy

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Application Layer                            │
│                    (Your iOS Reading App)                           │
└───────────────────────────┬─────────────────────────────────────────┘
                            │
┌───────────────────────────┴─────────────────────────────────────────┐
│                       ReadiumNavigator                              │
│  ┌──────────────┐ ┌──────────────┐ ┌────────────┐ ┌──────────────┐ │
│  │EPUBNavigator │ │ PDFNavigator │ │AudioNavigator│ │ CBZNavigator │ │
│  └──────────────┘ └──────────────┘ └────────────┘ └──────────────┘ │
└───────────────────────────┬─────────────────────────────────────────┘
                            │
┌───────────────────────────┴─────────────────────────────────────────┐
│                       ReadiumStreamer                               │
│  ┌──────────────┐ ┌──────────────┐ ┌────────────┐ ┌──────────────┐ │
│  │  EPUBParser  │ │  PDFParser   │ │ AudioParser│ │ ImageParser  │ │
│  └──────────────┘ └──────────────┘ └────────────┘ └──────────────┘ │
└───────────────────────────┬─────────────────────────────────────────┘
                            │
┌───────────────────────────┴─────────────────────────────────────────┐
│                        ReadiumShared                                │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────────┐   │
│  │Publication │ │  Manifest  │ │  Locator   │ │   Services     │   │
│  └────────────┘ └────────────┘ └────────────┘ └────────────────┘   │
└───────────────────────────┬─────────────────────────────────────────┘
                            │
┌───────────────────────────┴─────────────────────────────────────────┐
│                       ReadiumInternal                               │
│        (JSON utilities, Extensions, UTI handling)                   │
└─────────────────────────────────────────────────────────────────────┘

        ┌─────────────────┐           ┌─────────────────────────┐
        │   ReadiumOPDS   │           │      ReadiumLCP         │
        │  (Catalog API)  │           │   (DRM Protection)      │
        └─────────────────┘           └─────────────────────────┘

                          ADAPTERS
        ┌─────────────────────┐   ┌─────────────────────────┐
        │ReadiumAdapterGCDWeb │   │ ReadiumAdapterLCPSQLite │
        │   (HTTP Server)     │   │   (License Storage)     │
        └─────────────────────┘   └─────────────────────────┘
```

## Module Responsibilities

### ReadiumShared (Foundation Layer)
- **Core data models**: Publication, Manifest, Link, Locator, Metadata
- **Service architecture**: Pluggable services for positions, search, content extraction
- **Container abstraction**: Uniform access to packaged (ZIP) and remote resources
- **Format detection**: Media type sniffing and UTI handling
- **Toolkit utilities**: URL handling, JSON parsing, XML processing

### ReadiumStreamer (Parsing Layer)
- **Publication opening**: Entry point via `PublicationOpener`
- **Format-specific parsers**: EPUB, PDF, Audio, Image, ReadiumWebPub
- **Manifest construction**: Parse package files into Readium manifests
- **Service factories**: Create format-appropriate services (positions, search)
- **Content protection integration**: Hook point for DRM

### ReadiumNavigator (Presentation Layer)
- **Visual rendering**: Display publications in UIViewController
- **User input**: Touch, keyboard, pointer event handling
- **Text selection**: Copy, highlight, annotation support
- **Decoration system**: Visual overlays (highlights, bookmarks, search results)
- **Preferences**: Font, theme, layout customization
- **Text-to-speech**: AVFoundation-based TTS

### ReadiumOPDS (Catalog Layer)
- **OPDS 1.x**: XML-based catalog parsing
- **OPDS 2.0**: JSON-based catalog parsing
- **Publication discovery**: Browse and search remote catalogs
- **Faceted navigation**: Category/filter-based browsing

### ReadiumLCP (DRM Layer)
- **License management**: Parse and validate LCP licenses
- **Content decryption**: AES-256-CBC decryption of resources
- **Authentication**: Passphrase-based license unlocking
- **Rights enforcement**: Print/copy limits, date restrictions

## Key Architectural Decisions

### 1. Protocol-Oriented Design
All major components defined as protocols for testability and flexibility:
- `Navigator`, `VisualNavigator`, `SelectableNavigator`
- `PublicationService`, `ContentService`, `SearchService`
- `ContentProtection`, `LCPAuthenticating`

### 2. Value Types for Data
Core models are structs (immutable, Sendable):
- `Manifest`, `Link`, `Locator`, `Metadata`
- Enables safe concurrent access
- Copy-on-write semantics

### 3. Service Architecture
Publications are extended via composable services:
```swift
publication.findService(SearchService.self)?.search(query)
publication.findService(PositionsService.self)?.positions
```

### 4. Container Abstraction
Uniform resource access regardless of source:
- ZIP archives (EPUB, CBZ)
- Single files (PDF, MP3)
- Remote HTTP resources
- Composite (local + remote)

### 5. Lazy Loading
Resources loaded on-demand:
- Positions computed when first accessed
- Content streamed, not fully loaded
- Deferred JavaScript injection

## File Organization Pattern

```
Sources/{Module}/
├── {Feature}/           # Feature-specific code
│   ├── {Feature}.swift  # Main implementation
│   └── ...
├── Extensions/          # Type extensions
├── Preferences/         # User preferences
├── Toolkit/             # Module-specific utilities
└── Resources/           # Assets, localizations
```

## Threading Model

- **Main thread**: All UI operations (Navigator)
- **Background**: Resource loading, parsing, decryption
- **Async/await**: Modern concurrency throughout
- **Actors**: Thread-safe state (e.g., position caching)

## Related Documentation
- [02-modules.md](./02-modules.md) - Detailed module breakdown
- [04-patterns.md](./04-patterns.md) - Design patterns used
- [05-flows.md](./05-flows.md) - Data flow diagrams
