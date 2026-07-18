//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// Rejects hostile bridge values before any handler promotes them to a DTO.
/// Warnings name only the violated limit; they never echo attacker-controlled data.
enum BridgePayloadBudget {
    enum Rejection: Swift.Error, Equatable {
        case unsupportedValue
        case nonFiniteNumber
        case tooDeep
        case tooManyEntries
        case stringTooLong
        case tooLarge

        var warning: String {
            switch self {
            case .unsupportedValue: "contains a non-JSON value"
            case .nonFiniteNumber: "contains a non-finite number"
            case .tooDeep: "exceeds nesting depth"
            case .tooManyEntries: "exceeds collection entry limit"
            case .stringTooLong: "contains an overlong string"
            case .tooLarge: "exceeds aggregate payload budget"
            }
        }
    }

    static let maxDepth = 8
    static let maxEntries = 64
    static let maxStringBytes = 8_192
    static let maxTotalBytes = 32_768

    static func validate(_ value: Any) -> Result<Void, Rejection> {
        var totalBytes = 0
        return validate(value, depth: 0, totalBytes: &totalBytes)
    }

    private static func validate(
        _ value: Any,
        depth: Int,
        totalBytes: inout Int
    ) -> Result<Void, Rejection> {
        guard depth <= maxDepth else { return .failure(.tooDeep) }
        if value is NSNull || value is Bool { return .success(()) }
        if let number = value as? NSNumber {
            guard number.doubleValue.isFinite else { return .failure(.nonFiniteNumber) }
            totalBytes += MemoryLayout<Double>.size
            return totalBytes <= maxTotalBytes ? .success(()) : .failure(.tooLarge)
        }
        if let string = value as? String {
            let bytes = string.lengthOfBytes(using: .utf8)
            guard bytes <= maxStringBytes else { return .failure(.stringTooLong) }
            totalBytes += bytes
            return totalBytes <= maxTotalBytes ? .success(()) : .failure(.tooLarge)
        }
        if let dictionary = value as? [String: Any] {
            guard dictionary.count <= maxEntries else { return .failure(.tooManyEntries) }
            for (key, child) in dictionary {
                let keyResult = validate(key, depth: depth + 1, totalBytes: &totalBytes)
                guard keyResult.isSuccess else { return keyResult }
                let result = validate(child, depth: depth + 1, totalBytes: &totalBytes)
                guard result.isSuccess else { return result }
            }
            return .success(())
        }
        if let array = value as? [Any] {
            guard array.count <= maxEntries else { return .failure(.tooManyEntries) }
            for child in array {
                let result = validate(child, depth: depth + 1, totalBytes: &totalBytes)
                guard result.isSuccess else { return result }
            }
            return .success(())
        }
        return .failure(.unsupportedValue)
    }
}

private extension Result where Success == Void, Failure == BridgePayloadBudget.Rejection {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
