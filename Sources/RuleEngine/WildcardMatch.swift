//
//  WildcardMatch.swift
//  MacStroke
//
//  Port of the original utils.m helpers `wildcardArray` / `wildcardString`.
//  The original evaluates `NSPredicate "self LIKE %@"`, i.e. a whole-string
//  anchored match where `*` stands for any run of characters and `?` for
//  exactly one character. Case folding is done by lowercasing both sides
//  instead of using the LIKE[c] flag.
//

import Foundation

/// LIKE-match `text` against a single wildcard pattern (anchored, `*` / `?`).
func wildcardLikeMatch(_ text: String, _ pattern: String) -> Bool {
    let pattern = Array(pattern)
    let text = Array(text)
    let pCount = pattern.count + 1
    let tCount = text.count + 1

    // matches(i, j): pattern[i...] matches text[j...]; whole-string anchored.
    var matches = Array(repeating: false, count: pCount * tCount)
    func read(_ i: Int, _ j: Int) -> Bool { matches[i * tCount + j] }
    func write(_ i: Int, _ j: Int, _ value: Bool) { matches[i * tCount + j] = value }

    write(pCount - 1, tCount - 1, true)
    for i in stride(from: pattern.count - 1, through: 0, by: -1) {
        switch pattern[i] {
        case "*":
            for j in stride(from: text.count, through: 0, by: -1) {
                write(i, j, read(i + 1, j) || (j < text.count && read(i, j + 1)))
            }
        case "?":
            for j in stride(from: text.count - 1, through: 0, by: -1) {
                write(i, j, read(i + 1, j + 1))
            }
        default:
            for j in stride(from: text.count - 1, through: 0, by: -1) {
                write(i, j, text[j] == pattern[i] && read(i + 1, j + 1))
            }
        }
    }
    return read(0, 0)
}

/// Original `wildcardArray`: any pattern in the list may match.
func wildcardArray(_ text: String, patterns: [String], ignoreCase: Bool) -> Bool {
    let haystack = ignoreCase ? text.lowercased() : text
    for pattern in patterns {
        let needle = ignoreCase ? pattern.lowercased() : pattern
        if wildcardLikeMatch(haystack, needle) { return true }
    }
    return false
}

/// Original `wildcardString`: the pattern list is split on `|` and newlines.
func wildcardString(_ text: String, patterns: String, ignoreCase: Bool) -> Bool {
    let parts = patterns.components(separatedBy: CharacterSet(charactersIn: "|\n"))
    return wildcardArray(text, patterns: parts, ignoreCase: ignoreCase)
}
