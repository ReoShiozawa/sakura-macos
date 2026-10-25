// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#include "sakura/core/syntax/CustomSyntax.h"
#include "sakura/core/search/SearchEngine.h"
#include "../search/BufferUText.h"
#include <algorithm>
#include <chrono>
#include <map>
#include <set>
#include <span>
#include <stdexcept>
#include <unicode/uchar.h>
#include <unicode/ustring.h>
#include <unicode/utf16.h>

namespace sakura::core {
namespace {
struct GroupView {
  std::span<const SakuraString> keywords, patterns;
  bool caseSensitive;
};
std::vector<GroupView> groupsOf(const CustomSyntaxRules& rules) {
  std::vector<GroupView> result{{rules.keywords, rules.patterns, rules.caseSensitive}};
  for (const auto& group : rules.additionalGroups) result.push_back({group.keywords, group.patterns, group.caseSensitive});
  return result;
}
bool word(UChar32 c) {
  auto type = u_charType(c);
  return u_hasBinaryProperty(c, UCHAR_ALPHABETIC) || u_isalnum(c) ||
      type == U_NON_SPACING_MARK || type == U_COMBINING_SPACING_MARK ||
      type == U_ENCLOSING_MARK || type == U_CONNECTOR_PUNCTUATION ||
      type == U_LETTER_NUMBER || type == U_OTHER_NUMBER || u_hasBinaryProperty(c, UCHAR_JOIN_CONTROL);
}
SakuraString fold(SakuraStringView text, bool sensitive) {
  if (sensitive) return SakuraString(text);
  UErrorCode status = U_ZERO_ERROR;
  auto size = u_strFoldCase(nullptr, 0, reinterpret_cast<const UChar*>(text.data()),
      static_cast<int32_t>(text.size()), U_FOLD_CASE_DEFAULT, &status);
  if (status != U_BUFFER_OVERFLOW_ERROR && U_FAILURE(status)) throw std::runtime_error("case folding failed");
  SakuraString result(static_cast<std::size_t>(size), u'\0'); status = U_ZERO_ERROR;
  u_strFoldCase(reinterpret_cast<UChar*>(result.data()), size,
      reinterpret_cast<const UChar*>(text.data()), static_cast<int32_t>(text.size()), U_FOLD_CASE_DEFAULT, &status);
  if (U_FAILURE(status)) throw std::runtime_error("case folding failed");
  return result;
}
}
std::optional<std::string> validateCustomSyntaxRules(const CustomSyntaxRules& rules) {
  if (rules.additionalGroups.size() > 9) return "maximum 10 keyword groups";
  std::size_t total = 0, wordCount = 0, patternCount = 0;
  for (const auto& group : groupsOf(rules)) {
    wordCount += group.keywords.size(); patternCount += group.patterns.size();
    if (wordCount > 2048 || patternCount > 8) return "maximum 2048 keywords / 8 patterns across all groups";
    for (const auto& keyword : group.keywords) {
      total += keyword.size();
      if (keyword.empty() || keyword.size() > 128 || total > 32768) return "keyword size limit exceeded";
      int32_t at = 0;
      while (at < static_cast<int32_t>(keyword.size())) {
        UChar32 c; U16_NEXT(reinterpret_cast<const UChar*>(keyword.data()), at, static_cast<int32_t>(keyword.size()), c);
        if (!word(c)) return "keywords must contain only Unicode word characters";
      }
    }
    for (std::size_t n = 0; n < group.patterns.size(); ++n) {
      const auto& pattern = group.patterns[n];
      if (pattern.empty() || pattern.size() > 512) return "pattern size limit exceeded";
      if (!SearchEngine::isValidPattern(pattern, {.caseSensitive=group.caseSensitive, .regularExpression=true}))
        return "invalid regular expression #" + std::to_string(n + 1);
    }
  }
  return std::nullopt;
}
CustomSyntaxResult highlightCustomSyntax(const TextBuffer& buffer, const std::vector<SyntaxToken>& base,
                                         const CustomSyntaxRules& rules, std::function<bool()> cancelled) {
  using Status = CustomSyntaxStatus;
  if (buffer.length() > kCustomSyntaxTextLimit || buffer.lineCount() > kCustomSyntaxLineLimit) return {{}, Status::tooLarge};
  if (cancelled && cancelled()) return {{}, Status::cancelled};
  if (validateCustomSyntaxRules(rules)) return {{}, Status::invalidRules};
  auto groups = groupsOf(rules);
  if (std::all_of(groups.begin(), groups.end(), [](const auto& g){return g.keywords.empty() && g.patterns.empty();})) return {};
  // Base tokens come from the lexical highlighter and must be ordered/nonoverlapping.
  TextOffset last = 0;
  for (const auto& token : base) {
    if (token.range.location < last || token.range.location > buffer.length() ||
        token.range.length > buffer.length() - token.range.location) return {{}, Status::invalidRules};
    last = token.range.location + token.range.length;
  }
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(200);
  bool expired = false, wasCancelled = false;
  auto stop = [&] {
    wasCancelled = cancelled && cancelled();
    expired = std::chrono::steady_clock::now() >= deadline;
    return wasCancelled || expired;
  };
  std::map<TextOffset, std::pair<TextOffset, std::uint8_t>> accepted;
  auto insert = [&](TextRange range, std::uint8_t group) {
    if (!range.length) return true;
    auto end = range.location + range.length;
    auto token = std::lower_bound(base.begin(), base.end(), range.location,
        [](const auto& value, auto offset) { return value.range.location + value.range.length <= offset; });
    if (token != base.end() && token->range.location < end) return true;
    auto next = accepted.lower_bound(range.location);
    if ((next != accepted.end() && next->first < end) ||
        (next != accepted.begin() && std::prev(next)->second.first > range.location)) return true;
    if (accepted.size() >= kCustomSyntaxMatchLimit) return false;
    accepted.emplace(range.location, std::make_pair(end, group));
    return true;
  };
  try {
    std::vector<std::set<SakuraString>> words(groups.size());
    bool hasWords = false;
    for (std::size_t group = 0; group < groups.size(); ++group)
      for (const auto& keyword : groups[group].keywords) {
        words[group].insert(fold(keyword, groups[group].caseSensitive)); hasWords = true;
      }
    if (hasWords) {
      detail::BufferUText reader(buffer,stop);
      auto* text = reader.get();
      const auto length = static_cast<std::int64_t>(buffer.length());
      while (utext_getNativeIndex(text) < length) {
        if (stop()) return {{}, wasCancelled ? Status::cancelled : Status::timedOut};
        const auto start = utext_getNativeIndex(text);
        auto c = utext_next32(text);
        reader.rethrowFailure();
        if (!word(c)) continue;
        auto at = utext_getNativeIndex(text);
        while (at < length) {
          c = utext_current32(text);
          reader.rethrowFailure();
          if (!word(c)) break;
          (void)utext_next32(text);
          reader.rethrowFailure();
          at = utext_getNativeIndex(text);
          if ((at - start) % 1024 == 0 && stop()) return {{}, wasCancelled ? Status::cancelled : Status::timedOut};
        }
        if (at - start <= 128) {
          const auto originalWord = buffer.slice({static_cast<TextOffset>(start),static_cast<TextOffset>(at-start)},stop);
          std::optional<SakuraString> foldedWord;
          for (std::size_t group = 0; group < groups.size(); ++group) {
            if (words[group].empty()) continue;
            if (!groups[group].caseSensitive && !foldedWord) foldedWord = fold(originalWord, false);
            const auto& candidate = groups[group].caseSensitive ? originalWord : *foldedWord;
            if (words[group].contains(candidate)) {
              if (!insert({static_cast<TextOffset>(start), static_cast<TextOffset>(at - start)}, static_cast<std::uint8_t>(group + 1))) return {{}, Status::tooManyMatches};
              break;
            }
          }
        }
      }
    }
    SearchEngine engine;
    for (std::size_t group = 0; group < groups.size(); ++group) for (const auto& pattern : groups[group].patterns) {
      SearchOptions options{.caseSensitive=groups[group].caseSensitive, .regularExpression=true};
      options.cancelled = stop;
      options.maxMatches = kCustomSyntaxMatchLimit + 1;
      options.regexTimeLimitMilliseconds = 50;
      options.captureGroups = false;
      auto matches = engine.findAll(buffer, pattern, options);
      if (matches.size() > kCustomSyntaxMatchLimit) return {{}, Status::tooManyMatches};
      for (auto match : matches) if (!insert(match.range, static_cast<std::uint8_t>(group + 1))) return {{}, Status::tooManyMatches};
    }
  } catch (const std::exception&) {
    return {{}, wasCancelled ? Status::cancelled : Status::timedOut};
  }
  if (stop()) return {{}, wasCancelled ? Status::cancelled : Status::timedOut};
  CustomSyntaxResult result;
  for (auto [begin, info] : accepted) result.tokens.push_back({{begin, info.first - begin}, SyntaxTokenKind::keyword, info.second});
  return result;
}
}  // namespace sakura::core
