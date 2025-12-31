# External Dependencies

> **Purpose**: Third-party libraries and their roles in the toolkit

## Dependency Graph

```
┌─────────────────────────────────────────────────────────────────────┐
│                        ReadiumNavigator                             │
│                              │                                      │
│                    ┌─────────┴─────────┐                           │
│                    ▼                   ▼                           │
│             DifferenceKit         SwiftSoup                        │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                        ReadiumStreamer                              │
│                              │                                      │
│                    ┌─────────┴─────────┐                           │
│                    ▼                   ▼                           │
│              CryptoSwift          ReadiumFuzi                      │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                         ReadiumShared                               │
│                              │                                      │
│         ┌────────────────────┼────────────────────┐                │
│         ▼                    ▼                    ▼                │
│     SwiftSoup            ReadiumFuzi         ReadiumZIPFoundation  │
│                              │                    │                │
│                              ▼                    ▼                │
│                          Minizip                Zip                │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                          ReadiumLCP                                 │
│                              │                                      │
│                    ┌─────────┴─────────┐                           │
│                    ▼                   ▼                           │
│              CryptoSwift      ReadiumZIPFoundation                 │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                    ReadiumAdapterGCDWebServer                       │
│                              │                                      │
│                              ▼                                      │
│                     ReadiumGCDWebServer                            │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                     ReadiumAdapterLCPSQLite                         │
│                              │                                      │
│                              ▼                                      │
│                        SQLite.swift                                │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Library Details

### CryptoSwift

**Repository**: `https://github.com/krzyzanowskim/CryptoSwift.git`
**Version**: `≥ 1.8.0`
**Used by**: ReadiumStreamer, ReadiumLCP

**Purpose**: Pure Swift cryptographic operations

**Usage in Readium**:
- AES-256-CBC encryption/decryption for LCP
- SHA-256 hashing for password verification
- PBKDF2 key derivation
- HMAC for integrity checks

**Key APIs Used**:
```swift
import CryptoSwift

// AES decryption
let aes = try AES(key: keyBytes, blockMode: CBC(iv: ivBytes))
let decrypted = try aes.decrypt(encryptedBytes)

// SHA-256
let hash = data.sha256()

// PBKDF2
let derived = try PKCS5.PBKDF2(password: passphrase, salt: salt, iterations: 10000)
```

---

### SwiftSoup

**Repository**: `https://github.com/scinfu/SwiftSoup.git`
**Version**: `≥ 2.7.0`
**Used by**: ReadiumShared, ReadiumNavigator

**Purpose**: HTML/XML parsing and manipulation (Swift port of jsoup)

**Usage in Readium**:
- Extract text content from HTML for search
- Parse HTML for content extraction
- Manipulate DOM for injection

**Key APIs Used**:
```swift
import SwiftSoup

let doc = try SwiftSoup.parse(html)
let text = try doc.text()  // Extract all text
let elements = try doc.select("p")  // CSS selectors
try element.attr("href")  // Get attributes
```

---

### ReadiumFuzi (Fuzi Fork)

**Repository**: `https://github.com/readium/Fuzi.git`
**Version**: `≥ 4.0.0`
**Used by**: ReadiumShared, ReadiumStreamer, ReadiumOPDS

**Purpose**: Fast XML/HTML parsing using libxml2

**Usage in Readium**:
- Parse EPUB OPF files
- Parse EPUB NCX navigation
- Parse OPDS 1.x XML feeds
- Parse encryption.xml

**Key APIs Used**:
```swift
import ReadiumFuzi

let doc = try XMLDocument(data: xmlData)
let root = doc.root

// XPath queries
let nodes = root.xpath("//opf:item", namespaces: ["opf": "..."])

// Element access
let href = element.attr("href")
let text = element.stringValue
```

---

### ReadiumZIPFoundation (ZIPFoundation Fork)

**Repository**: `https://github.com/readium/ZIPFoundation.git`
**Version**: `≥ 3.0.1`
**Used by**: ReadiumShared, ReadiumLCP

**Purpose**: ZIP archive reading with streaming support

**Usage in Readium**:
- Read EPUB files (ZIP format)
- Access entries without full extraction
- Stream large resources

**Key APIs Used**:
```swift
import ReadiumZIPFoundation

let archive = try Archive(url: epubURL, accessMode: .read)
for entry in archive {
    let data = try archive.extractData(from: entry)
}
```

---

### Zip

**Repository**: `https://github.com/marmelroy/Zip.git`
**Version**: `≥ 2.1.0`
**Used by**: ReadiumShared

**Purpose**: Simple ZIP utilities

**Usage in Readium**:
- Quick ZIP extraction
- Zip file validation

---

### DifferenceKit

**Repository**: `https://github.com/ra1028/DifferenceKit.git`
**Version**: `≥ 1.3.0`
**Used by**: ReadiumNavigator

**Purpose**: Efficient collection diffing for UI updates

**Usage in Readium**:
- Diff decorations for efficient updates
- Update spreads in pagination view
- Minimize reloads when content changes

**Key APIs Used**:
```swift
import DifferenceKit

let changeset = StagedChangeset(source: oldItems, target: newItems)
collectionView.reload(using: changeset) { data in
    self.items = data
}
```

---

### ReadiumGCDWebServer (GCDWebServer Fork)

**Repository**: `https://github.com/readium/GCDWebServer.git`
**Version**: `≥ 4.0.0`
**Used by**: ReadiumAdapterGCDWebServer

**Purpose**: Lightweight HTTP server for serving publication resources

**Usage in Readium**:
- Serve EPUB resources to WKWebView
- Handle byte-range requests
- Provide local URLs for resources

**Key APIs Used**:
```swift
import ReadiumGCDWebServer

let server = GCDWebServer()
server.addHandler(forMethod: "GET", pathRegex: ".*") { request in
    // Return response
}
server.start(withPort: 0, bonjourName: nil)
```

---

### SQLite.swift

**Repository**: `https://github.com/stephencelis/SQLite.swift.git`
**Version**: `≥ 0.15.0`
**Used by**: ReadiumAdapterLCPSQLite

**Purpose**: Type-safe SQLite wrapper

**Usage in Readium**:
- Store LCP licenses
- Cache passphrases
- Track consumable rights (print/copy)

**Key APIs Used**:
```swift
import SQLite

let db = try Connection(path)
let licenses = Table("Licenses")
let id = Expression<String>("id")

try db.run(licenses.insert(id <- licenseId))
let query = licenses.filter(id == licenseId)
```

---

## Dependency Matrix

| Module | CryptoSwift | SwiftSoup | Fuzi | ZIPFoundation | DifferenceKit | GCDWebServer | SQLite |
|--------|:-----------:|:---------:|:----:|:-------------:|:-------------:|:------------:|:------:|
| ReadiumShared | | ✓ | ✓ | ✓ | | | |
| ReadiumStreamer | ✓ | | ✓ | | | | |
| ReadiumNavigator | | ✓ | | | ✓ | | |
| ReadiumOPDS | | | ✓ | | | | |
| ReadiumLCP | ✓ | | | ✓ | | | |
| AdapterGCDWebServer | | | | | | ✓ | |
| AdapterLCPSQLite | | | | | | | ✓ |

---

## System Frameworks Used

| Framework | Purpose | Modules |
|-----------|---------|---------|
| **UIKit** | UI components | Navigator |
| **WebKit** | WKWebView for EPUB | Navigator |
| **PDFKit** | PDF rendering | Navigator |
| **AVFoundation** | Audio playback, TTS | Navigator |
| **CoreServices** | UTI handling | Shared, Internal |
| **Foundation** | Base utilities | All |
| **Combine** | Reactive programming | Various |

---

## Version Requirements

| Dependency | Minimum Version | Notes |
|------------|-----------------|-------|
| iOS | 13.4 | Minimum deployment target |
| Swift | 5.10 (6.0 for develop) | Language version |
| Xcode | 15.4 (16.2 for develop) | Build tool |

---

## Optional Dependencies

### R2LCPClient.framework

**Provider**: EDRLab (private)
**Purpose**: Core LCP decryption (liblcp wrapper)

This is a **private framework** required for LCP support. Contact EDRLab to obtain.

**Without it**: ReadiumLCP compiles but cannot decrypt content.

---

## Adding to Your Project

### Swift Package Manager (Recommended)

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/readium/swift-toolkit.git", from: "3.6.0")
]

// Add to target
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "ReadiumShared", package: "swift-toolkit"),
        .product(name: "ReadiumStreamer", package: "swift-toolkit"),
        .product(name: "ReadiumNavigator", package: "swift-toolkit"),
        // Add others as needed
    ]
)
```

### Carthage

```
# Cartfile
github "readium/swift-toolkit" ~> 3.6.0
```

### CocoaPods

```ruby
# Podfile
source 'https://github.com/readium/podspecs'
source 'https://cdn.cocoapods.org/'

pod 'ReadiumShared', '~> 3.6.0'
pod 'ReadiumStreamer', '~> 3.6.0'
pod 'ReadiumNavigator', '~> 3.6.0'
```
