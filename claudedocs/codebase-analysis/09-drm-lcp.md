# LCP (Licensed Content Protection)

> **Purpose**: DRM implementation for protecting publications

## What is LCP?

**Readium LCP** (Licensed Content Protection) is an open DRM standard created by the Readium Foundation. It protects ebooks while being:
- **Interoperable** - Works across any LCP-compliant reader
- **User-friendly** - Simple passphrase-based access
- **Privacy-preserving** - No tracking, no online requirement after acquisition

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Your Reading App                             │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         LCPService                                  │
│  • retrieveLicense()    - Get license from publication              │
│  • contentProtection()  - Create ContentProtection for Streamer     │
│  • acquirePublication() - Download + import protected publication   │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              │                  │                  │
              ▼                  ▼                  ▼
┌─────────────────────┐ ┌─────────────────┐ ┌─────────────────────┐
│ LicenseValidation   │ │  LCPDecryptor   │ │ LCPAuthenticating   │
│ (State Machine)     │ │ (AES-256-CBC)   │ │ (Passphrase UI)     │
└─────────────────────┘ └─────────────────┘ └─────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      R2LCPClient.framework                          │
│                      (Private, from EDRLab)                         │
│  • liblcp C library wrapper                                         │
│  • Certificate validation                                           │
│  • Cryptographic operations                                         │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Encryption Model

LCP uses a **three-layer encryption** system:

```
┌─────────────────────────────────────────────────────────────────────┐
│ Layer 1: User Passphrase                                            │
│                                                                     │
│   User enters: "MySecretPassword123"                                │
│                     │                                               │
│                     ▼                                               │
│   SHA-256 hash: a1b2c3d4e5f6...                                    │
└─────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Layer 2: User Key (in License Document)                             │
│                                                                     │
│   {                                                                 │
│     "algorithm": "http://www.w3.org/2001/04/xmlenc#aes256-cbc",    │
│     "text_hint": "Enter your library passphrase",                   │
│     "key_check": "base64-encoded-check-value"                       │
│   }                                                                 │
│                                                                     │
│   User Key derived via PBKDF2:                                      │
│     PBKDF2(password_hash, salt, 10000 iterations)                   │
└─────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Layer 3: Content Key (encrypted in License)                         │
│                                                                     │
│   {                                                                 │
│     "algorithm": "http://www.w3.org/2001/04/xmlenc#aes256-cbc",    │
│     "encrypted_value": "base64-encrypted-content-key"               │
│   }                                                                 │
│                                                                     │
│   Decrypt with User Key → Content Key (32 bytes)                    │
└─────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Resource Decryption                                                 │
│                                                                     │
│   For each encrypted resource:                                      │
│     1. Read encrypted bytes                                         │
│     2. Extract IV (first 16 bytes)                                  │
│     3. AES-256-CBC decrypt with Content Key + IV                    │
│     4. Remove PKCS#7 padding                                        │
│     5. Inflate if compressed                                        │
└─────────────────────────────────────────────────────────────────────┘
```

---

## License Document Structure

**File**: `META-INF/license.lcpl` (inside EPUB)

```json
{
  "id": "license-uuid-here",
  "issued": "2024-01-15T10:00:00Z",
  "provider": "https://library.example.com",

  "encryption": {
    "profile": "http://readium.org/lcp/profile-1.0",
    "content_key": {
      "algorithm": "http://www.w3.org/2001/04/xmlenc#aes256-cbc",
      "encrypted_value": "base64..."
    },
    "user_key": {
      "algorithm": "http://www.w3.org/2001/04/xmlenc#aes256-cbc",
      "text_hint": "Your library card number",
      "key_check": "base64..."
    }
  },

  "links": [
    { "rel": "hint", "href": "https://library.example.com/hint" },
    { "rel": "publication", "href": "https://library.example.com/book.epub" },
    { "rel": "status", "href": "https://library.example.com/license/status" }
  ],

  "rights": {
    "print": 10,
    "copy": 1000,
    "start": "2024-01-15T00:00:00Z",
    "end": "2024-02-15T00:00:00Z"
  },

  "user": {
    "id": "user-uuid",
    "email": "user@example.com"
  },

  "signature": {
    "algorithm": "http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha256",
    "certificate": "base64-certificate",
    "value": "base64-signature"
  }
}
```

---

## Status Document (LSD)

Retrieved from `status` link for real-time license state:

```json
{
  "id": "license-uuid",
  "status": "active",
  "message": "Your loan is active",
  "updated": {
    "license": "2024-01-15T10:00:00Z",
    "status": "2024-01-15T12:00:00Z"
  },
  "links": [
    { "rel": "license", "href": "..." },
    { "rel": "register", "href": "...", "templated": true },
    { "rel": "return", "href": "..." },
    { "rel": "renew", "href": "..." }
  ],
  "potential_rights": {
    "end": "2024-03-15T00:00:00Z"
  },
  "events": [
    { "type": "register", "timestamp": "...", "id": "device-1" }
  ]
}
```

### Status Values

| Status | Meaning |
|--------|---------|
| `ready` | License issued, not yet used |
| `active` | License in use |
| `revoked` | License revoked by provider |
| `returned` | User returned the loan |
| `cancelled` | License cancelled before use |
| `expired` | Past end date |

---

## Key Files

### Service Layer

| File | Purpose |
|------|---------|
| `LCPService.swift` | Main entry point |
| `LCPLicense.swift` | Opened license protocol |
| `License.swift` | Internal license implementation |
| `LCPClient.swift` | Bridge to liblcp |

### Validation

| File | Purpose |
|------|---------|
| `LicenseValidation.swift` | State machine for validation |
| `LicenseDocument.swift` | Parse license JSON |
| `StatusDocument.swift` | Parse status JSON |

### Decryption

| File | Purpose |
|------|---------|
| `LCPDecryptor.swift` | Resource decryption |
| `LCPContentProtection.swift` | Streamer integration |

### Authentication

| File | Purpose |
|------|---------|
| `LCPAuthenticating.swift` | Passphrase provider protocol |
| `LCPDialogAuthentication.swift` | UI dialog provider |
| `LCPPassphraseAuthentication.swift` | Pre-stored passphrase |

### Persistence

| File | Purpose |
|------|---------|
| `LCPLicenseRepository.swift` | License storage protocol |
| `LCPPassphraseRepository.swift` | Passphrase cache protocol |

---

## Integration Guide

### 1. Setup LCPService

```swift
import ReadiumLCP
import ReadiumAdapterLCPSQLite

// Create repositories (SQLite-based)
let db = Database.shared
let licenseRepo = SQLiteLCPLicenseRepository(database: db)
let passphraseRepo = SQLiteLCPPassphraseRepository(database: db)

// Create LCP service
let lcpService = LCPService(
    client: LCPClient(),  // Requires R2LCPClient.framework
    licenseRepository: licenseRepo,
    passphraseRepository: passphraseRepo,
    httpClient: DefaultHTTPClient()
)
```

### 2. Create Content Protection

```swift
// For Streamer
let contentProtection = lcpService.contentProtection(
    authentication: LCPDialogAuthentication()
)

let opener = PublicationOpener(
    parser: DefaultPublicationParser(...),
    contentProtections: [contentProtection]
)
```

### 3. Open Protected Publication

```swift
let result = await opener.open(asset: asset)

switch result {
case .success(let publication):
    // Publication is decrypted transparently
    // Just use it normally
    let navigator = EPUBNavigatorViewController(publication: publication)

case .failure(let error):
    if let lcpError = error as? LCPError {
        switch lcpError {
        case .licenseNotFound:
            showError("This book is not licensed")
        case .passphraseNotFound:
            showError("Please enter your passphrase")
        case .licenseExpired:
            showError("Your loan has expired")
        default:
            showError(lcpError.localizedDescription)
        }
    }
}
```

### 4. Custom Authentication

```swift
// Provide passphrase programmatically
class MyAuthenticator: LCPAuthenticating {
    func retrievePassphrase(
        for license: LCPAuthenticatedLicense,
        reason: LCPAuthenticationReason,
        allowUserInteraction: Bool
    ) async -> String? {
        // Look up passphrase from your storage
        return myDatabase.getPassphrase(for: license.document.id)
    }
}

let protection = lcpService.contentProtection(
    authentication: MyAuthenticator()
)
```

---

## Validation State Machine

```
┌─────────────────────────────────────────────────────────────────────┐
│                    LicenseValidation States                         │
│                                                                     │
│   start ──────────────────────────────────────────────────────┐    │
│     │                                                          │    │
│     ▼                                                          │    │
│   validateLicense ─────────────────────────────────────────┐   │    │
│     │ Parse license.lcpl                                   │   │    │
│     │                                                      │   │    │
│     ▼                                                      │   │    │
│   fetchStatus ─────────────────────────────────────────┐   │   │    │
│     │ GET status document (optional)                   │   │   │    │
│     │                                                  │   │   │    │
│     ▼                                                  │   │   │    │
│   validateStatus ──────────────────────────────────┐   │   │   │    │
│     │ Check status: active/expired/revoked         │   │   │   │    │
│     │                                              │   │   │   │    │
│     ▼                                              │   │   │   │    │
│   fetchLicense ────────────────────────────────┐   │   │   │   │    │
│     │ Get updated license if available         │   │   │   │   │    │
│     │                                          │   │   │   │   │    │
│     ▼                                          │   │   │   │   │    │
│   checkLicenseStatus ──────────────────────┐   │   │   │   │   │    │
│     │ Verify dates, revocation             │   │   │   │   │   │    │
│     │                                      │   │   │   │   │   │    │
│     ▼                                      │   │   │   │   │   │    │
│   requestPassphrase ───────────────────┐   │   │   │   │   │   │    │
│     │ Ask user for passphrase          │   │   │   │   │   │   │    │
│     │                                  │   │   │   │   │   │   │    │
│     ▼                                  │   │   │   │   │   │   │    │
│   validateIntegrity ───────────────┐   │   │   │   │   │   │   │    │
│     │ Verify signature with liblcp │   │   │   │   │   │   │   │    │
│     │ Create decryption context    │   │   │   │   │   │   │   │    │
│     │                              │   │   │   │   │   │   │   │    │
│     ▼                              │   │   │   │   │   │   │   │    │
│   registerDevice ──────────────┐   │   │   │   │   │   │   │   │    │
│     │ Register with LSD        │   │   │   │   │   │   │   │   │    │
│     │                          │   │   │   │   │   │   │   │   │    │
│     ▼                          ▼   ▼   ▼   ▼   ▼   ▼   ▼   ▼   │    │
│   valid ◄──────────────────────────────────────────────────────┘    │
│     │                                                               │
│     └──► License ready for use                                      │
│                                                                     │
│                          OR                                         │
│                                                                     │
│   failure ◄──────────────────────────────────────────────────────┘  │
│     │                                                               │
│     └──► LCPError returned                                          │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Error Handling

```swift
public enum LCPError: Error {
    // License issues
    case licenseNotFound
    case licenseIntegrity(message: String)
    case licenseStatus(status: StatusDocument.Status)
    case licenseExpired(start: Date?, end: Date?)

    // Authentication
    case passphraseNotFound
    case invalidPassphrase

    // Network
    case network(Error)
    case unexpectedServerError

    // Content
    case contentNotProtected
    case decryption(Error)

    // Container
    case missingLicense
    case corruptedLicense
}
```

---

## Rights Management

### Checking Rights

```swift
if let license = publication.findService(ContentProtectionService.self)?.license as? LCPLicense {
    // Check if can copy
    if license.canCopy {
        // Copy allowed
    }

    // Check remaining copies
    let remaining = license.remainingCopies  // nil = unlimited

    // Check expiration
    if let end = license.rights?.end, end < Date() {
        showError("License expired")
    }
}
```

### Consuming Rights

```swift
// When user copies text
func copyText(_ text: String) {
    let charCount = text.count

    if license.consumeCopy(characters: charCount) {
        // Copy successful
        UIPasteboard.general.string = text
    } else {
        showError("Copy limit reached")
    }
}
```

---

## Loan Operations

### Return Loan

```swift
try await license.returnLoan()
// Book returned to library
```

### Renew Loan

```swift
// Check if renewal available
if let renewURL = license.renewURL {
    // Option 1: Web-based renewal
    await UIApplication.shared.open(renewURL)

    // Option 2: Programmatic renewal
    try await license.renewLoan(end: newEndDate)
}
```

---

## Requirements

1. **R2LCPClient.framework** - Private framework from EDRLab
   - Contact: contact@edrlab.org
   - Contains liblcp for cryptographic operations

2. **Certificate** - Production LCP certificate
   - Required for validating license signatures
   - Development certificates available for testing
