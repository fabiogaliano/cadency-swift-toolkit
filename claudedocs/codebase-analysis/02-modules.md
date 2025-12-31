# Module Reference

> **Purpose**: Detailed breakdown of each module, key files, and entry points

## ReadiumShared

**Location**: `Sources/Shared/`
**Purpose**: Core data models and shared infrastructure

### Key Directories

| Directory | Purpose |
|-----------|---------|
| `Publication/` | Core publication models (Publication, Manifest, Link, Locator, Metadata) |
| `Publication/Services/` | Service protocols and implementations |
| `Publication/Extensions/` | Format-specific extensions (EPUB, Presentation, Encryption) |
| `OPDS/` | OPDS catalog data models (Feed, Acquisition, Price) |
| `Toolkit/` | 105+ utility files (URL, JSON, XML, Media, Archive) |
| `Logger/` | Logging infrastructure |
| `Resources/` | Localization files |

### Entry Points

```swift
// Core types
import ReadiumShared

let publication: Publication     // Main publication object
let manifest: Manifest          // Publication metadata + structure
let locator: Locator           // Position within publication
let link: Link                 // Resource reference
```

### Key Files

| File | Purpose |
|------|---------|
| `Publication/Publication.swift` | Main publication class with services |
| `Publication/Manifest.swift` | Metadata, reading order, resources |
| `Publication/Link.swift` | Resource references with properties |
| `Publication/Locator.swift` | Serializable position (bookmarks) |
| `Publication/Metadata.swift` | Title, authors, dates, language |
| `Toolkit/Media/MediaType.swift` | MIME type handling |
| `Toolkit/URL/AnyURL.swift` | Unified URL abstraction |

---

## ReadiumStreamer

**Location**: `Sources/Streamer/`
**Purpose**: Parse publications from files/archives

### Key Directories

| Directory | Purpose |
|-----------|---------|
| `Parser/` | Publication parsers (EPUB, PDF, Audio, Image) |
| `Parser/EPUB/` | EPUB-specific parsing (OPF, NCX, encryption) |
| `Parser/PDF/` | PDF parsing and positions |
| `Parser/Audio/` | Audiobook parsing |
| `Parser/Image/` | CBZ/image archive parsing |
| `Toolkit/` | Compression, path utilities |
| `Assets/` | Static assets |

### Entry Points

```swift
import ReadiumStreamer

let opener = PublicationOpener(
    parser: DefaultPublicationParser(...),
    contentProtections: [lcpProtection]
)
let publication = try await opener.open(asset: asset)
```

### Key Files

| File | Purpose |
|------|---------|
| `PublicationOpener.swift` | Main entry point for opening publications |
| `PublicationParser.swift` | Parser protocol |
| `DefaultPublicationParser.swift` | Composite parser with all formats |
| `Parser/EPUB/EPUBParser.swift` | EPUB parsing orchestration |
| `Parser/EPUB/EPUBManifestParser.swift` | OPF + navigation parsing |
| `Parser/PDF/PDFParser.swift` | PDF metadata extraction |

---

## ReadiumNavigator

**Location**: `Sources/Navigator/`
**Purpose**: Render publications to users

### Key Directories

| Directory | Purpose |
|-----------|---------|
| `EPUB/` | EPUB rendering (paginated + continuous) |
| `EPUB/Scripts/` | JavaScript source for WebView |
| `EPUB/Assets/` | Built JS, CSS, HTML templates |
| `PDF/` | PDF rendering via PDFKit |
| `Audiobook/` | Audio playback |
| `CBZ/` | Comic book/image viewing |
| `Input/` | Touch, keyboard, pointer handling |
| `Preferences/` | Settings framework |
| `Decorator/` | Highlight/annotation rendering |
| `TTS/` | Text-to-speech |

### Entry Points

```swift
import ReadiumNavigator

// EPUB (paginated)
let navigator = EPUBNavigatorViewController(
    publication: publication,
    config: .init(preferences: preferences)
)

// EPUB (continuous scroll) - NEW
let continuous = EPUBContinuousNavigatorViewController(
    publication: publication,
    config: .init(...)
)

// PDF
let pdfNav = PDFNavigatorViewController(publication: publication)

// Audio
let audioNav = AudioNavigator(publication: publication)
```

### Key Files

| File | Purpose |
|------|---------|
| `Navigator.swift` | Base navigator protocol |
| `VisualNavigator.swift` | Visual content protocol |
| `SelectableNavigator.swift` | Text selection protocol |
| `EPUB/EPUBNavigatorViewController.swift` | Paginated EPUB |
| `EPUB/EPUBContinuousNavigatorViewController.swift` | Continuous scroll EPUB |
| `PDF/PDFNavigatorViewController.swift` | PDF viewer |
| `Audiobook/AudioNavigator.swift` | Audio player |

---

## ReadiumOPDS

**Location**: `Sources/OPDS/`
**Purpose**: Parse OPDS catalog feeds

### Entry Points

```swift
import ReadiumOPDS

let parseData = try await OPDSParser.parseURL(url: catalogURL)
if let feed = parseData.feed {
    // Browse publications
    for pub in feed.publications { ... }
}
```

### Key Files

| File | Purpose |
|------|---------|
| `OPDSParser.swift` | Entry point, format detection |
| `OPDS1Parser.swift` | XML feed parsing |
| `OPDS2Parser.swift` | JSON feed parsing |
| `ParseData.swift` | Parse result wrapper |

---

## ReadiumLCP

**Location**: `Sources/LCP/`
**Purpose**: Readium LCP DRM support

### Key Directories

| Directory | Purpose |
|-----------|---------|
| `License/` | License document parsing and validation |
| `License/Model/` | License data models |
| `License/Container/` | License extraction from publications |
| `Content Protection/` | Decryption integration |
| `Authentications/` | Passphrase UI and handling |
| `Services/` | Device, CRL, passphrase services |

### Entry Points

```swift
import ReadiumLCP

let lcpService = LCPService(
    client: lcpClient,
    licenseRepository: sqliteRepo,
    passphraseRepository: sqlitePassphrases,
    httpClient: httpClient
)

// Get content protection for Streamer
let protection = lcpService.contentProtection()

// Open protected publication
let license = try await lcpService.retrieveLicense(from: asset)
```

### Key Files

| File | Purpose |
|------|---------|
| `LCPService.swift` | Main LCP service |
| `LCPLicense.swift` | Opened license interface |
| `LCPDecryptor.swift` | Resource decryption |
| `LCPContentProtection.swift` | Streamer integration |
| `License/LicenseValidation.swift` | Validation state machine |

---

## ReadiumInternal

**Location**: `Sources/Internal/`
**Purpose**: Shared internal utilities

### Key Files

| File | Purpose |
|------|---------|
| `JSON.swift` | JSON parsing utilities |
| `UTI.swift` | Uniform Type Identifier handling |
| `Measure.swift` | Performance timing |
| `Extensions/` | Swift stdlib extensions |

---

## Adapters

### ReadiumAdapterGCDWebServer
**Location**: `Sources/Adapters/GCDWebServer/`

Serves publication resources via local HTTP for WebView:
- `GCDHTTPServer.swift` - HTTP server implementation
- `ResourceResponse.swift` - Streaming response handler

### ReadiumAdapterLCPSQLite
**Location**: `Sources/Adapters/LCPSQLite/`

SQLite persistence for LCP:
- `Database.swift` - SQLite connection
- `SQLiteLCPLicenseRepository.swift` - License storage
- `SQLiteLCPPassphraseRepository.swift` - Passphrase storage
