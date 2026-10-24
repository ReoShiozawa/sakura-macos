// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include "sakura/core/search/SearchEngine.h"

#include <algorithm>
#include <limits>
#include <memory>
#include <stdexcept>

#include <unicode/uregex.h>

namespace sakura::core {
namespace {

SakuraChar folded(SakuraChar value, bool caseSensitive) noexcept {
  if (caseSensitive || value < u'A' || value > u'Z') return value;
  return static_cast<SakuraChar>(value + (u'a' - u'A'));
}

bool isAsciiWord(SakuraChar value) noexcept {
  return (value >= u'a' && value <= u'z') ||
         (value >= u'A' && value <= u'Z') ||
         (value >= u'0' && value <= u'9') || value == u'_';
}

bool wholeWordMatches(SakuraStringView text, std::size_t start,
                      std::size_t end, const SearchOptions& options) noexcept {
  return !options.wholeWord ||
         (!(start != 0 && isAsciiWord(text[start - 1])) &&
          !(end < text.size() && isAsciiWord(text[end])));
}

void checkCancellation(const SearchOptions& options) {
  if (options.cancelled && options.cancelled()) {
    throw std::runtime_error("Search cancelled");
  }
}

std::optional<SearchMatch> findLiteralInRange(
    const TextBuffer& buffer, SakuraStringView text, SakuraStringView needle,
    std::size_t begin, std::size_t end, const SearchOptions& options) {
  checkCancellation(options);
  if (needle.size() > end - begin) return std::nullopt;
  const std::size_t last = end - needle.size();
  for (std::size_t offset = begin; offset <= last; ++offset) {
    if ((offset - begin) % 4096 == 0) checkCancellation(options);
    const auto matchEnd = offset + needle.size();
    bool matched = true;
    for (std::size_t index = 0; index < needle.size(); ++index) {
      if (folded(text[offset + index], options.caseSensitive) !=
          folded(needle[index], options.caseSensitive)) {
        matched = false;
        break;
      }
    }
    // Most positions do not match even the first code unit. Only successful
    // candidates need the line-index lookups used to protect edit boundaries.
    if (matched && buffer.isEditBoundary(offset) &&
        buffer.isEditBoundary(matchEnd) &&
        wholeWordMatches(text, offset, matchEnd, options)) {
      return SearchMatch{{static_cast<TextOffset>(offset),
                          static_cast<TextOffset>(needle.size())}, {}};
    }
  }
  return std::nullopt;
}

using Regex = std::unique_ptr<URegularExpression, decltype(&uregex_close)>;

Regex compileRegex(SakuraStringView pattern, const SearchOptions& options) {
  if (pattern.size() > static_cast<std::size_t>(INT32_MAX)) {
    return {nullptr, uregex_close};
  }
  static_assert(sizeof(UChar) == sizeof(SakuraChar));
  UErrorCode status = U_ZERO_ERROR;
  const std::uint32_t flags = options.caseSensitive ? 0 : UREGEX_CASE_INSENSITIVE;
  Regex regex(uregex_open(reinterpret_cast<const UChar*>(pattern.data()),
                         static_cast<std::int32_t>(pattern.size()), flags,
                         nullptr, &status), uregex_close);
  if (U_FAILURE(status)) regex.reset();
  return regex;
}

void checkStatus(UErrorCode status) {
  if (U_FAILURE(status)) {
    // Never silently apply only part of a replacement after a search error.
    throw std::runtime_error("Unicode regular expression search failed");
  }
}

// Exceptions must not cross ICU's C callback boundary. A throwing callback is
// treated as a request to stop, then reported by checkStatus after ICU returns.
bool continueSearch(const void* context) noexcept {
  const auto& options = *static_cast<const SearchOptions*>(context);
  try { return !options.cancelled || !options.cancelled(); }
  catch (...) { return false; }
}

UBool U_CALLCONV regexMatchProgress(const void* context, std::int32_t) {
  return continueSearch(context);
}

UBool U_CALLCONV regexFindProgress(const void* context, std::int64_t) {
  return continueSearch(context);
}

class RegexSearch {
 public:
  RegexSearch(const TextBuffer& buffer, const SakuraString& text,
              SakuraStringView pattern, SearchOptions options)
      : buffer_(buffer), text_(text), options_(options),
        regex_(compileRegex(pattern, options)) {
    if (!regex_) return;
    if (text.size() > static_cast<std::size_t>(INT32_MAX)) {
      throw std::length_error("regular expression text exceeds ICU UTF-16 limit");
    }
    UErrorCode status = U_ZERO_ERROR;
    uregex_setText(regex_.get(), reinterpret_cast<const UChar*>(text.data()),
                   static_cast<std::int32_t>(text.size()), &status);
    uregex_setTimeLimit(regex_.get(), std::max<std::int32_t>(1,
        options_.regexTimeLimitMilliseconds), &status);
    uregex_setMatchCallback(regex_.get(), regexMatchProgress, &options_, &status);
    uregex_setFindProgressCallback(regex_.get(), regexFindProgress, &options_, &status);
    checkStatus(status);
  }

  std::optional<SearchMatch> find(std::size_t begin, std::size_t end) {
    checkCancellation(options_);
    if (!regex_) return std::nullopt;
    UErrorCode status = U_ZERO_ERROR;
    // Always retain the full source as anchor and lookaround context.
    UBool found = uregex_find(regex_.get(), static_cast<std::int32_t>(begin),
                             &status);
    while (found && U_SUCCESS(status)) {
      const auto start = uregex_start(regex_.get(), 0, &status);
      const auto limit = uregex_end(regex_.get(), 0, &status);
      checkStatus(status);
      if (static_cast<std::size_t>(limit) > end) return std::nullopt;
      if (buffer_.isEditBoundary(start) && buffer_.isEditBoundary(limit) &&
          wholeWordMatches(text_, start, limit, options_)) {
        SearchMatch match{{static_cast<TextOffset>(start),
                            static_cast<TextOffset>(limit - start)}, {}};
        const auto count = uregex_groupCount(regex_.get(), &status);
        match.captures.reserve(static_cast<std::size_t>(count) + 1);
        for (std::int32_t group = 0; group <= count; ++group) {
          const auto groupStart = uregex_start(regex_.get(), group, &status);
          const auto groupEnd = uregex_end(regex_.get(), group, &status);
          if (groupStart < 0) match.captures.push_back(std::nullopt);
          else match.captures.push_back(TextRange{
              static_cast<TextOffset>(groupStart),
              static_cast<TextOffset>(groupEnd - groupStart)});
        }
        checkStatus(status);
        return match;
      }
      // ICU advances by a Unicode code point after an empty match.
      found = uregex_findNext(regex_.get(), &status);
    }
    checkStatus(status);
    return std::nullopt;
  }

 private:
  const TextBuffer& buffer_;
  const SakuraString& text_;
  SearchOptions options_;
  Regex regex_;
};

}  // namespace

bool SearchEngine::isValidPattern(SakuraStringView needle, SearchOptions options) {
  return !options.regularExpression || static_cast<bool>(compileRegex(needle, options));
}

SakuraString SearchEngine::expandReplacement(SakuraStringView source,
                                             const SearchMatch& match,
                                             SakuraStringView replacement,
                                             std::optional<std::size_t> outputLimit) {
  SakuraString result;
  const auto limit = std::min(outputLimit.value_or(result.max_size()), result.max_size());
  const auto appendCharacter = [&](SakuraChar value) {
    if (result.size() == limit) throw std::length_error("replacement output limit exceeded");
    result.push_back(value);
  };
  const auto appendRange = [&](TextRange range) {
    if (range.location > source.size() || range.length > source.size() - range.location) {
      throw std::out_of_range("capture range is outside the source");
    }
    if (range.length > limit - result.size()) {
      throw std::length_error("replacement output limit exceeded");
    }
    result.append(source.substr(range.location, range.length));
  };
  const auto appendCapture = [&](std::size_t index) {
    if (index == 0) appendRange(match.range);
    else if (match.captures.at(index)) appendRange(*match.captures[index]);
  };
  for (std::size_t cursor = 0; cursor < replacement.size(); ++cursor) {
    const auto value = replacement[cursor];
    if (value != u'$' || cursor + 1 == replacement.size()) {
      appendCharacter(value);
      continue;
    }
    const auto next = replacement[cursor + 1];
    if (next == u'$') { appendCharacter(u'$'); ++cursor; }
    else if (next == u'&') { appendCapture(0); ++cursor; }
    else if (next == u'`') { appendRange({0, match.range.location}); ++cursor; }
    else if (next == u'\'') {
      const auto end = match.range.location + match.range.length;
      if (end > source.size()) throw std::out_of_range("match is outside the source");
      appendRange({end, source.size() - end}); ++cursor;
    } else if (next >= u'0' && next <= u'9') {
      std::size_t group = next - u'0';
      std::size_t digits = 1;
      if (cursor + 2 < replacement.size() && replacement[cursor + 2] >= u'0' &&
          replacement[cursor + 2] <= u'9') {
        const auto twoDigit = group * 10 + replacement[cursor + 2] - u'0';
        if (twoDigit < match.captures.size()) { group = twoDigit; digits = 2; }
      }
      if (group == 0 || group < match.captures.size()) {
        appendCapture(group);
        cursor += digits;
      } else appendCharacter(u'$');
    } else appendCharacter(u'$');
  }
  return result;
}

std::optional<SearchMatch> SearchEngine::findNext(
    const TextBuffer& buffer, SakuraStringView needle, TextOffset start,
    SearchOptions options) const {
  if (needle.empty()) return std::nullopt;
  const SakuraString text = buffer.text();
  const std::size_t position = std::min<std::size_t>(start, text.size());
  if (options.regularExpression) {
    RegexSearch search(buffer, text, needle, options);
    if (const auto match = search.find(position, text.size())) return match;
    if (options.wrap && position != 0) return search.find(0, position);
  } else {
    if (const auto match = findLiteralInRange(buffer, text, needle, position,
                                             text.size(), options)) return match;
    if (options.wrap && position != 0) {
      return findLiteralInRange(buffer, text, needle, 0, position, options);
    }
  }
  return std::nullopt;
}

std::vector<SearchMatch> SearchEngine::findAll(const TextBuffer& buffer,
                                              SakuraStringView needle,
                                              SearchOptions options) const {
  std::vector<SearchMatch> matches;
  if (needle.empty()) return matches;
  const SakuraString text = buffer.text();
  const std::size_t length = text.size();
  // Compile once per document, not once per match.
  std::optional<RegexSearch> regex;
  if (options.regularExpression) regex.emplace(buffer, text, needle, options);
  std::size_t start = 0;
  while (start <= length) {
    const auto match = regex ? regex->find(start, length) :
        findLiteralInRange(buffer, text, needle, start, length, options);
    if (!match) break;
    matches.push_back(*match);
    if (options.maxMatches != 0 && matches.size() >= options.maxMatches) break;
    start = static_cast<std::size_t>(match->range.location + match->range.length);
    if (match->range.length == 0) {
      if (start == length) break;
      do { ++start; } while (start < length && !buffer.isEditBoundary(start));
    }
  }
  return matches;
}

}  // namespace sakura::core
