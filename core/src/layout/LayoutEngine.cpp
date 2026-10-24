// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include "sakura/core/layout/LayoutEngine.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <memory>
#include <stdexcept>

#include <unicode/uregex.h>

namespace sakura::core {
namespace {

float nonNegative(float value) noexcept {
  return std::max(0.0F, value);
}

using GraphemeMatcher =
    std::unique_ptr<URegularExpression, decltype(&uregex_close)>;

// ICU's \X consumes one extended grapheme. Its C regex API is part of the
// macOS SDK, unlike ubrk.h, so this uses the same system ICU as core search
// without introducing a separate set of ICU headers or libraries. Compile
// only on encountering non-ASCII text, then reuse the matcher across lines.
void bindGraphemeMatcher(GraphemeMatcher& matcher, SakuraStringView text) {
  if (text.size() > static_cast<std::size_t>(
                        std::numeric_limits<std::int32_t>::max())) {
    throw std::length_error("Unicode layout line exceeds ICU UTF-16 limit");
  }
  UErrorCode status = U_ZERO_ERROR;
  static_assert(sizeof(UChar) == sizeof(SakuraChar));
  if (!matcher) {
    constexpr SakuraStringView pattern = u"\\X";
    matcher.reset(uregex_open(reinterpret_cast<const UChar*>(pattern.data()),
                              static_cast<std::int32_t>(pattern.size()),
                              UREGEX_ERROR_ON_UNKNOWN_ESCAPES, nullptr, &status));
    if (U_FAILURE(status) || !matcher) {
      throw std::runtime_error("Unicode grapheme matcher could not be created");
    }
  }
  // Retain the complete logical line, rather than a substring/region, to
  // keep surrounding grapheme context available to ICU.
  uregex_setText(matcher.get(), reinterpret_cast<const UChar*>(text.data()),
                 static_cast<std::int32_t>(text.size()), &status);
  if (U_FAILURE(status)) {
    throw std::runtime_error("Unicode grapheme text could not be set");
  }
}

std::int32_t nextGraphemeEnd(GraphemeMatcher& matcher, std::int32_t start) {
  UErrorCode status = U_ZERO_ERROR;
  const bool matched = uregex_lookingAt(matcher.get(), start, &status);
  const auto end = matched ? uregex_end(matcher.get(), 0, &status) : start;
  if (U_FAILURE(status) || !matched || end <= start) {
    throw std::runtime_error("Unicode grapheme matcher did not advance");
  }
  return end;
}

}  // namespace

float ITextMetrics::advanceCluster(SakuraStringView cluster,
                                   const FontStyle& style) const {
  float width = 0.0F;
  for (const auto character : cluster) {
    width += nonNegative(advance(character, style));
  }
  return width;
}

std::size_t LayoutResult::visualLineFor(TextPosition position) const {
  // Lines are ordered by logical line and fragment end. lower_bound retains
  // the existing preceding-line affinity at an exact soft-wrap boundary.
  const auto found = std::lower_bound(
      visualLines.begin(), visualLines.end(), position,
      [](const VisualLine& visual, TextPosition target) {
        return visual.logicalLine < target.line ||
               (visual.logicalLine == target.line &&
                visual.endColumn < target.column);
      });
  if (found != visualLines.end() && found->logicalLine == position.line &&
      found->startColumn <= position.column &&
      position.column <= found->endColumn) {
    return static_cast<std::size_t>(found - visualLines.begin());
  }
  throw std::out_of_range("text position is not present in the layout");
}

LayoutResult LayoutEngine::layout(const TextBuffer& buffer,
                                  const ITextMetrics& metrics,
                                  const FontStyle& style,
                                  const LayoutOptions& options) const {
  LayoutResult result;
  // Every logical line contributes at least one visual line. Reserving that
  // lower bound avoids repeated copies of millions of line descriptors.
  result.visualLines.reserve(buffer.lineCount());
  result.lineHeight = nonNegative(metrics.lineHeight(style));
  const auto configuredTabWidth = std::max<TextOffset>(1, options.tabWidth);
  const float spaceAdvance = nonNegative(metrics.advance(u' ', style));
  const float tabStop = spaceAdvance * static_cast<float>(configuredTabWidth);
  GraphemeMatcher graphemes(nullptr, uregex_close);

  for (std::size_t lineIndex = 0; lineIndex < buffer.lineCount(); ++lineIndex) {
    const auto& logical = buffer.line(lineIndex).content;
    if (logical.empty()) {
      result.visualLines.push_back({lineIndex, 0, 0, 0.0F, result.lineHeight});
      continue;
    }

    TextOffset fragmentStart = 0;
    TextOffset column = 0;
    float fragmentWidth = 0.0F;
    bool graphemesBound = false;
    const auto* characters = logical.data();
    const auto length = logical.size();

    while (column < length) {
      const auto index = static_cast<std::size_t>(column);
      const auto character = characters[index];
      TextOffset characterLength = 1;
      float characterWidth = 0.0F;

      if (character == u'\t') {
        characterWidth = tabStop > 0.0F
                             ? tabStop - std::fmod(fragmentWidth, tabStop)
                             : 0.0F;
      } else if (character >= u'\x80' ||
                 (index + 1 < length && characters[index + 1] >= u'\x80')) {
        // Looking ahead is necessary even at an ASCII base: "e" followed by
        // a combining accent must not wrap between the two. Ordinary ASCII
        // text avoids both ICU allocation and cluster shaping entirely.
        if (!graphemesBound) {
          bindGraphemeMatcher(graphemes, logical);
          graphemesBound = true;
        }
        // column is already a boundary (including ASCII skipped by the fast
        // path); matching at that exact position cannot regroup a prior flag
        // or split a preceding base/combining sequence.
        const auto end = nextGraphemeEnd(graphemes,
                                         static_cast<std::int32_t>(index));
        characterLength = static_cast<TextOffset>(end) - column;
        characterWidth = nonNegative(metrics.advanceCluster(
            SakuraStringView(logical).substr(index,
                                            static_cast<std::size_t>(characterLength)),
            style));
      } else {
        characterWidth = nonNegative(metrics.advance(character, style));
      }

      if (options.wrapWidth > 0.0F && fragmentWidth > 0.0F &&
          fragmentWidth + characterWidth > options.wrapWidth) {
        result.visualLines.push_back(
            {lineIndex, fragmentStart, column, fragmentWidth, result.lineHeight});
        fragmentStart = column;
        fragmentWidth = 0.0F;
        // Tab stops restart at each display line, as in the Win32 layout
        // engine. A tab that triggered wrapping must be measured again from
        // the new origin, not retain its width from the preceding fragment.
        if (character == u'\t') characterWidth = tabStop;
      }

      fragmentWidth += characterWidth;
      column += characterLength;
    }

    result.visualLines.push_back(
        {lineIndex, fragmentStart, column, fragmentWidth, result.lineHeight});
  }

  return result;
}

}  // namespace sakura::core
