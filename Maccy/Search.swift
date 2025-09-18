import AppKit
import Defaults
import Fuse

class Search {
  enum Mode: String, CaseIterable, Identifiable, CustomStringConvertible, Defaults.Serializable {
    case exact
    case fuzzy
    case regexp
    case mixed

    var id: Self { self }

    var description: String {
      switch self {
      case .exact:
        return NSLocalizedString("Exact", tableName: "GeneralSettings", comment: "")
      case .fuzzy:
        return NSLocalizedString("Fuzzy", tableName: "GeneralSettings", comment: "")
      case .regexp:
        return NSLocalizedString("Regex", tableName: "GeneralSettings", comment: "")
      case .mixed:
        return NSLocalizedString("Mixed", tableName: "GeneralSettings", comment: "")
      }
    }
  }

  struct SearchResult: Equatable {
    var score: Double?
    var object: Searchable
    var ranges: [Range<String.Index>] = []
  }

  typealias Searchable = HistoryItemDecorator

  private let fuse = Fuse(threshold: 0.7) // threshold found by trial-and-error
  private let fuzzySearchLimit = 5_000
  private let alphanumericSet = CharacterSet.alphanumerics

  func search(string: String, within: [Searchable]) -> [SearchResult] {
    guard !string.isEmpty else {
      return within.map { SearchResult(object: $0) }
    }

    switch Defaults[.searchMode] {
    case .mixed:
      return mixedSearch(string: string, within: within)
    case .regexp:
      return simpleSearch(string: string, within: within, options: .regularExpression)
    case .fuzzy:
      return fuzzySearch(string: string, within: within)
    default:
      return simpleSearch(string: string, within: within, options: .caseInsensitive)
    }
  }

  private func fuzzySearch(string: String, within: [Searchable]) -> [SearchResult] {
    let pattern = fuse.createPattern(from: string)
    let searchResults: [SearchResult] = within.compactMap { item in
      fuzzySearch(for: pattern, in: item.title, of: item)
    }
    let sortedResults = searchResults.sorted(by: { ($0.score ?? 0) < ($1.score ?? 0) })
    return sortedResults
  }

  private func fuzzySearch(
    for pattern: Fuse.Pattern?,
    in searchString: String,
    of item: Searchable
  ) -> SearchResult? {
    var searchString = searchString
    if searchString.count > fuzzySearchLimit {
      // shortcut to avoid slow search
      let stopIndex = searchString.index(searchString.startIndex, offsetBy: fuzzySearchLimit)
      searchString = "\(searchString[...stopIndex])"
    }

    if let fuzzyResult = fuse.search(pattern, in: searchString) {
      return SearchResult(
        score: fuzzyResult.score,
        object: item,
        ranges: fuzzyResult.ranges.map {
          let startIndex = searchString.startIndex
          let lowerBound = searchString.index(startIndex, offsetBy: $0.lowerBound)
          let upperBound = searchString.index(startIndex, offsetBy: $0.upperBound + 1)

          return lowerBound..<upperBound
        }
      )
    } else {
      return nil
    }
  }

  private func simpleSearch(
    string: String,
    within: [Searchable],
    options: NSString.CompareOptions
  ) -> [SearchResult] {
    return within.compactMap { simpleSearch(for: string, in: $0.title, of: $0, options: options) }
  }

  private func simpleSearch(
    for string: String,
    in searchString: String,
    of item: Searchable,
    options: NSString.CompareOptions
  ) -> SearchResult? {
    if let range = searchString.range(of: string, options: options, range: nil, locale: nil) {
      return SearchResult(object: item, ranges: [range])
    } else {
      return nil
    }
  }

  private func mixedSearch(string: String, within: [Searchable]) -> [SearchResult] {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return within.map { SearchResult(object: $0) }
    }

    let tokens = normalizedTokens(from: trimmed)
    let pattern = fuse.createPattern(from: trimmed)

    var combinedResults: [UUID: SearchResult] = [:]
    var fuzzyFallback: [SearchResult] = []

    for item in within {
      if let tokenResult = tokenMatch(tokens: tokens, originalQuery: trimmed, in: item) {
        combinedResults[item.id] = tokenResult
        continue
      }

      if let regexResult = regexMatch(trimmed, in: item) {
        combinedResults[item.id] = regexResult
        continue
      }

      if let fuzzyResult = fuzzySearch(for: pattern, in: item.title, of: item) {
        var adjusted = fuzzyResult
        adjusted.score = (adjusted.score ?? 1) + 1_000
        fuzzyFallback.append(adjusted)
      }
    }

    for result in fuzzyFallback where combinedResults[result.object.id] == nil {
      combinedResults[result.object.id] = result
    }

    return combinedResults.values.sorted { ($0.score ?? 0) < ($1.score ?? 0) }
  }

  private func normalizedTokens(from query: String) -> [String] {
    var uniqueTokens: [String] = []
    let rawTokens = query.lowercased().split(whereSeparator: { $0.isWhitespace })
    for token in rawTokens {
      let tokenString = String(token)
      if !tokenString.isEmpty && !uniqueTokens.contains(tokenString) {
        uniqueTokens.append(tokenString)
      }
    }

    if uniqueTokens.isEmpty {
      uniqueTokens.append(query.lowercased())
    }

    return uniqueTokens
  }

  private func tokenMatch(tokens: [String], originalQuery: String, in item: Searchable) -> SearchResult? {
    let searchString = item.title
    guard !searchString.isEmpty else { return nil }

    if let exactRange = searchString.range(of: originalQuery, options: [.caseInsensitive, .diacriticInsensitive]) {
      let score = score(for: exactRange, in: searchString, isExact: true)
      return SearchResult(score: score, object: item, ranges: [exactRange])
    }

    var ranges: [Range<String.Index>] = []
    var totalScore: Double = 0

    for token in tokens {
      guard let range = searchString.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) else {
        return nil
      }

      totalScore += score(for: range, in: searchString, isExact: false)
      ranges.append(range)
    }

    guard !ranges.isEmpty else { return nil }

    let mergedRanges = mergeRanges(ranges)
    return SearchResult(score: totalScore, object: item, ranges: mergedRanges)
  }

  private func regexMatch(_ pattern: String, in item: Searchable) -> SearchResult? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return nil
    }

    let searchString = item.title
    guard !searchString.isEmpty else { return nil }

    let nsRange = NSRange(location: 0, length: searchString.utf16.count)
    let matches = regex.matches(in: searchString, range: nsRange)
    guard !matches.isEmpty else { return nil }

    let highlightRanges = matches.compactMap { Range($0.range, in: searchString) }
    let score = matches.first.map { Double($0.range.location) } ?? 0
    return SearchResult(score: score, object: item, ranges: highlightRanges)
  }

  private func score(
    for range: Range<String.Index>,
    in searchString: String,
    isExact: Bool
  ) -> Double {
    let startDistance = searchString.distance(from: searchString.startIndex, to: range.lowerBound)
    let matchLength = searchString.distance(from: range.lowerBound, to: range.upperBound)
    var score = Double(startDistance)

    if range.lowerBound == searchString.startIndex {
      score -= 150
    } else if isWordBoundary(in: searchString, before: range.lowerBound) {
      score -= 50
    }

    if isExact {
      score -= 200
    }

    score += Double(matchLength) / Double(max(searchString.count, 1))
    return score
  }

  private func isWordBoundary(in string: String, before index: String.Index) -> Bool {
    guard index > string.startIndex else { return true }
    let previousIndex = string.index(before: index)
    let scalars = string[previousIndex].unicodeScalars
    guard let scalar = scalars.first else { return true }
    return !alphanumericSet.contains(scalar)
  }

  private func mergeRanges(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
    guard !ranges.isEmpty else { return [] }

    let sortedRanges = ranges.sorted { $0.lowerBound < $1.lowerBound }
    var merged: [Range<String.Index>] = []

    for range in sortedRanges {
      if var last = merged.last, last.upperBound >= range.lowerBound {
        if range.upperBound > last.upperBound {
          last = last.lowerBound..<range.upperBound
        }
        merged[merged.count - 1] = last
      } else {
        merged.append(range)
      }
    }

    return merged
  }
}
