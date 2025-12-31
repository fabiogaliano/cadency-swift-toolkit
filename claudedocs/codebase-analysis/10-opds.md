# OPDS Catalog Support

> **Purpose**: Parsing and navigating OPDS catalog feeds

## What is OPDS?

**OPDS** (Open Publication Distribution System) is a catalog format for distributing ebooks. It's like RSS for book catalogs, enabling:
- **Discovery** - Browse and search publications
- **Acquisition** - Download or borrow publications
- **Navigation** - Hierarchical catalog structure

## OPDS Versions

| Version | Format | Use Case |
|---------|--------|----------|
| OPDS 1.x | Atom XML | Legacy, widespread |
| OPDS 2.0 | JSON (RWPM) | Modern, recommended |

The toolkit supports both transparently.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         OPDSParser                                  │
│                     (Format Detection)                              │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                    ┌────────────┴────────────┐
                    │                         │
                    ▼                         ▼
         ┌──────────────────┐      ┌──────────────────┐
         │   OPDS1Parser    │      │   OPDS2Parser    │
         │   (Atom XML)     │      │   (JSON RWPM)    │
         └─────────┬────────┘      └────────┬─────────┘
                   │                        │
                   └───────────┬────────────┘
                               │
                               ▼
                    ┌──────────────────┐
                    │    ParseData     │
                    │ ┌──────────────┐ │
                    │ │ Feed or      │ │
                    │ │ Publication  │ │
                    │ └──────────────┘ │
                    └──────────────────┘
```

---

## Key Files

| File | Location | Purpose |
|------|----------|---------|
| `OPDSParser.swift` | `Sources/OPDS/` | Entry point, format detection |
| `OPDS1Parser.swift` | `Sources/OPDS/` | XML Atom feed parsing |
| `OPDS2Parser.swift` | `Sources/OPDS/` | JSON feed parsing |
| `ParseData.swift` | `Sources/OPDS/` | Parse result wrapper |
| `Feed.swift` | `Sources/Shared/OPDS/` | Feed data model |
| `OpdsMetadata.swift` | `Sources/Shared/OPDS/` | Feed metadata |
| `OPDSAcquisition.swift` | `Sources/Shared/OPDS/` | Acquisition links |
| `OPDSPrice.swift` | `Sources/Shared/OPDS/` | Pricing info |
| `OPDSAvailability.swift` | `Sources/Shared/OPDS/` | Availability state |

---

## Usage

### Basic Parsing

```swift
import ReadiumOPDS

// Parse catalog URL
let parseData = try await OPDSParser.parseURL(url: catalogURL)

// Check what we got
if let feed = parseData.feed {
    // It's a catalog feed
    print("Catalog: \(feed.metadata.title)")

    // Browse publications
    for publication in feed.publications {
        print("  - \(publication.metadata.title)")
    }

    // Browse navigation
    for navLink in feed.navigation {
        print("  Category: \(navLink.title)")
    }

} else if let publication = parseData.publication {
    // It's a single publication entry
    print("Publication: \(publication.metadata.title)")
}
```

### Navigating Catalog

```swift
// Follow navigation link
if let categoryLink = feed.navigation.first(where: { $0.title == "Fiction" }) {
    let categoryFeed = try await OPDSParser.parseURL(url: categoryLink.url)
    // Browse fiction books...
}

// Pagination
if let nextLink = feed.links.first(where: { $0.rels.contains(.next) }) {
    let nextPage = try await OPDSParser.parseURL(url: nextLink.url)
    // Load next page...
}
```

### Search

```swift
// Find search link (templated)
if let searchLink = feed.links.first(where: { $0.rels.contains(.search) }) {
    // Expand template
    let searchURL = searchLink.url(parameters: ["query": "fantasy"])
    let results = try await OPDSParser.parseURL(url: searchURL)
    // Display search results...
}
```

---

## Data Models

### Feed

```swift
public class Feed {
    /// Catalog metadata (title, pagination)
    public let metadata: OpdsMetadata

    /// Feed-level links (self, search, next, etc.)
    public let links: [Link]

    /// Available facets for filtering
    public let facets: [Facet]

    /// Grouped publication collections
    public let groups: [Group]

    /// Publications in this feed
    public let publications: [Publication]

    /// Navigation links (categories, subcatalogs)
    public let navigation: [Link]

    /// JSON-LD context (OPDS 2.0)
    public let context: [String]
}
```

### OpdsMetadata

```swift
public struct OpdsMetadata {
    public let title: String
    public let identifier: String?
    public let modified: Date?

    // Pagination
    public let numberOfItems: Int?
    public let itemsPerPage: Int?
    public let currentPage: Int?
}
```

### Facet (Filtering)

```swift
public struct Facet {
    /// Facet metadata (name)
    public let metadata: OpdsMetadata

    /// Filter options as links
    public let links: [Link]
}
```

**Example facets**:
- Genre: Fiction, Non-fiction, Mystery, Romance
- Language: English, French, Spanish
- Format: EPUB, PDF, Audiobook

### Group (Collections)

```swift
public struct Group {
    /// Group metadata (title)
    public let metadata: OpdsMetadata

    /// Links in this group
    public let links: [Link]

    /// Publications in this group
    public let publications: [Publication]

    /// Nested navigation
    public let navigation: [Link]
}
```

**Example groups**:
- "Featured This Week"
- "New Releases"
- "Popular in Your Area"

---

## Acquisition Links

Publications contain acquisition links indicating how to obtain them:

### Acquisition Types

| Relation | Meaning |
|----------|---------|
| `http://opds-spec.org/acquisition` | Generic acquisition |
| `http://opds-spec.org/acquisition/buy` | Purchase |
| `http://opds-spec.org/acquisition/borrow` | Library loan |
| `http://opds-spec.org/acquisition/open-access` | Free download |
| `http://opds-spec.org/acquisition/sample` | Free sample |
| `http://opds-spec.org/acquisition/subscribe` | Subscription |

### Example

```swift
// Find acquisition links
for link in publication.links {
    if link.rels.contains(.opdsAcquisitionOpenAccess) {
        // Free download available
        print("Download: \(link.href)")
    }

    if link.rels.contains(.opdsAcquisitionBuy) {
        // For purchase
        if let price = link.properties.price {
            print("Buy for \(price.currency) \(price.value)")
        }
    }

    if link.rels.contains(.opdsAcquisitionBorrow) {
        // Library loan
        if let availability = link.properties.availability {
            print("Availability: \(availability.state)")
        }
    }
}
```

### OPDSAcquisition

```swift
public struct OPDSAcquisition {
    /// Media type of the acquired resource
    public let type: MediaType

    /// Nested acquisitions (for indirect acquisition)
    public let children: [OPDSAcquisition]
}
```

**Indirect acquisition** example:
```
Acquire ACSM file → Opens Adobe DRM → Downloads EPUB
```

---

## Pricing

```swift
public struct OPDSPrice {
    /// ISO 4217 currency code
    public let currency: String  // "USD", "EUR", etc.

    /// Price value
    public let value: Double
}

// Usage
if let price = link.properties.price {
    let formatted = NumberFormatter.localizedString(
        from: NSNumber(value: price.value),
        number: .currency
    )
    print("Price: \(formatted)")  // "$9.99"
}
```

---

## Library Availability

For lending libraries:

```swift
public struct OPDSAvailability {
    /// Current state
    public let state: State

    /// When state changed
    public let since: Date?

    /// When state will change (loan end, hold ready)
    public let until: Date?

    public enum State: String {
        case available   // Ready to borrow
        case unavailable // All copies out
        case reserved    // Reserved for user
        case ready       // Hold ready for pickup
    }
}

public struct OPDSCopies {
    public let total: Int?      // Total copies owned
    public let available: Int?  // Currently available
}

public struct OPDSHolds {
    public let total: Int?     // People on waitlist
    public let position: Int?  // User's position
}
```

**Example UI**:
```swift
if let availability = link.properties.availability {
    switch availability.state {
    case .available:
        showBorrowButton()
    case .unavailable:
        if let holds = link.properties.holds {
            showLabel("On hold: \(holds.position ?? 0) of \(holds.total ?? 0)")
        }
        showHoldButton()
    case .reserved:
        showLabel("Reserved until \(availability.until)")
    case .ready:
        showLabel("Ready for pickup!")
        showBorrowButton()
    }
}
```

---

## OPDS 1.x vs 2.0

### OPDS 1.x (XML)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"
      xmlns:opds="http://opds-spec.org/2010/catalog">
  <title>My Library</title>
  <id>urn:uuid:catalog-id</id>
  <updated>2024-01-15T00:00:00Z</updated>

  <link rel="self" href="https://library.example.com/catalog" type="application/atom+xml"/>
  <link rel="search" href="https://library.example.com/search?q={searchTerms}" type="application/atom+xml"/>

  <entry>
    <title>A Great Book</title>
    <id>urn:isbn:1234567890</id>
    <author><name>Jane Author</name></author>
    <link rel="http://opds-spec.org/acquisition/open-access"
          href="https://library.example.com/book.epub"
          type="application/epub+zip"/>
  </entry>
</feed>
```

### OPDS 2.0 (JSON)

```json
{
  "@context": "https://readium.org/webpub-manifest/context.jsonld",
  "metadata": {
    "title": "My Library",
    "itemsPerPage": 20,
    "numberOfItems": 100
  },
  "links": [
    { "rel": "self", "href": "https://library.example.com/catalog", "type": "application/opds+json" },
    { "rel": "search", "href": "https://library.example.com/search{?query}", "type": "application/opds+json", "templated": true }
  ],
  "publications": [
    {
      "metadata": {
        "title": "A Great Book",
        "author": "Jane Author"
      },
      "links": [
        {
          "rel": "http://opds-spec.org/acquisition/open-access",
          "href": "https://library.example.com/book.epub",
          "type": "application/epub+zip"
        }
      ]
    }
  ]
}
```

---

## Common Patterns

### Building a Catalog Browser

```swift
class CatalogBrowser {
    var currentFeed: Feed?
    var navigationStack: [Feed] = []

    func loadCatalog(url: URL) async throws {
        let parseData = try await OPDSParser.parseURL(url: url)
        if let feed = parseData.feed {
            currentFeed = feed
            updateUI()
        }
    }

    func navigateTo(link: Link) async throws {
        // Save current for back navigation
        if let current = currentFeed {
            navigationStack.append(current)
        }
        try await loadCatalog(url: link.url)
    }

    func goBack() {
        if let previous = navigationStack.popLast() {
            currentFeed = previous
            updateUI()
        }
    }

    func search(query: String) async throws {
        guard let searchLink = currentFeed?.links.first(where: { $0.rels.contains(.search) }) else {
            return
        }
        let searchURL = searchLink.url(parameters: ["query": query])
        try await loadCatalog(url: searchURL)
    }
}
```

### Downloading a Publication

```swift
func download(publication: Publication) async throws -> URL {
    // Find best acquisition link
    guard let link = publication.links.first(where: {
        $0.rels.contains(.opdsAcquisitionOpenAccess) ||
        $0.rels.contains(.opdsAcquisition)
    }) else {
        throw OPDSError.noAcquisitionLink
    }

    // Download
    let (data, _) = try await URLSession.shared.data(from: link.url)

    // Save to documents
    let filename = publication.metadata.title.sanitizedFilename + ".epub"
    let destination = documentsDirectory.appendingPathComponent(filename)
    try data.write(to: destination)

    return destination
}
```

---

## Authentication

OPDS Authentication for OPDS (AuthOPDS) spec support is planned but not yet implemented.

For now, handle authentication at the HTTP level:
- Basic auth in URL
- OAuth tokens in headers
- Cookie-based sessions

```swift
// Example with URLSession
var request = URLRequest(url: catalogURL)
request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

let (data, _) = try await URLSession.shared.data(for: request)
let parseData = try OPDSParser.parse(data: data, url: catalogURL)
```
