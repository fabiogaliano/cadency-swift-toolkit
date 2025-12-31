# Glossary

> **Purpose**: Quick reference for terminology used in the Readium Swift Toolkit

## A

**Acquisition Link**
A link in an OPDS catalog that allows obtaining a publication (buy, borrow, download).

**AES-256-CBC**
Advanced Encryption Standard with 256-bit key in Cipher Block Chaining mode. Used by LCP for content encryption.

## C

**CBZ (Comic Book ZIP)**
A comic book archive format consisting of images in a ZIP file.

**Container**
An abstraction for accessing resources in a publication, whether from a ZIP archive, file system, or network.

**Content Key**
In LCP, the symmetric key used to decrypt publication resources. Itself encrypted with the User Key.

**Content Protection**
The DRM layer that handles decryption of protected content. Implements `ContentProtection` protocol.

## D

**Decoration**
A visual overlay on content (highlight, underline, annotation marker). Managed by `DecorableNavigator`.

**DIVINA**
Digital Visual Narratives - Readium's format for visual content like comics and manga.

## E

**EPUB**
Electronic Publication - the dominant ebook format. ZIP archive containing XHTML, CSS, and images.

**EPUBLayout**
Distinguishes between reflowable content (text adapts to screen) and fixed-layout (FXL) content.

## F

**Facet**
A filtering option in OPDS catalogs (e.g., genre, language, format).

**Fixed-Layout (FXL)**
EPUB content with fixed page dimensions, like a PDF or comic book.

**Fragment**
A portion of a URL after `#` that identifies a location within a resource (e.g., `chapter1.xhtml#section2`).

## H

**HREF**
Hypertext Reference - a URL or path pointing to a resource.

## L

**LCP (Licensed Content Protection)**
Readium's open DRM standard for protecting publications with passphrase-based encryption.

**LCPL (LCP License)**
The license file (`license.lcpl`) containing encryption keys and rights information.

**LSD (License Status Document)**
A server-side document tracking the current state of an LCP license (active, expired, returned).

**Link**
A reference to a resource within a publication or catalog, with metadata like media type and relations.

**Locator**
A precise, serializable position within a publication. Used for bookmarks, highlights, and reading positions.

**LocalizedString**
A string that may have translations in multiple languages.

## M

**Manifest**
The structure describing a publication's metadata, reading order, and resources. Based on Readium Web Publication Manifest.

**Media Overlays**
EPUB3 feature for synchronized audio-text playback using SMIL.

**Media Type**
MIME type identifying the format of a resource (e.g., `application/epub+zip`, `text/html`).

## N

**Navigator**
The component responsible for rendering a publication and handling user navigation.

**NCX**
Navigation Control file for XML - EPUB2's table of contents format.

## O

**OPF (Open Packaging Format)**
The package file in EPUB containing metadata and manifest (`content.opf`).

**OPDS**
Open Publication Distribution System - a catalog format for distributing ebooks.

## P

**Pagination**
The process of dividing content into pages for display.

**Position**
A numbered location within a publication, used for "go to page" features.

**Preferences**
User-configurable settings for rendering (font, theme, margins, etc.).

**Presentation**
How content is displayed (scroll vs. paginate, reading direction, spread mode).

**Profile**
A publication type identifier (EPUB, PDF, Audiobook, DIVINA).

**Progression**
A 0.0 to 1.0 value indicating position within a resource or publication.

**Publication**
The main object representing a loaded book, containing manifest, container, and services.

## R

**Reading Order**
The ordered sequence of resources that constitute the "spine" of a publication.

**Reading Progression**
The direction of reading: LTR (left-to-right), RTL (right-to-left), TTB (top-to-bottom).

**Readium CSS**
The CSS framework injected into EPUB content for consistent styling.

**Readium Web Publication Manifest (RWPM)**
The JSON format describing a publication's structure, used internally and for OPDS 2.0.

**Reflowable**
Content that adapts to the available screen size (as opposed to fixed-layout).

**Resource**
A streamable asset within a publication (HTML chapter, image, audio file).

## S

**Selection**
Currently selected text within a navigator, with its locator and visual bounds.

**Service**
A pluggable component providing functionality to a Publication (search, positions, content extraction).

**Spread**
A two-page view in paginated reading mode.

**Streamer**
The component that parses publication files into Publication objects.

## T

**Table of Contents (TOC)**
The hierarchical navigation structure of a publication.

**Templated**
A link whose href is a URI template with placeholders (e.g., `search{?query}`).

**TTS (Text-to-Speech)**
Reading aloud publication content using speech synthesis.

## U

**URI Template**
A URL with variable placeholders (RFC 6570), used for parameterized endpoints like search.

**User Key**
In LCP, the key derived from the user's passphrase, used to decrypt the Content Key.

**UTI (Uniform Type Identifier)**
Apple's system for identifying file types.

## V

**Visual Navigator**
A navigator that displays content visually (EPUB, PDF, CBZ), as opposed to audio-only.

## W

**WKWebView**
Apple's web view component used for rendering EPUB content.

**WPUB (Web Publication)**
A packaged Readium Web Publication as a ZIP file.

## Z

**ZAB (Zipped Audio Book)**
An audiobook format as a ZIP archive of audio files.

**ZIP**
Archive format used as container for EPUB, CBZ, and other packaged publications.

---

## Acronym Quick Reference

| Acronym | Full Name |
|---------|-----------|
| AES | Advanced Encryption Standard |
| CBC | Cipher Block Chaining |
| CBZ | Comic Book ZIP |
| CSS | Cascading Style Sheets |
| DRM | Digital Rights Management |
| EPUB | Electronic Publication |
| FXL | Fixed Layout |
| HREF | Hypertext Reference |
| LCP | Licensed Content Protection |
| LCPL | LCP License |
| LSD | License Status Document |
| LTR | Left-to-Right |
| NCX | Navigation Control file for XML |
| OPF | Open Packaging Format |
| OPDS | Open Publication Distribution System |
| RTL | Right-to-Left |
| RWPM | Readium Web Publication Manifest |
| SMIL | Synchronized Multimedia Integration Language |
| TOC | Table of Contents |
| TTB | Top-to-Bottom |
| TTS | Text-to-Speech |
| URI | Uniform Resource Identifier |
| UTI | Uniform Type Identifier |
| WCAG | Web Content Accessibility Guidelines |
| ZAB | Zipped Audio Book |
