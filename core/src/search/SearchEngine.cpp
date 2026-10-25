// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include "sakura/core/search/SearchEngine.h"
#include "BufferUText.h"

#include <algorithm>
#include <array>
#include <limits>
#include <memory>
#include <stdexcept>

#include <unicode/uregex.h>
#include <unicode/uchar.h>
#include <unicode/utf16.h>

namespace sakura::core {
namespace {

bool isUnicodeWord(UChar32 value) noexcept {
  const auto type = u_charType(value);
  return u_isalnum(value) || u_hasBinaryProperty(value, UCHAR_ALPHABETIC) ||
      type == U_NON_SPACING_MARK || type == U_COMBINING_SPACING_MARK ||
      type == U_ENCLOSING_MARK || type == U_CONNECTOR_PUNCTUATION ||
      type == U_LETTER_NUMBER || type == U_OTHER_NUMBER ||
      u_hasBinaryProperty(value, UCHAR_JOIN_CONTROL);
}

bool wholeWordMatches(const TextBuffer& text, std::size_t start,
                      std::size_t end, const SearchOptions& options) {
  if (!options.wholeWord) return true;
  UChar32 before = -1, after = -1;
  if (start) {
    before = text.characterAt(start-1);
    if (U16_IS_TRAIL(before) && start > 1) {
      const auto lead = text.characterAt(start-2);
      if (U16_IS_LEAD(lead)) before = U16_GET_SUPPLEMENTARY(lead, before);
    }
  }
  if (end < text.length()) {
    after = text.characterAt(end);
    if (U16_IS_LEAD(after) && end+1 < text.length()) {
      const auto trail = text.characterAt(end+1);
      if (U16_IS_TRAIL(trail)) after = U16_GET_SUPPLEMENTARY(after, trail);
    }
  }
  return !isUnicodeWord(before) && !isUnicodeWord(after);
}

void checkCancellation(const SearchOptions& options) {
  if (options.cancelled && options.cancelled()) {
    throw std::runtime_error("Search cancelled");
  }
}

TextRange searchRange(const TextBuffer& buffer, const SearchOptions& options) {
  auto range = options.range.value_or(TextRange{0, buffer.length()});
  if (range.location > buffer.length() || range.length > buffer.length() - range.location ||
      !buffer.isEditBoundary(range.location) || !buffer.isEditBoundary(range.location + range.length))
    throw std::out_of_range("invalid search region");
  return range;
}

class LiteralSearch {
 public:
  LiteralSearch(const TextBuffer& buffer, SakuraStringView needle, const SearchOptions& options)
      : buffer_(buffer), needle_(needle), options_(options) {
    if (needle.size() > options.range.value_or(TextRange{0,buffer.length()}).length) return;
    prefix_.resize(needle.size());
    for (std::size_t at=1, matched=0; at<needle.size(); ++at) {
      if (at%4096 == 0) checkCancellation(options_);
      while (matched && needle[at] != needle[matched]) matched = prefix_[matched-1];
      if (needle[at] == needle[matched]) ++matched;
      prefix_[at] = matched;
    }
  }
  std::optional<SearchMatch> find(std::size_t begin, std::size_t end) {
    checkCancellation(options_);
    if (needle_.size() > end-begin) return std::nullopt;
    std::size_t matched = 0;
    for (std::size_t at=begin; at<end; ++at) {
      if ((at-begin)%4096 == 0) checkCancellation(options_);
      if (at < chunkStart_ || at >= chunkEnd_) {
        chunkStart_ = at;
        chunkEnd_ = at + std::min<std::size_t>(units_.size(),end-at);
        buffer_.copyText({at,chunkEnd_-at},{units_.data(),chunkEnd_-at});
      }
      const auto value = units_[at-chunkStart_];
      while (matched && value != needle_[matched]) matched = prefix_[matched-1];
      if (value == needle_[matched]) ++matched;
      if (matched != needle_.size()) continue;
      const auto start = at+1-needle_.size(), limit = at+1;
      matched = prefix_[matched-1];
      if (buffer_.isEditBoundary(start) && buffer_.isEditBoundary(limit) &&
          wholeWordMatches(buffer_,start,limit,options_))
        return SearchMatch{{start,needle_.size()},{}};
    }
    return std::nullopt;
  }
 private:
  const TextBuffer& buffer_;
  SakuraStringView needle_;
  SearchOptions options_;
  std::vector<std::size_t> prefix_;
  std::array<SakuraChar,8192> units_{};
  std::size_t chunkStart_{}, chunkEnd_{};
};

using Regex = std::unique_ptr<URegularExpression, decltype(&uregex_close)>;

Regex compileRegex(SakuraStringView pattern, const SearchOptions& options) {
  if (pattern.size() > static_cast<std::size_t>(INT32_MAX)) {
    return {nullptr, uregex_close};
  }
  static_assert(sizeof(UChar) == sizeof(SakuraChar));
  UErrorCode status = U_ZERO_ERROR;
  const std::uint32_t flags = (options.caseSensitive ? 0 : UREGEX_CASE_INSENSITIVE) |
      (options.regularExpression ? (options.regexMultiline ? UREGEX_MULTILINE : 0) : UREGEX_LITERAL);
  Regex regex(uregex_open(reinterpret_cast<const UChar*>(pattern.data()),
                         static_cast<std::int32_t>(pattern.size()), flags,
                         nullptr, &status), uregex_close);
  if (U_FAILURE(status)) regex.reset();
  return regex;
}

void checkStatus(UErrorCode status) {
  if (U_FAILURE(status)) {
    // Never silently apply only part of a replacement after a search error.
    throw std::runtime_error(std::string("Unicode regular expression search failed: ") + u_errorName(status));
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
  RegexSearch(const TextBuffer& buffer,
              SakuraStringView pattern, SearchOptions options)
      : buffer_(buffer), text_(buffer, options.cancelled), options_(options),
        regex_(compileRegex(pattern, options)) {
    if (!regex_) return;
    if (buffer.length() > static_cast<std::size_t>(INT32_MAX)) {
      throw std::length_error("regular expression text exceeds ICU UTF-16 limit");
    }
    UErrorCode status = U_ZERO_ERROR;
    uregex_setUText(regex_.get(), text_.get(), &status);
    uregex_setTimeLimit(regex_.get(), std::max<std::int32_t>(1,
        options_.regexTimeLimitMilliseconds), &status);
    uregex_setMatchCallback(regex_.get(), regexMatchProgress, &options_, &status);
    uregex_setFindProgressCallback(regex_.get(), regexFindProgress, &options_, &status);
    text_.rethrowFailure();
    checkStatus(status);
  }

  // ICU callbacks retain &options_; moving the matcher would invalidate it.
  RegexSearch(const RegexSearch&) = delete;
  RegexSearch& operator=(const RegexSearch&) = delete;
  RegexSearch(RegexSearch&&) = delete;
  RegexSearch& operator=(RegexSearch&&) = delete;

  std::optional<SearchMatch> find(std::size_t begin, std::size_t end) {
    checkCancellation(options_);
    if (!regex_) return std::nullopt;
    UErrorCode status = U_ZERO_ERROR;
    const auto region = searchRange(buffer_, options_);
    // setRegionAndStart does not reset the region (find(start) would). Retain
    // full-source lookaround and real anchors, while greedy matches stop at the
    // selected boundary. See ICU uregex_setRegionAndStart / transparent bounds.
    uregex_useTransparentBounds(regex_.get(), true, &status);
    uregex_useAnchoringBounds(regex_.get(), false, &status);
    uregex_setRegionAndStart(regex_.get(), region.location, region.location + region.length, begin, &status);
    UBool found = uregex_findNext(regex_.get(), &status);
    text_.rethrowFailure();
    while (found && U_SUCCESS(status)) {
      const auto start = uregex_start(regex_.get(), 0, &status);
      const auto limit = uregex_end(regex_.get(), 0, &status);
      checkStatus(status);
      if (static_cast<std::size_t>(limit) > end) return std::nullopt;
      if (buffer_.isEditBoundary(start) && buffer_.isEditBoundary(limit) &&
          wholeWordMatches(buffer_, start, limit, options_)) {
        SearchMatch match{{static_cast<TextOffset>(start),
                            static_cast<TextOffset>(limit - start)}, {}};
        if (options_.regularExpression && options_.captureGroups) captureCurrentMatch(match);
        return match;
      }
      // ICU advances by a Unicode code point after an empty match.
      found = uregex_findNext(regex_.get(), &status);
      text_.rethrowFailure();
    }
    checkStatus(status);
    return std::nullopt;
  }

  void captureCurrentMatch(SearchMatch& match, bool cumulative = true) {
    UErrorCode status = U_ZERO_ERROR;
    const auto count = uregex_groupCount(regex_.get(), &status);
    checkStatus(status);
    const auto slots = static_cast<std::size_t>(count) + 1;
    if (slots > options_.maxCaptureSlots - (cumulative ? captureSlots_ : 0))
      throw std::length_error("capture budget exceeded");
    if (cumulative) captureSlots_ += slots;
    match.captures.reserve(slots);
    for (std::int32_t group = 0; group <= count; ++group) {
      const auto begin = uregex_start(regex_.get(), group, &status);
      const auto end = uregex_end(regex_.get(), group, &status);
      if (begin < 0) match.captures.push_back(std::nullopt);
      else match.captures.push_back(TextRange{static_cast<TextOffset>(begin),static_cast<TextOffset>(end-begin)});
    }
    checkStatus(status);
  }

 private:
  const TextBuffer& buffer_;
  detail::BufferUText text_;
  SearchOptions options_;
  Regex regex_;
  std::size_t captureSlots_{};
};

}  // namespace

bool SearchEngine::isValidPattern(SakuraStringView needle, SearchOptions options) {
  return !options.regularExpression || static_cast<bool>(compileRegex(needle, options));
}

namespace {
template<class CopyRange>
SakuraString expandReplacementFromSource(TextOffset sourceSize,
                                             const SearchMatch& match,
                                             SakuraStringView replacement,
                                             std::optional<std::size_t> outputLimit,
                                             const std::function<bool()>& cancelled,
                                             CopyRange copyRange) {
  SakuraString result;
  const auto limit = std::min(outputLimit.value_or(result.max_size()), result.max_size());
  const auto appendCharacter = [&](SakuraChar value) {
    if (result.size() == limit) throw std::length_error("replacement output limit exceeded");
    result.push_back(value);
  };
  const auto appendRange = [&](TextRange range) {
    if (range.location > sourceSize || range.length > sourceSize - range.location) {
      throw std::out_of_range("capture range is outside the source");
    }
    if (range.length > limit - result.size()) {
      throw std::length_error("replacement output limit exceeded");
    }
    for (TextOffset offset = 0; offset < range.length; offset += 65536) {
      if (cancelled && cancelled()) throw std::runtime_error("replacement expansion cancelled");
      copyRange(result, TextRange{range.location + offset,
                                 std::min<TextOffset>(65536, range.length - offset)});
    }
  };
  const auto appendCapture = [&](std::size_t index) {
    if (index == 0) appendRange(match.range);
    else if (match.captures.at(index)) appendRange(*match.captures[index]);
  };
  for (std::size_t cursor = 0; cursor < replacement.size(); ++cursor) {
    if (cursor % 4096 == 0 && cancelled && cancelled()) throw std::runtime_error("replacement expansion cancelled");
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
      if (match.range.location > sourceSize || match.range.length > sourceSize - match.range.location)
        throw std::out_of_range("match is outside the source");
      const auto end = match.range.location + match.range.length;
      appendRange({end, sourceSize - end}); ++cursor;
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
} // namespace

SakuraString SearchEngine::expandReplacement(SakuraStringView source,
    const SearchMatch& match, SakuraStringView replacement,
    std::optional<std::size_t> outputLimit, const std::function<bool()>& cancelled) {
  return expandReplacementFromSource(source.size(),match,replacement,outputLimit,cancelled,
      [&](SakuraString& result, TextRange range) {
        result.append(source.substr(static_cast<std::size_t>(range.location),
                                    static_cast<std::size_t>(range.length)));
      });
}

SakuraString SearchEngine::expandReplacement(const TextBuffer& source,
    const SearchMatch& match, SakuraStringView replacement,
    std::optional<std::size_t> outputLimit, const std::function<bool()>& cancelled) {
  return expandReplacementFromSource(source.length(),match,replacement,outputLimit,cancelled,
      [&](SakuraString& result, TextRange range) {
        const auto previousSize = result.size();
        const auto count = static_cast<std::size_t>(range.length);
        result.resize(previousSize + count);
        source.copyText(range,{result.data()+previousSize,count});
      });
}

std::optional<SearchMatch> SearchEngine::findNext(
    const TextBuffer& buffer, SakuraStringView needle, TextOffset start,
    SearchOptions options) const {
  const auto region = searchRange(buffer, options);
  if (needle.empty()) return std::nullopt;
  checkCancellation(options);
  const auto lower = static_cast<std::size_t>(region.location);
  const auto upper = static_cast<std::size_t>(region.location + region.length);
  const std::size_t position = std::clamp<std::size_t>(start, lower, upper);
  if (options.regularExpression || !options.caseSensitive) {
    RegexSearch search(buffer, needle, options);
    if (const auto match = search.find(position, upper)) return match;
    if (options.wrap && position != lower) return search.find(lower, position);
  } else {
    LiteralSearch search(buffer, needle, options);
    if (const auto match = search.find(position, upper)) return match;
    if (options.wrap && position != lower) {
      return search.find(lower, position);
    }
  }
  return std::nullopt;
}

std::optional<SearchMatch> SearchEngine::findPrevious(const TextBuffer& buffer,
    SakuraStringView needle, TextOffset cursor, SearchOptions options) const {
  const auto region = searchRange(buffer, options);
  if (needle.empty()) return std::nullopt;
  checkCancellation(options);
  const auto upper = static_cast<std::size_t>(region.location + region.length);
  auto scanOptions = options; scanOptions.captureGroups = false;
  std::optional<RegexSearch> regex;
  std::optional<LiteralSearch> literal;
  if (options.regularExpression || !options.caseSensitive) regex.emplace(buffer, needle, scanOptions);
  else literal.emplace(buffer,needle,scanOptions);
  std::optional<SearchMatch> candidate;
  bool precedes = false;
  std::size_t start = region.location;
  while (start <= upper) {
    auto match = regex ? regex->find(start, upper) : literal->find(start, upper);
    if (!match) break;
    if (match->range.location >= cursor && (precedes || !options.wrap)) break;
    // Capture the exact active matcher state, not a new match started at this
    // candidate: restarting could change alternatives involving ICU's \G.
    // Only the retained candidate is budgeted; earlier arrays are discarded.
    if (options.regularExpression && options.captureGroups) regex->captureCurrentMatch(*match,false);
    if (match->range.location < cursor) {
      candidate = std::move(match); precedes = true;
    } else {
      candidate = std::move(match);
    }
    start = candidate->range.location + candidate->range.length;
    if (!candidate->range.length) {
      if (start == upper) break;
      do { ++start; } while (start < upper && !buffer.isEditBoundary(start));
    }
  }
  return candidate;
}

std::vector<SearchMatch> SearchEngine::findAll(const TextBuffer& buffer,
                                              SakuraStringView needle,
                                              SearchOptions options) const {
  std::vector<SearchMatch> matches;
  const auto region = searchRange(buffer, options);
  if (needle.empty()) return matches;
  checkCancellation(options);
  const std::size_t length = region.location + region.length;
  // Compile once per document, not once per match.
  std::optional<RegexSearch> regex;
  std::optional<LiteralSearch> literal;
  if (options.regularExpression || !options.caseSensitive) regex.emplace(buffer, needle, options);
  else literal.emplace(buffer,needle,options);
  std::size_t start = region.location;
  while (start <= length) {
    const auto match = regex ? regex->find(start, length) :
        literal->find(start, length);
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
