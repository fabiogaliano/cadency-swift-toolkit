# Data Flows

> **Purpose**: Step-by-step flows for common operations

## 1. Opening a Publication

```
┌─────────────────────────────────────────────────────────────────────┐
│                    PublicationOpener.open(asset)                    │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│              ContentProtection Chain (Optional LCP)                 │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ For each ContentProtection:                                    │ │
│  │   1. Check if asset is protected                               │ │
│  │   2. Request authentication (passphrase)                       │ │
│  │   3. Create decrypting container wrapper                       │ │
│  └────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                   CompositePublicationParser                        │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ Try parsers in order:                                          │ │
│  │   1. EPUBParser    → Check mimetype, parse OPF                 │ │
│  │   2. PDFParser     → Check %PDF header                         │ │
│  │   3. AudioParser   → Check audio MIME types                    │ │
│  │   4. ImageParser   → Check image formats                       │ │
│  │   5. WebPubParser  → Check manifest.json                       │ │
│  └────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Publication.Builder                              │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ 1. Set manifest (metadata + links)                             │ │
│  │ 2. Set container (resource access)                             │ │
│  │ 3. Register services (positions, search, content)              │ │
│  │ 4. Apply transformations                                       │ │
│  └────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Publication (immutable)                          │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ • manifest: Manifest                                           │ │
│  │ • container: Container (possibly decrypting)                   │ │
│  │ • services: [PublicationService]                               │ │
│  └────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

**Code Example**:
```swift
let opener = PublicationOpener(
    parser: DefaultPublicationParser(
        httpClient: httpClient,
        assetRetriever: assetRetriever,
        pdfFactory: pdfFactory
    ),
    contentProtections: [lcpService.contentProtection()]
)

let result = await opener.open(asset: asset)
switch result {
case .success(let publication):
    // Use publication
case .failure(let error):
    // Handle error
}
```

---

## 2. EPUB Parsing Detail

```
EPUBParser.parse(asset)
         │
         ▼
┌─────────────────────────────────────────┐
│ 1. Validate EPUB                        │
│    • Check mimetype file                │
│    • Verify ZIP structure               │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│ 2. EPUBContainerParser                  │
│    • Parse META-INF/container.xml       │
│    • Extract rootfile path (OPF)        │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│ 3. EPUBEncryptionParser                 │
│    • Parse META-INF/encryption.xml      │
│    • Map encrypted resources            │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│ 4. OPFParser                            │
│    • Parse package.opf                  │
│    • Extract metadata (title, authors)  │
│    • Build manifest links               │
│    • Determine reading order            │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│ 5. Navigation Parsing                   │
│    • NavigationDocumentParser (EPUB 3)  │
│    OR                                   │
│    • NCXParser (EPUB 2 fallback)        │
│    → Extract TOC, landmarks, page-list  │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│ 6. EPUBDeobfuscator (if encrypted)      │
│    • Wrap resources for deobfuscation   │
│    • IDPF or Adobe algorithm            │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│ 7. Create Services                      │
│    • EPUBPositionsService               │
│    • StringSearchService                │
│    • DefaultContentService              │
└────────────────┬────────────────────────┘
                 │
                 ▼
         Publication.Builder
```

---

## 3. Navigator Rendering (EPUB)

```
┌─────────────────────────────────────────────────────────────────────┐
│                EPUBNavigatorViewController                          │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
         ┌───────────────────────┴───────────────────────┐
         │                                               │
         ▼                                               ▼
┌─────────────────────┐                   ┌─────────────────────────┐
│  HTTP Server Start  │                   │   PaginationView Setup  │
│  (GCDWebServer)     │                   │   (UICollectionView)    │
└─────────┬───────────┘                   └───────────┬─────────────┘
          │                                           │
          │                                           ▼
          │                               ┌─────────────────────────┐
          │                               │  EPUBSpreadView Setup   │
          │                               │  (WKWebView per spread) │
          │                               └───────────┬─────────────┘
          │                                           │
          │      ┌────────────────────────────────────┘
          │      │
          ▼      ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     Resource Loading                                │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ 1. WebView requests: http://localhost:PORT/chapter.xhtml       │ │
│  │ 2. HTTP Server intercepts                                      │ │
│  │ 3. Publication.get(link) retrieves resource                    │ │
│  │ 4. Decrypt if LCP protected                                    │ │
│  │ 5. Return data with correct Content-Type                       │ │
│  └────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     JavaScript Injection                            │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ Injected scripts:                                              │ │
│  │ • readium-reflowable.js (pagination, gestures)                 │ │
│  │ • Readium CSS (typography, themes)                             │ │
│  │ • User CSS (preferences)                                       │ │
│  │ • Decoration templates (highlights)                            │ │
│  └────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     User Interaction                                │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ • Tap left/right → goLeft()/goRight()                          │ │
│  │ • Swipe → page turn animation                                  │ │
│  │ • Text selection → SelectableNavigator delegate                │ │
│  │ • Keyboard → InputObservable                                   │ │
│  └────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 4. LCP Decryption Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                    LCPService.retrieveLicense()                     │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    LicenseValidation State Machine                  │
│                                                                     │
│   start ──► validateLicense ──► fetchStatus ──► validateStatus     │
│                                                        │            │
│                                                        ▼            │
│   valid ◄── registerDevice ◄── validateIntegrity ◄── requestPassphrase
│     │                               │                  │            │
│     │                               │                  ▼            │
│     │                               │      ┌───────────────────┐    │
│     │                               │      │ LCPAuthenticating │    │
│     │                               │      │ (UI or stored)    │    │
│     │                               │      └───────────────────┘    │
│     │                               │                               │
│     │                               ▼                               │
│     │                    ┌───────────────────┐                      │
│     │                    │   LCPClient       │                      │
│     │                    │ createContext()   │                      │
│     │                    │   (liblcp)        │                      │
│     │                    └───────────────────┘                      │
│     │                                                               │
│     ▼                                                               │
│  LCPLicense (opened, with context)                                  │
└─────────────────────────────────────────────────────────────────────┘

                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Resource Decryption                              │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ 1. Resource requested                                          │ │
│  │ 2. LCPDecryptor checks if encrypted                            │ │
│  │ 3. Read encrypted bytes                                        │ │
│  │ 4. AES-256-CBC decrypt with content key                        │ │
│  │ 5. Remove PKCS#7 padding                                       │ │
│  │ 6. Inflate if compressed                                       │ │
│  │ 7. Return decrypted data                                       │ │
│  └────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 5. Locator Flow (Bookmarking)

```
User taps "Add Bookmark"
         │
         ▼
┌─────────────────────────────────────────┐
│ navigator.currentLocation               │
│   → Returns current Locator             │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│ Locator                                 │
│ {                                       │
│   href: "chapter3.xhtml",               │
│   mediaType: "application/xhtml+xml",   │
│   title: "Chapter 3",                   │
│   locations: {                          │
│     progression: 0.45,                  │
│     totalProgression: 0.23,             │
│     position: 47                        │
│   }                                     │
│ }                                       │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│ Serialize to JSON                       │
│ locator.jsonString                      │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│ Store in database                       │
│ (Your app's responsibility)             │
└─────────────────────────────────────────┘

         ... Later ...

┌─────────────────────────────────────────┐
│ Retrieve from database                  │
│ let json = db.getBookmark()             │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│ Locator(jsonString: json)               │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│ navigator.go(to: locator)               │
│   → Navigates to saved position         │
└─────────────────────────────────────────┘
```

---

## 6. Search Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                    User enters search query                         │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ publication.findService(SearchService.self)?.search(query: "text")  │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    StringSearchService                              │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ For each resource in readingOrder:                             │ │
│  │   1. Load HTML content                                         │ │
│  │   2. Extract text (strip tags)                                 │ │
│  │   3. Search for query (case-insensitive)                       │ │
│  │   4. Create Locator for each match with text context           │ │
│  └────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Returns: LocatorCollection                                          │
│ [                                                                   │
│   Locator(href: "ch1.xhtml", text: { before: "...", highlight: "text", after: "..." }),
│   Locator(href: "ch3.xhtml", text: { ... }),                        │
│   ...                                                               │
│ ]                                                                   │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Display results & apply decorations                                 │
│                                                                     │
│ navigator.apply(decorations: results.map { locator in               │
│     Decoration(id: locator.id, locator: locator,                    │
│                style: .highlight(tint: .yellow))                    │
│ }, in: "search")                                                    │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 7. OPDS Catalog Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                    OPDSParser.parseURL(catalogURL)                  │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Fetch URL content                                │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
              ┌──────────────────┴──────────────────┐
              │                                     │
              ▼                                     ▼
┌─────────────────────────┐           ┌─────────────────────────────┐
│ Content-Type: XML       │           │ Content-Type: JSON          │
│         │               │           │           │                 │
│         ▼               │           │           ▼                 │
│   OPDS1Parser           │           │     OPDS2Parser             │
│   (Atom/XML feed)       │           │     (RWPM JSON)             │
└───────────┬─────────────┘           └───────────┬─────────────────┘
            │                                     │
            └─────────────────┬───────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    ParseData                                        │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ • feed: Feed?         (catalog)                                │ │
│  │ • publication: Publication? (single item)                      │ │
│  │ • version: .opds1 | .opds2                                     │ │
│  │ • url: URL                                                     │ │
│  └────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Feed Structure                                   │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ • metadata: title, itemsPerPage, currentPage                   │ │
│  │ • navigation: [Link] (categories, subcatalogs)                 │ │
│  │ • publications: [Publication] (browsable items)                │ │
│  │ • facets: [Facet] (filters: genre, language)                   │ │
│  │ • groups: [Group] (featured, new releases)                     │ │
│  │ • links: [Link] (self, next, search)                           │ │
│  └────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```
