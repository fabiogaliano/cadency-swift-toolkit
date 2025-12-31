# Readium Swift Toolkit - Codebase Analysis

> **Generated**: 2024-12-31
> **Purpose**: Comprehensive documentation for iterative learning with pragmatic-mentor

## Quick Start

This is the **Readium Swift Toolkit** - a Swift library for building iOS reading applications that support EPUB, PDF, audiobooks, and comics.

### What This Toolkit Does

```
┌────────────────────────────────────────────────────────────────┐
│                     YOUR iOS READING APP                       │
└───────────────────────────────┬────────────────────────────────┘
                                │
     ┌──────────────────────────┼──────────────────────────────┐
     │                          │                              │
     ▼                          ▼                              ▼
┌─────────┐               ┌───────────┐               ┌─────────────┐
│ OPEN    │               │  RENDER   │               │  DISCOVER   │
│         │               │           │               │             │
│ EPUB    │               │ Paginated │               │ OPDS        │
│ PDF     │───────────────│ Scrolling │───────────────│ Catalogs    │
│ Audio   │   Streamer    │ TTS       │   Navigator   │             │
│ Comics  │               │ Search    │               │             │
└─────────┘               └───────────┘               └─────────────┘
```

### Core Concepts (5-Minute Overview)

1. **Publication** - A loaded book with its content and metadata
2. **Manifest** - The structure describing what's in the publication
3. **Locator** - A precise position (for bookmarks, highlights)
4. **Navigator** - The view controller that renders content
5. **Container** - Access layer to resources (files, archives, network)

---

## Documentation Index

### Essential (Start Here)

| File | Description | When to Read |
|------|-------------|--------------|
| [01-architecture.md](./01-architecture.md) | Module hierarchy, responsibilities | First, for big picture |
| [02-modules.md](./02-modules.md) | Detailed module breakdown | When exploring specific modules |
| [03-data-models.md](./03-data-models.md) | Core types (Publication, Locator, Link) | When working with data |

### Deep Dives

| File | Description | When to Read |
|------|-------------|--------------|
| [04-patterns.md](./04-patterns.md) | Design patterns used | Understanding code style |
| [05-flows.md](./05-flows.md) | Data flow diagrams | Understanding how pieces connect |
| [06-dependencies.md](./06-dependencies.md) | Third-party libraries | Setup and dependency questions |

### Feature-Specific

| File | Description | When to Read |
|------|-------------|--------------|
| [07-navigator.md](./07-navigator.md) | Navigator protocols, EPUB/PDF rendering | Building reader UI |
| [08-javascript.md](./08-javascript.md) | WebView JavaScript integration | EPUB rendering, gestures |
| [09-drm-lcp.md](./09-drm-lcp.md) | LCP DRM implementation | Protected content |
| [10-opds.md](./10-opds.md) | OPDS catalog parsing | Catalog browsing |

### Reference

| File | Description | When to Read |
|------|-------------|--------------|
| [11-glossary.md](./11-glossary.md) | Terminology definitions | When encountering new terms |

---

## Module Summary

| Module | Purpose | Key Entry Points |
|--------|---------|------------------|
| **ReadiumShared** | Core types, services | `Publication`, `Manifest`, `Locator` |
| **ReadiumStreamer** | Parse files into publications | `PublicationOpener`, `EPUBParser` |
| **ReadiumNavigator** | Render publications | `EPUBNavigatorViewController`, `PDFNavigatorViewController` |
| **ReadiumOPDS** | Catalog parsing | `OPDSParser` |
| **ReadiumLCP** | DRM support | `LCPService` |

---

## Key Files Quick Reference

### When You Need To...

**Open a publication:**
```
Sources/Streamer/PublicationOpener.swift
Sources/Streamer/Parser/EPUB/EPUBParser.swift
```

**Display EPUB content:**
```
Sources/Navigator/EPUB/EPUBNavigatorViewController.swift
Sources/Navigator/EPUB/EPUBContinuousNavigatorViewController.swift (continuous scroll)
```

**Work with positions/bookmarks:**
```
Sources/Shared/Publication/Locator.swift
Sources/Shared/Publication/Services/Positions/PositionsService.swift
```

**Customize appearance:**
```
Sources/Navigator/EPUB/Preferences/EPUBPreferences.swift
Sources/Navigator/EPUB/Assets/Static/readium-css/
```

**Handle DRM:**
```
Sources/LCP/LCPService.swift
Sources/LCP/Content Protection/LCPDecryptor.swift
```

**Parse catalogs:**
```
Sources/OPDS/OPDSParser.swift
Sources/OPDS/OPDS1Parser.swift
Sources/OPDS/OPDS2Parser.swift
```

---

## Current Work in Progress

Based on git status, active development includes:

### Continuous Scroll Navigator (NEW)
```
Sources/Navigator/EPUB/EPUBContinuousNavigatorViewController.swift
Sources/Navigator/EPUB/Assets/continuous-wrapper.html
Sources/Navigator/EPUB/Scripts/src/index-continuous-wrapper.js
```

This adds a new **vertical continuous scrolling** mode for EPUB, complementing the existing paginated view.

---

## Learning Path

### Level 1: Understanding the Architecture
1. Read [01-architecture.md](./01-architecture.md) for the big picture
2. Skim [02-modules.md](./02-modules.md) to understand module responsibilities
3. Review [11-glossary.md](./11-glossary.md) for unfamiliar terms

### Level 2: Working with Publications
1. Study [03-data-models.md](./03-data-models.md) - understand Publication, Manifest, Locator
2. Read [05-flows.md](./05-flows.md) - "Opening a Publication" flow
3. Explore [04-patterns.md](./04-patterns.md) - Service Architecture pattern

### Level 3: Building Reader Features
1. Deep dive into [07-navigator.md](./07-navigator.md)
2. Understand [08-javascript.md](./08-javascript.md) for EPUB rendering
3. Study preferences system in `EPUBPreferences`

### Level 4: Advanced Topics
1. [09-drm-lcp.md](./09-drm-lcp.md) for DRM support
2. [10-opds.md](./10-opds.md) for catalog browsing
3. Continuous scroll implementation details

---

## Pragmatic Mentor Usage

When using these docs with the pragmatic-mentor skill, you can say:

> "Load up the codebase analysis docs and help me understand [topic]"

Or for specific learning:

> "Walk me through the [architecture/navigator/LCP] documentation iteratively"

The mentor can then:
1. Reference specific documentation sections
2. Ask Socratic questions to test understanding
3. Build mental models using the diagrams
4. Create Anki cards from key concepts

---

## Project Stats

| Metric | Count |
|--------|-------|
| Swift Files | ~500+ |
| Modules | 7 (+ 2 adapters) |
| External Dependencies | 8 |
| Supported Formats | EPUB, PDF, Audiobook, CBZ, DIVINA |
| iOS Minimum | 13.4 |
| Swift Version | 5.10 / 6.0 |

---

## File Structure

```
claudedocs/codebase-analysis/
├── 00-OVERVIEW.md          ← You are here
├── 01-architecture.md      ← Module hierarchy
├── 02-modules.md           ← Module details
├── 03-data-models.md       ← Core types
├── 04-patterns.md          ← Design patterns
├── 05-flows.md             ← Data flows
├── 06-dependencies.md      ← Third-party libs
├── 07-navigator.md         ← Reader rendering
├── 08-javascript.md        ← WebView integration
├── 09-drm-lcp.md           ← DRM/LCP
├── 10-opds.md              ← Catalog support
└── 11-glossary.md          ← Terminology
```

---

## Tips for Navigation

1. **Use file references** - Each doc links to related docs
2. **Search by concept** - Check the glossary first
3. **Follow the flows** - Diagrams show how pieces connect
4. **Check key files** - Each section lists relevant source files

---

*This documentation was generated by analyzing the Readium Swift Toolkit codebase for iterative learning with the pragmatic-mentor skill.*
