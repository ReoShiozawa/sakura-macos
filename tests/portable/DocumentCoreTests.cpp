// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include <cstddef>
#include <algorithm>
#include <iostream>
#include <random>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <type_traits>
#include <utility>
#include <vector>

#include "sakura/app/CommandBus.h"
#include "sakura/app/DocumentSession.h"
#include "sakura/core/encoding/EncodingService.h"
#include "sakura/core/encoding/Utf16Codec.h"
#include "sakura/core/encoding/Utf8Codec.h"
#include "sakura/core/layout/LayoutEngine.h"
#include "sakura/core/search/SearchEngine.h"
#include "sakura/core/syntax/SyntaxHighlighter.h"

namespace {

using sakura::app::DocumentSession;
using sakura::app::CommandArgs;
using sakura::app::CommandBus;
using sakura::app::CommandContext;
using sakura::app::CommandResult;
using sakura::app::ICommandHandler;
using sakura::core::BomPolicy;
using sakura::core::CodecOffsetUnit;
using sakura::core::EncodingService;
using sakura::core::EncodingState;
using sakura::core::LineEnding;
using sakura::core::FontStyle;
using sakura::core::ITextMetrics;
using sakura::core::LayoutEngine;
using sakura::core::LayoutOptions;
using sakura::core::SakuraString;
using sakura::core::SearchEngine;
using sakura::core::SearchOptions;
using sakura::core::SyntaxHighlighter;
using sakura::core::SyntaxTokenKind;
using sakura::core::TextBuffer;
using sakura::core::TextPosition;
using sakura::core::TextRange;
using sakura::core::TextEncoding;
using sakura::core::Utf8Codec;
using sakura::core::Utf16ByteOrder;
using sakura::core::Utf16Codec;

int failures = 0;

void fail(std::string_view test, std::string_view expression, int line) {
  std::cerr << test << ':' << line << ": expectation failed: " << expression << '\n';
  ++failures;
}

#define EXPECT(test, expression) \
  do {                            \
    if (!(expression)) {          \
      fail(test, #expression, __LINE__); \
    }                             \
  } while (false)

std::vector<std::byte> bytes(std::initializer_list<unsigned int> values) {
  std::vector<std::byte> result;
  for (const auto value : values) {
    result.push_back(static_cast<std::byte>(value));
  }
  return result;
}

class MonospaceMetrics final : public ITextMetrics {
 public:
  [[nodiscard]] float advance(sakura::core::SakuraChar,
                              const FontStyle&) const override {
    return 1.0F;
  }

  [[nodiscard]] float lineHeight(const FontStyle&) const override {
    return 2.0F;
  }
};

// Models a platform shaper that measures one grapheme as one cell, rather
// than the fallback adapter's one cell per UTF-16 code unit.
class GraphemeMetrics final : public ITextMetrics {
 public:
  mutable std::size_t clusterCalls{};
  mutable std::size_t largestCluster{};

  [[nodiscard]] float advance(sakura::core::SakuraChar,
                              const FontStyle&) const override {
    return 1.0F;
  }

  [[nodiscard]] float advanceCluster(sakura::core::SakuraStringView cluster,
                                     const FontStyle&) const override {
    ++clusterCalls;
    largestCluster = std::max(largestCluster, cluster.size());
    return 1.0F;
  }

  [[nodiscard]] float lineHeight(const FontStyle&) const override {
    return 2.0F;
  }
};

void textBufferPreservesMixedEndings() {
  constexpr std::string_view test = "textBufferPreservesMixedEndings";
  const SakuraString source = u"first\r\n二行目\nthird\rlast😀\r\n";
  TextBuffer buffer(source);

  EXPECT(test, buffer.text() == source);
  EXPECT(test, buffer.lineCount() == 5);
  EXPECT(test, buffer.line(0).ending == LineEnding::carriageReturnLineFeed);
  EXPECT(test, buffer.line(1).ending == LineEnding::lineFeed);
  EXPECT(test, buffer.line(2).ending == LineEnding::carriageReturn);
  EXPECT(test, buffer.line(3).ending == LineEnding::carriageReturnLineFeed);
  EXPECT(test, buffer.line(4).ending == LineEnding::none);
}

void textBufferMapsUtf16Offsets() {
  constexpr std::string_view test = "textBufferMapsUtf16Offsets";
  TextBuffer buffer(u"A😀B\r\n次");

  EXPECT(test, buffer.line(0).content.size() == 4);
  EXPECT(test, buffer.offsetAt(TextPosition{0, 3}) == 3);
  EXPECT(test, buffer.positionAt(5) == (TextPosition{0, 4}));
  EXPECT(test, buffer.positionAt(6) == (TextPosition{1, 0}));
  EXPECT(test, buffer.offsetAt(TextPosition{1, 1}) == 7);
  EXPECT(test, !buffer.isCodePointBoundary(2));
  EXPECT(test, buffer.isCodePointBoundary(3));
}

void textBufferProtectsAliasingAndCrLf() {
  constexpr std::string_view test = "textBufferProtectsAliasingAndCrLf";
  TextBuffer buffer(u"aliased content");
  const auto expected = buffer.line(0).content;
  buffer.assign(buffer.line(0).content);
  EXPECT(test, buffer.text() == expected);

  buffer.assign(u"a\r\nb");
  EXPECT(test, !buffer.isEditBoundary(2));
  bool threw = false;
  try {
    buffer.replace(TextRange{2, 0}, u"x");
  } catch (const std::invalid_argument&) {
    threw = true;
  }
  EXPECT(test, threw);
  EXPECT(test, buffer.text() == u"a\r\nb");
}

void incrementalReplaceMatchesSerializedText() {
  constexpr std::string_view test = "incrementalReplaceMatchesSerializedText";
  const SakuraString source = u"aa\r\nbb\ncc\rdd😀";
  const std::vector<SakuraString> replacements{u"", u"X", u"\n", u"R\r\nS", u"🌸"};
  const TextBuffer boundaries(source);

  for (sakura::core::TextOffset start = 0; start <= boundaries.length(); ++start) {
    if (!boundaries.isEditBoundary(start)) {
      continue;
    }
    for (sakura::core::TextOffset end = start; end <= boundaries.length(); ++end) {
      if (!boundaries.isEditBoundary(end)) {
        continue;
      }
      for (const auto& replacement : replacements) {
        TextBuffer actual(source);
        actual.replace(TextRange{start, end - start}, replacement);
        auto expected = source;
        expected.replace(static_cast<std::size_t>(start),
                         static_cast<std::size_t>(end - start), replacement);
        EXPECT(test, actual.text() == expected);
        EXPECT(test, actual.length() == expected.size());
        const TextBuffer reparsed(expected);
        EXPECT(test, actual.lineCount() == reparsed.lineCount());
        for (std::size_t line = 0; line < actual.lineCount() &&
                                   line < reparsed.lineCount(); ++line) {
          EXPECT(test, actual.line(line).content == reparsed.line(line).content);
          EXPECT(test, actual.line(line).ending == reparsed.line(line).ending);
          EXPECT(test, actual.lineStartOffset(line) == reparsed.lineStartOffset(line));
        }
      }
    }
  }
}

bool naiveEditBoundary(const SakuraString& text, std::size_t offset) {
  if (offset > text.size()) return false;
  if (offset == 0 || offset == text.size()) return true;
  const auto left = text[offset - 1];
  const auto right = text[offset];
  return !(left == u'\r' && right == u'\n') &&
      !(left >= u'\xD800' && left <= u'\xDBFF' &&
        right >= u'\xDC00' && right <= u'\xDFFF');
}

// This oracle parses the serialized UTF-16 independently of TextBuffer's
// incremental edit and prefix-index implementations.
void expectBufferMatchesNaive(std::string_view test, const TextBuffer& actual,
                              const SakuraString& expected) {
  struct ExpectedLine {
    std::size_t start;
    SakuraString content;
    LineEnding ending;
  };
  std::vector<ExpectedLine> lines;
  std::size_t cursor = 0;
  for (;;) {
    const auto start = cursor;
    while (cursor < expected.size() && expected[cursor] != u'\r' &&
           expected[cursor] != u'\n') ++cursor;
    const auto content = expected.substr(start, cursor - start);
    auto ending = LineEnding::none;
    if (cursor < expected.size()) {
      if (expected[cursor] == u'\r' && cursor + 1 < expected.size() &&
          expected[cursor + 1] == u'\n') {
        ending = LineEnding::carriageReturnLineFeed;
        cursor += 2;
      } else {
        ending = expected[cursor++] == u'\r'
            ? LineEnding::carriageReturn : LineEnding::lineFeed;
      }
    }
    lines.push_back({start, content, ending});
    if (ending == LineEnding::none) break;
  }
  EXPECT(test, actual.text() == expected);
  EXPECT(test, actual.length() == expected.size());
  EXPECT(test, actual.lineCount() == lines.size());
  for (std::size_t line = 0; line < lines.size() && line < actual.lineCount(); ++line) {
    EXPECT(test, actual.lineStartOffset(line) == lines[line].start);
    EXPECT(test, actual.line(line).content == lines[line].content);
    EXPECT(test, actual.line(line).ending == lines[line].ending);
    for (std::size_t column = 0; column <= lines[line].content.size(); ++column) {
      EXPECT(test, actual.offsetAt({line, column}) == lines[line].start + column);
    }
  }
  std::size_t line = 0;
  for (std::size_t offset = 0; offset <= expected.size(); ++offset) {
    while (line + 1 < lines.size() && lines[line + 1].start <= offset) ++line;
    const auto column = std::min(offset - lines[line].start,
                                 lines[line].content.size());
    EXPECT(test, actual.positionAt(offset) == (TextPosition{line, column}));
    EXPECT(test, actual.isEditBoundary(offset) == naiveEditBoundary(expected, offset));
    const auto count = std::min<std::size_t>(3, expected.size() - offset);
    EXPECT(test, actual.slice({offset, count}) == expected.substr(offset, count));
  }
}

void textBufferRandomizedEditsKeepPrefixIndexConsistent() {
  constexpr std::string_view test = "textBufferRandomizedEditsKeepPrefixIndexConsistent";
  const std::vector<SakuraString> replacements{
      u"", u"X", u"abc", u"\r", u"\n", u"\r\n", u"\n\r", u"\rX\n",
      u"桜", u"😀", u"\xD800", u"\xDC00"};
  std::mt19937_64 random(0x53414B555241);
  SakuraString expected = u"a\rX\nb\r\n😀\nlast";
  TextBuffer actual(expected);
  for (std::size_t iteration = 0; iteration < 2500; ++iteration) {
    std::vector<std::size_t> boundaries;
    for (std::size_t offset = 0; offset <= expected.size(); ++offset) {
      if (naiveEditBoundary(expected, offset)) boundaries.push_back(offset);
    }
    auto first = static_cast<std::size_t>(random() % boundaries.size());
    auto last = iteration % 3 == 0
        ? static_cast<std::size_t>(random() % boundaries.size())
        : std::min(first + static_cast<std::size_t>(random() % 3), boundaries.size() - 1);
    if (first > last) std::swap(first, last);
    const auto start = boundaries[first];
    const auto count = boundaries[last] - start;
    const auto revision = actual.revision();
    SakuraString replacement = replacements[random() % replacements.size()];
    if (iteration % 17 == 0) {
      const auto& aliased = actual.line(random() % actual.lineCount()).content;
      const auto begin = static_cast<std::size_t>(random() % (aliased.size() + 1));
      const auto view = sakura::core::SakuraStringView(aliased).substr(begin);
      replacement = view;
      actual.replace({start, count}, view);
    } else actual.replace({start, count}, replacement);
    expected.replace(start, count, replacement);
    EXPECT(test, actual.revision() == revision + 1);
    expectBufferMatchesNaive(test, actual, expected);
  }
}

void ordinaryLineEditsKeepOtherLineStorageStable() {
  constexpr std::string_view test = "ordinaryLineEditsKeepOtherLineStorageStable";
  SakuraString expected;
  for (std::size_t line = 0; line < 4096; ++line) expected.append(u"abcd\r\n");
  TextBuffer buffer(expected);
  const auto* firstLine = &buffer.line(0);
  const auto* lastLine = &buffer.line(buffer.lineCount() - 1);
  const auto lastOffset = buffer.lineStartOffset(buffer.lineCount() - 1);
  for (std::size_t iteration = 0; iteration < 100; ++iteration) {
    buffer.replace({7, 1}, u"xy");
    EXPECT(test, &buffer.line(0) == firstLine);
    EXPECT(test, &buffer.line(buffer.lineCount() - 1) == lastLine);
    EXPECT(test, buffer.lineStartOffset(buffer.lineCount() - 1) == lastOffset + 1);
    EXPECT(test, buffer.positionAt(lastOffset + 1) ==
                     (TextPosition{buffer.lineCount() - 1, 0}));
    buffer.replace({7, 2}, u"b");
    EXPECT(test, buffer.lineStartOffset(buffer.lineCount() - 1) == lastOffset);
  }
  EXPECT(test, buffer.text() == expected);
}

void textBufferCopiesMovesAndFailuresKeepIndexConsistent() {
  constexpr std::string_view test = "textBufferCopiesMovesAndFailuresKeepIndexConsistent";
  const SakuraString source = u"a😀\r\nnext\rlast\n";
  TextBuffer original(source);
  TextBuffer copied(original);
  TextBuffer assigned;
  assigned = original;
  TextBuffer moved(std::move(copied));
  TextBuffer moveAssigned;
  moveAssigned = std::move(assigned);
  for (const auto* buffer : {&original, &moved, &moveAssigned}) {
    expectBufferMatchesNaive(test, *buffer, source);
  }
  original.replace({0, 1}, u"XYZ");
  expectBufferMatchesNaive(test, moved, source);
  expectBufferMatchesNaive(test, moveAssigned, source);
  copied.assign(u"moved-from is reusable\n");
  expectBufferMatchesNaive(test, copied, u"moved-from is reusable\n");
  const auto preserved = original.text();
  const auto revision = original.revision();
  for (const TextRange range : {TextRange{original.length() + 1, 0},
                               TextRange{0, original.length() + 1},
                               TextRange{4, 0}, TextRange{6, 0}}) {
    bool rejected = false;
    try { original.replace(range, u"bad"); }
    catch (const std::out_of_range&) { rejected = true; }
    catch (const std::invalid_argument&) { rejected = true; }
    EXPECT(test, rejected);
    EXPECT(test, original.revision() == revision);
    expectBufferMatchesNaive(test, original, preserved);
  }
  original.assign(original.line(1).content);
  expectBufferMatchesNaive(test, original, u"next");
}

void undoRedoHandlesNewCrLfBoundaries() {
  constexpr std::string_view test = "undoRedoHandlesNewCrLfBoundaries";
  struct Case { SakuraString before; TextRange range; SakuraString replacement; };
  const std::vector<Case> cases{
      {u"a\rb", {2, 0}, u"\n"},
      {u"a\nb", {1, 0}, u"\r"},
      {u"a\rX\nb", {2, 1}, u""},
      {u"\rX\n", {1, 1}, u""},
      {u"x\r\ny", {1, 2}, u"\n"},
      {u"x\r\ny", {1, 2}, u"\r"},
      {u"a\xD800" u"b", {2, 0}, u"\xDC00"},
      {u"a\xDC00" u"b", {1, 0}, u"\xD800"},
      {u"\xD800X\xDC00", {1, 1}, u""},
  };
  for (const auto& item : cases) {
    TextBuffer buffer(item.before);
    sakura::core::EditEngine editor(buffer);
    auto after = item.before;
    after.replace(static_cast<std::size_t>(item.range.location),
                  static_cast<std::size_t>(item.range.length), item.replacement);
    editor.replace(item.range, item.replacement);
    expectBufferMatchesNaive(test, buffer, after);
    EXPECT(test, editor.undo());
    expectBufferMatchesNaive(test, buffer, item.before);
    EXPECT(test, editor.redo());
    expectBufferMatchesNaive(test, buffer, after);
  }
}

void failedBatchEditPreservesTextHistoryAndRevision() {
  constexpr std::string_view test = "failedBatchEditPreservesTextHistoryAndRevision";
  TextBuffer buffer(u"a\r\nb");
  sakura::core::EditEngine editor(buffer);
  editor.replace({0, 1}, u"A");
  const auto firstChangedState = editor.stateId();
  EXPECT(test, editor.undo());
  const auto beforeRevision = buffer.revision();
  const auto beforeState = editor.stateId();
  for (const TextRange invalid : {TextRange{100, 0}, TextRange{2, 0}}) {
    bool rejected = false;
    try {
      editor.replaceMany({{{0, 1}, u"X"}, {invalid, u"bad"}});
    } catch (const std::out_of_range&) { rejected = true; }
      catch (const std::invalid_argument&) { rejected = true; }
    EXPECT(test, rejected);
    expectBufferMatchesNaive(test, buffer, u"a\r\nb");
    EXPECT(test, buffer.revision() == beforeRevision);
    EXPECT(test, editor.stateId() == beforeState);
    EXPECT(test, !editor.canUndo());
    EXPECT(test, editor.canRedo());
  }
  EXPECT(test, editor.redo());
  EXPECT(test, editor.stateId() == firstChangedState);
  expectBufferMatchesNaive(test, buffer, u"A\r\nb");
  editor.replace({3, 1}, u"B");
  EXPECT(test, editor.stateId() == firstChangedState + 1);
  EXPECT(test, !editor.canRedo());
  expectBufferMatchesNaive(test, buffer, u"A\r\nB");
  EXPECT(test, editor.undo());
  EXPECT(test, editor.undo());
  expectBufferMatchesNaive(test, buffer, u"a\r\nb");
}

void compoundBatchEditsRestoreJoinedBoundaries() {
  constexpr std::string_view test = "compoundBatchEditsRestoreJoinedBoundaries";
  const SakuraString before = u"\rX\nY\rZ\n";
  TextBuffer buffer(before);
  sakura::core::EditEngine editor(buffer);
  const auto revision = buffer.revision();
  editor.replaceMany({{{1, 1}, u""}, {{4, 1}, u""}});
  expectBufferMatchesNaive(test, buffer, u"\r\nY\r\n");
  EXPECT(test, buffer.revision() == revision + 2);
  const auto changedState = editor.stateId();
  EXPECT(test, editor.canUndo());
  EXPECT(test, editor.undo());
  expectBufferMatchesNaive(test, buffer, before);
  EXPECT(test, !editor.canUndo());
  EXPECT(test, editor.redo());
  expectBufferMatchesNaive(test, buffer, u"\r\nY\r\n");
  EXPECT(test, editor.stateId() == changedState);
}

void layoutWrapsTabsAndUtf16Pairs() {
  constexpr std::string_view test = "layoutWrapsTabsAndUtf16Pairs";
  const MonospaceMetrics metrics;
  const LayoutEngine engine;
  FontStyle style;

  LayoutOptions wrapAtThree;
  wrapAtThree.wrapWidth = 3.0F;
  const auto wrapped = engine.layout(TextBuffer(u"abcdef\r\nx"), metrics,
                                     style, wrapAtThree);
  EXPECT(test, wrapped.lineHeight == 2.0F);
  EXPECT(test, wrapped.visualLines.size() == 3);
  EXPECT(test, wrapped.visualLines[0].logicalLine == 0);
  EXPECT(test, wrapped.visualLines[0].startColumn == 0);
  EXPECT(test, wrapped.visualLines[0].endColumn == 3);
  EXPECT(test, wrapped.visualLines[1].startColumn == 3);
  EXPECT(test, wrapped.visualLines[1].endColumn == 6);
  EXPECT(test, wrapped.visualLines[2].logicalLine == 1);
  EXPECT(test, wrapped.visualLineFor(TextPosition{0, 3}) == 0);
  EXPECT(test, wrapped.visualLineFor(TextPosition{0, 0}) == 0);
  EXPECT(test, wrapped.visualLineFor(TextPosition{0, 4}) == 1);
  EXPECT(test, wrapped.visualLineFor(TextPosition{0, 6}) == 1);
  EXPECT(test, wrapped.visualLineFor(TextPosition{1, 0}) == 2);
  bool rejectedMissingPosition = false;
  try {
    (void)wrapped.visualLineFor(TextPosition{0, 7});
  } catch (const std::out_of_range&) {
    rejectedMissingPosition = true;
  }
  EXPECT(test, rejectedMissingPosition);
  rejectedMissingPosition = false;
  try {
    (void)wrapped.visualLineFor(TextPosition{2, 0});
  } catch (const std::out_of_range&) {
    rejectedMissingPosition = true;
  }
  EXPECT(test, rejectedMissingPosition);

  const auto emptyLines = engine.layout(TextBuffer(u"\n\n"), metrics,
                                       style, wrapAtThree);
  for (std::size_t line = 0; line < 3; ++line) {
    EXPECT(test, emptyLines.visualLineFor(TextPosition{line, 0}) == line);
  }

  LayoutOptions tabOptions;
  tabOptions.wrapWidth = 4.0F;
  tabOptions.tabWidth = 4;
  const auto tabbed = engine.layout(TextBuffer(u"a\tb"), metrics, style,
                                    tabOptions);
  EXPECT(test, tabbed.visualLines.size() == 2);
  EXPECT(test, tabbed.visualLines[0].endColumn == 2);
  EXPECT(test, tabbed.visualLines[0].width == 4.0F);
  EXPECT(test, tabbed.visualLines[1].startColumn == 2);
  EXPECT(test, tabbed.visualLines[1].width == 1.0F);

  LayoutOptions emojiOptions;
  emojiOptions.wrapWidth = 2.0F;
  const auto emoji = engine.layout(TextBuffer(u"a😀b"), metrics, style,
                                   emojiOptions);
  EXPECT(test, emoji.visualLines.size() == 3);
  EXPECT(test, emoji.visualLines[1].startColumn == 1);
  EXPECT(test, emoji.visualLines[1].endColumn == 3);
  EXPECT(test, emoji.visualLines[1].width == 2.0F);
}

void wrappedTabsUseTheDisplayLineOrigin() {
  constexpr std::string_view test = "wrappedTabsUseTheDisplayLineOrigin";
  const MonospaceMetrics metrics;
  const LayoutEngine engine;
  const FontStyle style;
  const LayoutOptions options{10.0F, 4};

  // A tab following a completely filled display line starts at the next
  // line's first tab stop, rather than the logical line's twelfth column.
  const auto startsWithTab = engine.layout(
      TextBuffer(u"abcdefghij\tabcdefghi"), metrics, style, options);
  EXPECT(test, startsWithTab.visualLines.size() == 3);
  if (startsWithTab.visualLines.size() == 3) {
    EXPECT(test, startsWithTab.visualLines[0].endColumn == 10);
    EXPECT(test, startsWithTab.visualLines[1].startColumn == 10);
    EXPECT(test, startsWithTab.visualLines[1].endColumn == 17);
    EXPECT(test, startsWithTab.visualLines[1].width == 10.0F);
    EXPECT(test, startsWithTab.visualLines[2].width == 3.0F);
  }

  // The tab's width at column nine would be three, but after it forces a
  // wrap it must occupy four columns at the new display-line origin.
  const auto tabForcesWrap = engine.layout(
      TextBuffer(u"abcdefghi\tabcd"), metrics, style, options);
  EXPECT(test, tabForcesWrap.visualLines.size() == 2);
  if (tabForcesWrap.visualLines.size() == 2) {
    EXPECT(test, tabForcesWrap.visualLines[0].endColumn == 9);
    EXPECT(test, tabForcesWrap.visualLines[1].startColumn == 9);
    EXPECT(test, tabForcesWrap.visualLines[1].endColumn == 14);
    EXPECT(test, tabForcesWrap.visualLines[1].width == 8.0F);
  }

  // Tab stops also use the fragment origin when the tab itself is not the
  // first character on a wrapped display line.
  const auto tabWithinWrappedLine = engine.layout(
      TextBuffer(u"abcdefghijkl\tabcdefgh"), metrics, style, options);
  EXPECT(test, tabWithinWrappedLine.visualLines.size() == 3);
  if (tabWithinWrappedLine.visualLines.size() == 3) {
    EXPECT(test, tabWithinWrappedLine.visualLines[1].endColumn == 19);
    EXPECT(test, tabWithinWrappedLine.visualLines[1].width == 10.0F);
    EXPECT(test, tabWithinWrappedLine.visualLines[2].width == 2.0F);
  }

  const auto unwrapped = engine.layout(
      TextBuffer(u"abcdefghij\tabcdefghi"), metrics, style,
      {.wrapWidth = 0.0F, .tabWidth = 4});
  EXPECT(test, unwrapped.visualLines.size() == 1);
  EXPECT(test, unwrapped.visualLines.front().width == 21.0F);
}

void layoutKeepsExtendedGraphemesTogether() {
  constexpr std::string_view test = "layoutKeepsExtendedGraphemesTogether";
  const LayoutEngine engine;
  const FontStyle style;
  const LayoutOptions options{1.0F, 4};
  const std::vector<SakuraString> clusters{
      u"e\u0301",       // ASCII base plus a combining accent.
      u"か\u3099",      // Decomposed Japanese voiced sound mark.
      u"👨‍👩‍👧‍👦",     // Four people joined by zero-width joiners.
      u"🇯🇵",           // Regional indicator pair.
      u"👩🏽",           // Emoji modifier.
      u"❤\uFE0F",      // Variation selector.
      u"1\uFE0F\u20E3", // Keycap with an ASCII base.
      u"\u1100\u1161\u11A8", // Hangul Jamo syllable.
      u"\u0600A",      // Grapheme Prepend plus an ASCII character.
  };
  for (const auto& cluster : clusters) {
    const GraphemeMetrics metrics;
    SakuraString source = u"x";
    source += cluster;
    source += u"z\r\n";
    const auto result = engine.layout(TextBuffer(source), metrics, style, options);
    EXPECT(test, result.visualLines.size() == 4);
    if (result.visualLines.size() != 4) continue;
    EXPECT(test, result.visualLines[0].startColumn == 0);
    EXPECT(test, result.visualLines[0].endColumn == 1);
    EXPECT(test, result.visualLines[1].startColumn == 1);
    EXPECT(test, result.visualLines[1].endColumn == 1 + cluster.size());
    EXPECT(test, result.visualLines[1].width == 1.0F);
    EXPECT(test, result.visualLines[2].startColumn == 1 + cluster.size());
    EXPECT(test, result.visualLines[2].endColumn == source.size() - 2);
    EXPECT(test, result.visualLines[3].logicalLine == 1);
    EXPECT(test, result.visualLines[3].isEmpty());
    EXPECT(test, metrics.largestCluster == cluster.size());
  }

  // Leading marks form their own grapheme. A control/tab ends the preceding
  // cluster, and tab stops still restart at the wrapped display-line origin.
  const GraphemeMetrics metrics;
  const auto leadingMarks = engine.layout(TextBuffer(u"\u0301\u0308z"),
                                          metrics, style, options);
  EXPECT(test, leadingMarks.visualLines.size() == 2);
  EXPECT(test, leadingMarks.visualLines.front().endColumn == 2);
  const auto tabbed = engine.layout(TextBuffer(u"e\u0301\t\u0308z"),
                                   metrics, style, {4.0F, 4});
  EXPECT(test, tabbed.visualLines.size() == 2);
  EXPECT(test, tabbed.visualLines.front().endColumn == 3);
  EXPECT(test, tabbed.visualLines.front().width == 4.0F);
  EXPECT(test, tabbed.visualLines.back().startColumn == 3);

  // A sequence of regional indicators pairs from the beginning; it must not
  // regroup when a following cluster starts on a different display line.
  const auto flags = engine.layout(TextBuffer(u"🇯🇵🇺🇸🇨"), metrics, style, options);
  EXPECT(test, flags.visualLines.size() == 3);
  if (flags.visualLines.size() == 3) {
    EXPECT(test, flags.visualLines[0].endColumn == 4);
    EXPECT(test, flags.visualLines[1].endColumn == 8);
    EXPECT(test, flags.visualLines[2].endColumn == 10);
  }
}

void layoutHandlesMalformedAndOversizedGraphemes() {
  constexpr std::string_view test = "layoutHandlesMalformedAndOversizedGraphemes";
  const LayoutEngine engine;
  const FontStyle style;
  const MonospaceMetrics fallback;
  // Preserve malformed code units for editing: each lone surrogate remains
  // measurable, while valid pairs remain indivisible in the fallback adapter.
  const SakuraString malformed = u"\xD800" u"a\xDC00";
  const auto isolated = engine.layout(TextBuffer(malformed), fallback, style,
                                      {1.0F, 4});
  EXPECT(test, isolated.visualLines.size() == 3);
  for (std::size_t i = 0; i < isolated.visualLines.size(); ++i) {
    EXPECT(test, isolated.visualLines[i].startColumn == i);
    EXPECT(test, isolated.visualLines[i].endColumn == i + 1);
  }

  // The default cluster API still sums per-code-unit advances. A cluster
  // wider than the viewport overflows as a whole instead of looping or being
  // split, including when it is the final grapheme in a logical line.
  const auto fallbackAccent = engine.layout(TextBuffer(u"ae\u0301"), fallback,
                                             style, {1.0F, 4});
  EXPECT(test, fallbackAccent.visualLines.size() == 2);
  EXPECT(test, fallbackAccent.visualLines.back().startColumn == 1);
  EXPECT(test, fallbackAccent.visualLines.back().endColumn == 3);
  EXPECT(test, fallbackAccent.visualLines.back().width == 2.0F);

  SakuraString hugeCluster = u"e";
  hugeCluster.append(100'000, u'\u0301');
  const auto clusterSize = hugeCluster.size();
  hugeCluster += u"z";
  const GraphemeMetrics shaped;
  const auto oversized = engine.layout(TextBuffer(hugeCluster), shaped, style,
                                       {0.5F, 4});
  EXPECT(test, oversized.visualLines.size() == 2);
  EXPECT(test, oversized.visualLines.front().endColumn == clusterSize);
  EXPECT(test, oversized.visualLines.back().startColumn == clusterSize);
  EXPECT(test, shaped.largestCluster == clusterSize);

  const GraphemeMetrics asciiMetrics;
  const auto ascii = engine.layout(TextBuffer(SakuraString(100'000, u'a')),
                                   asciiMetrics, style, {80.0F, 4});
  EXPECT(test, ascii.visualLines.size() == 1'250);
  EXPECT(test, asciiMetrics.clusterCalls == 0);
}

void literalSearchSkipsInvalidEditBoundaries() {
  constexpr std::string_view test = "literalSearchSkipsInvalidEditBoundaries";
  const SearchEngine search;
  const SearchOptions options{.wrap = false};
  const TextBuffer mixedEndings(u"a\r\nb\nc\rx");
  const auto lineFeed = search.findNext(mixedEndings, u"\n", 0, options);
  EXPECT(test, lineFeed && lineFeed->range == (TextRange{4, 1}));
  const auto carriageReturn = search.findNext(mixedEndings, u"\r", 0, options);
  EXPECT(test, carriageReturn && carriageReturn->range == (TextRange{6, 1}));
  const auto pair = search.findNext(mixedEndings, u"\r\n", 0, options);
  EXPECT(test, pair && pair->range == (TextRange{1, 2}));
  EXPECT(test, search.findAll(mixedEndings, u"\n").size() == 1);

  const TextBuffer emoji(u"A😀B😀");
  EXPECT(test, search.findAll(emoji, u"\xD83D").empty());
  EXPECT(test, search.findAll(emoji, u"\xDE00").empty());
  const auto nextCompleteEmoji = search.findNext(emoji, u"😀", 2, options);
  EXPECT(test, nextCompleteEmoji && nextCompleteEmoji->range == (TextRange{4, 2}));
  const auto afterSplitBoundary = search.findNext(emoji, u"B", 2, options);
  EXPECT(test, afterSplitBoundary && afterSplitBoundary->range == (TextRange{3, 1}));
}

void searchAndReplaceRespectUtf16Boundaries() {
  constexpr std::string_view test = "searchAndReplaceRespectUtf16Boundaries";
  const TextBuffer buffer(u"One one stone\n😀one");
  const SearchEngine search;

  const auto first = search.findNext(buffer, u"one", 0,
                                     {.caseSensitive = false});
  EXPECT(test, first.has_value());
  EXPECT(test, first->range == (TextRange{0, 3}));
  const auto second = search.findNext(buffer, u"one", 3,
                                      {.caseSensitive = false});
  EXPECT(test, second.has_value());
  EXPECT(test, second->range == (TextRange{4, 3}));

  const auto whole = search.findAll(buffer, u"one",
                                    {.caseSensitive = false, .wholeWord = true});
  EXPECT(test, whole.size() == 3);
  EXPECT(test, whole[2].range.location == 16);
  EXPECT(test, !search.findNext(buffer, u"\xD83D", 0).has_value());

  DocumentSession document;
  EXPECT(test, document.load(bytes({'o', 'n', 'e', ' ', 'o', 'n', 'e'})).ok());
  const auto replaced = document.replaceAll(u"one", u"two");
  EXPECT(test, replaced.replacements == 2);
  EXPECT(test, document.buffer().text() == u"two two");
  EXPECT(test, document.undo());
  EXPECT(test, document.buffer().text() == u"one one");
  EXPECT(test, !document.canUndo());
  EXPECT(test, document.redo());
  EXPECT(test, document.buffer().text() == u"two two");

  DocumentSession captureDocument;
  EXPECT(test, captureDocument.load(bytes({
      'i', 't', 'e', 'm', '-', '1', '2', ' ',
      'i', 't', 'e', 'm', '-', '3', '4', '5'})).ok());
  const auto captured = captureDocument.replaceAll(
      u"item-([0-9]+)", u"[$1]",
      {.caseSensitive = true, .regularExpression = true});
  EXPECT(test, captured.valid);
  EXPECT(test, captured.replacements == 2);
  EXPECT(test, captureDocument.buffer().text() == u"[12] [345]");
  EXPECT(test, captureDocument.undo());
  EXPECT(test, captureDocument.buffer().text() == u"item-12 item-345");

  const auto invalidReplacement = captureDocument.replaceAll(
      u"[", u"x", {.regularExpression = true});
  EXPECT(test, !invalidReplacement.valid);
  EXPECT(test, invalidReplacement.replacements == 0);
  EXPECT(test, captureDocument.buffer().text() == u"item-12 item-345");

  const TextBuffer regexBuffer(u"item-12 item-345 item-x");
  const auto regular = search.findAll(
      regexBuffer, u"item-[0-9]+",
      {.caseSensitive = true, .regularExpression = true});
  EXPECT(test, regular.size() == 2);
  EXPECT(test, regular[0].range == (TextRange{0, 7}));
  EXPECT(test, regular[1].range == (TextRange{8, 8}));
  EXPECT(test, !search.findNext(regexBuffer, u"[", 0,
                                {.regularExpression = true}).has_value());
}

void unicodeRegexPreservesContextAndZeroWidthProgress() {
  constexpr std::string_view test = "unicodeRegexPreservesContextAndZeroWidthProgress";
  const SearchEngine search;
  const SearchOptions regex{.regularExpression = true};
  const auto unicode = search.findAll(TextBuffer(u"桜😀"), u".", regex);
  EXPECT(test, unicode.size() == 2);
  if (unicode.size() == 2) {
    EXPECT(test, unicode[0].range == (TextRange{0, 1}));
    EXPECT(test, unicode[1].range == (TextRange{1, 2}));
  }
  const TextBuffer anchored(u"foofoo");
  EXPECT(test, search.findAll(anchored, u"^foo", regex).size() == 1);
  EXPECT(test, !search.findNext(anchored, u"^foo", 3,
                               {.wrap = false, .regularExpression = true}));
  const auto wrapped = search.findNext(anchored, u"^foo", 3, regex);
  EXPECT(test, wrapped && wrapped->range == (TextRange{0, 3}));
  EXPECT(test, search.findAll(anchored, u"\\bfoo", regex).size() == 1);
  const auto behind = search.findNext(TextBuffer(u"ab"), u"(?<=a)b", 1, regex);
  EXPECT(test, behind && behind->range == (TextRange{1, 1}));

  const auto emptyMatches = search.findAll(TextBuffer(u"aa"), u"(?=a)|$", regex);
  EXPECT(test, emptyMatches.size() == 3);
  if (emptyMatches.size() == 3) {
    EXPECT(test, emptyMatches[0].range == (TextRange{0, 0}));
    EXPECT(test, emptyMatches[1].range == (TextRange{1, 0}));
    EXPECT(test, emptyMatches[2].range == (TextRange{2, 0}));
  }
  const auto emojiBoundaries = search.findAll(TextBuffer(u"😀"), u"(?=.)|$", regex);
  EXPECT(test, emojiBoundaries.size() == 2);
  if (emojiBoundaries.size() == 2) {
    EXPECT(test, emojiBoundaries[0].range == (TextRange{0, 0}));
    EXPECT(test, emojiBoundaries[1].range == (TextRange{2, 0}));
  }
  const auto crlfBoundaries = search.findAll(
      TextBuffer(u"a\r\nb"), u"(?=\\r)|(?=\\n)|$", regex);
  EXPECT(test, crlfBoundaries.size() == 2);
  if (crlfBoundaries.size() == 2) {
    EXPECT(test, crlfBoundaries[0].range == (TextRange{1, 0}));
    EXPECT(test, crlfBoundaries[1].range == (TextRange{4, 0}));
  }
  EXPECT(test, search.findAll(TextBuffer(u""), u"$", regex).size() == 1);
  EXPECT(test, SearchEngine::isValidPattern(u"(?<=a)b", regex));
  EXPECT(test, !SearchEngine::isValidPattern(u"[", regex));
}

void regexReplacementUsesOriginalCapturesAndContext() {
  constexpr std::string_view test = "regexReplacementUsesOriginalCapturesAndContext";
  const SearchOptions regex{.regularExpression = true};
  DocumentSession lookahead;
  lookahead.insert(0, u"ab ab");
  const auto result = lookahead.replaceAll(u"a(?=b)", u"X", regex);
  EXPECT(test, result.valid && result.replacements == 2);
  EXPECT(test, lookahead.buffer().text() == u"Xb Xb");
  EXPECT(test, lookahead.undo());
  EXPECT(test, lookahead.buffer().text() == u"ab ab");
  // The capture is outside the consumed match; re-matching just "a" loses it.
  const auto capture = lookahead.findNext(u"a(?=(b))", 0, regex);
  EXPECT(test, capture.has_value());
  if (capture) {
    EXPECT(test, lookahead.replacementText(*capture, u"[$1]", regex) == u"[b]");
    lookahead.replace(capture->range,
                      lookahead.replacementText(*capture, u"[$1]", regex));
    EXPECT(test, lookahead.buffer().text() == u"[b]b ab");
    EXPECT(test, lookahead.undo());
  }
  const auto captured = lookahead.replaceAll(u"a(?=(b))", u"[$1]", regex);
  EXPECT(test, captured.valid && captured.replacements == 2);
  EXPECT(test, lookahead.buffer().text() == u"[b]b [b]b");

  DocumentSession unicode;
  unicode.insert(0, u"桜A a😀 b");
  const SearchOptions insensitive{.caseSensitive = false, .regularExpression = true};
  const auto first = unicode.findNext(u"(桜a)", 0, insensitive);
  EXPECT(test, first.has_value());
  if (first) EXPECT(test, unicode.replacementText(*first, u"<$1>", insensitive) == u"<桜A>");
  const auto changed = unicode.replaceAll(u"(桜a)", u"<$1>", insensitive);
  EXPECT(test, changed.valid && changed.replacements == 1);
  EXPECT(test, unicode.buffer().text() == u"<桜A> a😀 b");
  EXPECT(test, unicode.replaceAll(u"a(?=(😀))", u"$1", regex).replacements == 1);
  EXPECT(test, unicode.buffer().text() == u"<桜A> 😀😀 b");
  EXPECT(test, unicode.replaceAll(u"(a)?b", u"$1$$1$&", regex).replacements == 1);
  EXPECT(test, unicode.buffer().text() == u"<桜A> 😀😀 $1b");
  EXPECT(test, unicode.replaceAll(u"$1b", u"$1").replacements == 1);
  EXPECT(test, unicode.buffer().text() == u"<桜A> 😀😀 $1");

  DocumentSession empty;
  const auto inserted = empty.replaceAll(u"$", u"X", regex);
  EXPECT(test, inserted.valid && inserted.replacements == 1);
  EXPECT(test, empty.buffer().text() == u"X");
  EXPECT(test, empty.undo());
  EXPECT(test, empty.buffer().text().empty());
  empty.insert(0, u"aa");
  EXPECT(test, empty.replaceAll(u"(?=a)|$", u"<", regex).replacements == 3);
  EXPECT(test, empty.buffer().text() == u"<a<a<");
  EXPECT(test, empty.undo());
  EXPECT(test, empty.buffer().text() == u"aa");
}

void searchCancellationAndLimitsDoNotPartiallyReplace() {
  constexpr std::string_view test = "searchCancellationAndLimitsDoNotPartiallyReplace";
  const auto limited = SearchEngine{}.findAll(TextBuffer(u"aaaa"), u".",
      {.regularExpression = true, .maxMatches = 2});
  EXPECT(test, limited.size() == 2);
  DocumentSession document;
  document.insert(0, u"aaaa");
  const auto all = document.replaceAll(u"a", u"b", {.maxMatches = 1});
  EXPECT(test, all.replacements == 4);
  EXPECT(test, document.buffer().text() == u"bbbb");
  EXPECT(test, document.undo());

  std::size_t checks = 0;
  bool cancelled = false;
  try {
    (void)document.replaceAll(u"a", u"b",
        {.cancelled = [&] { return ++checks > 3; }});
  } catch (const std::runtime_error&) { cancelled = true; }
  EXPECT(test, cancelled);
  EXPECT(test, document.buffer().text() == u"aaaa");

  document.insert(4, SakuraString(200, u'a') + u"!");
  const auto original = document.buffer().text();
  checks = 0;
  cancelled = false;
  try {
    (void)document.replaceAll(u"(a+)+$", u"b",
        {.regularExpression = true,
         .cancelled = [&] { return ++checks > 2; }});
  } catch (const std::runtime_error&) { cancelled = true; }
  EXPECT(test, cancelled);
  EXPECT(test, checks > 2);
  EXPECT(test, document.buffer().text() == original);

  bool timedOut = false;
  try {
    (void)document.replaceAll(u"(a+)+$", u"b",
        {.regularExpression = true, .regexTimeLimitMilliseconds = 1});
  } catch (const std::runtime_error&) { timedOut = true; }
  EXPECT(test, timedOut);
  EXPECT(test, document.buffer().text() == original);

  DocumentSession bounded;
  bounded.insert(0, u"aaaa");
  bool expansionLimited = false;
  try {
    (void)bounded.replaceAll(u"a", u"$`$'", {.regularExpression = true,
        .maxReplacementCodeUnits = 6});
  } catch (const std::length_error&) { expansionLimited = true; }
  EXPECT(test, expansionLimited);
  EXPECT(test, bounded.buffer().text() == u"aaaa");
  bool documentLimited = false;
  try {
    (void)bounded.replaceAll(u"a$", u"XX", {.regularExpression = true,
        .maxReplacementCodeUnits = 4});
  } catch (const std::length_error&) { documentLimited = true; }
  EXPECT(test, documentLimited);
  EXPECT(test, bounded.buffer().text() == u"aaaa");
  const auto boundedResult = bounded.replaceAll(u"a", u"b",
      {.maxReplacementCodeUnits = 4});
  EXPECT(test, boundedResult.replacements == 4);
  EXPECT(test, bounded.buffer().text() == u"bbbb");
}

void syntaxHighlightingFindsCLikeTokens() {
  constexpr std::string_view test = "syntaxHighlightingFindsCLikeTokens";
  const TextBuffer buffer(
      u"#include <vector>\n// note\nint main() { auto value = \"桜\"; return 42; }\n");
  const auto tokens = SyntaxHighlighter{}.highlightCLike(buffer);
  const auto contains = [&](SyntaxTokenKind kind) {
    return std::any_of(tokens.begin(), tokens.end(),
                       [&](const auto& token) { return token.kind == kind; });
  };
  EXPECT(test, contains(SyntaxTokenKind::preprocessor));
  EXPECT(test, contains(SyntaxTokenKind::comment));
  EXPECT(test, contains(SyntaxTokenKind::keyword));
  EXPECT(test, contains(SyntaxTokenKind::string));
  EXPECT(test, contains(SyntaxTokenKind::number));
  for (std::size_t index = 1; index < tokens.size(); ++index) {
    EXPECT(test, tokens[index - 1].range.location + tokens[index - 1].range.length <=
                     tokens[index].range.location);
  }
}

void editEngineSupportsUndoAndRedo() {
  constexpr std::string_view test = "editEngineSupportsUndoAndRedo";
  DocumentSession document;
  const auto initial = bytes({'a', '\n', 'b'});
  EXPECT(test, document.load(initial).ok());
  EXPECT(test, !document.isDirty());

  document.replace(TextRange{0, 1}, u"a");
  EXPECT(test, !document.isDirty());
  EXPECT(test, !document.canUndo());

  document.replace(TextRange{2, 1}, u"日本");
  EXPECT(test, document.buffer().text() == u"a\n日本");
  EXPECT(test, document.isDirty());
  EXPECT(test, document.undo());
  EXPECT(test, document.buffer().text() == u"a\nb");
  EXPECT(test, !document.isDirty());
  EXPECT(test, document.redo());
  EXPECT(test, document.buffer().text() == u"a\n日本");
  EXPECT(test, document.isDirty());

  document.undo();
  document.insert(3, u"!");
  EXPECT(test, !document.canRedo());
}

void editEngineRejectsSplitSurrogates() {
  constexpr std::string_view test = "editEngineRejectsSplitSurrogates";
  TextBuffer buffer(u"x😀y");
  bool threw = false;
  try {
    buffer.replace(TextRange{2, 0}, u"!");
  } catch (const std::invalid_argument&) {
    threw = true;
  }
  EXPECT(test, threw);
  EXPECT(test, buffer.text() == u"x😀y");
}

void utf8CodecRoundTripsUnicodeAndBom() {
  constexpr std::string_view test = "utf8CodecRoundTripsUnicodeAndBom";
  const SakuraString source = u"桜エディタ 😀\r\n";
  const auto encoded = Utf8Codec::encode(source, BomPolicy::always);
  EXPECT(test, encoded.ok());
  EXPECT(test, encoded.bytes.size() > 3);
  EXPECT(test, encoded.bytes[0] == std::byte{0xEF});

  const auto decoded = Utf8Codec::decode(encoded.bytes);
  EXPECT(test, decoded.ok());
  EXPECT(test, decoded.hadBom);
  EXPECT(test, decoded.text == source);
}

void utf8CodecReportsInvalidInput() {
  constexpr std::string_view test = "utf8CodecReportsInvalidInput";
  const std::vector<std::vector<std::byte>> invalidSequences{
      bytes({0xE3, 0x81}),                    // truncated
      bytes({0x80}),                          // stray continuation
      bytes({0xC0, 0x80}),                    // overlong NUL
      bytes({0xE0, 0x80, 0x80}),              // overlong NUL
      bytes({0xED, 0xA0, 0x80}),              // UTF-16 surrogate
      bytes({0xF4, 0x90, 0x80, 0x80}),        // above U+10FFFF
  };
  for (const auto& invalid : invalidSequences) {
    const auto decoded = Utf8Codec::decode(invalid);
    EXPECT(test, !decoded.ok());
    EXPECT(test, decoded.error.has_value());
    EXPECT(test, decoded.error->offsetUnit == CodecOffsetUnit::inputByte);
  }

  SakuraString unpaired;
  unpaired.push_back(u'\xD800');
  const auto encoded = Utf8Codec::encode(unpaired);
  EXPECT(test, !encoded.ok());
  EXPECT(test, encoded.error->offset == 0);
  EXPECT(test, encoded.error->offsetUnit == CodecOffsetUnit::utf16CodeUnit);
}

void utf16CodecHandlesByteOrderBomAndPairs() {
  constexpr std::string_view test = "utf16CodecHandlesByteOrderBomAndPairs";
  const SakuraString source = u"桜😀";
  const auto little = Utf16Codec::encode(source, Utf16ByteOrder::littleEndian,
                                         BomPolicy::always);
  EXPECT(test, little.ok());
  EXPECT(test, little.bytes[0] == std::byte{0xFF});
  EXPECT(test, little.bytes[1] == std::byte{0xFE});
  const auto decodedLittle = Utf16Codec::decode(
      little.bytes, Utf16ByteOrder::bigEndian);
  EXPECT(test, decodedLittle.ok());
  EXPECT(test, decodedLittle.hadBom);
  EXPECT(test, decodedLittle.text == source);

  const auto big = Utf16Codec::encode(source, Utf16ByteOrder::bigEndian);
  EXPECT(test, big.ok());
  EXPECT(test, big.bytes[0] == std::byte{0x68});
  EXPECT(test, big.bytes[1] == std::byte{0x5C});
  const auto decodedBig = Utf16Codec::decode(big.bytes, Utf16ByteOrder::bigEndian);
  EXPECT(test, decodedBig.ok());
  EXPECT(test, !decodedBig.hadBom);
  EXPECT(test, decodedBig.text == source);
}

void utf16CodecRejectsMalformedInput() {
  constexpr std::string_view test = "utf16CodecRejectsMalformedInput";
  const auto odd = Utf16Codec::decode(bytes({0x61}), Utf16ByteOrder::littleEndian);
  EXPECT(test, !odd.ok());
  EXPECT(test, odd.error->offsetUnit == CodecOffsetUnit::inputByte);

  const auto loneHigh = Utf16Codec::decode(bytes({0x00, 0xD8}),
                                            Utf16ByteOrder::littleEndian);
  EXPECT(test, !loneHigh.ok());
  EXPECT(test, loneHigh.error->offset == 0);

  SakuraString loneLow;
  loneLow.push_back(u'\xDC00');
  const auto encoded = Utf16Codec::encode(loneLow, Utf16ByteOrder::bigEndian);
  EXPECT(test, !encoded.ok());
  EXPECT(test, encoded.error->offsetUnit == CodecOffsetUnit::utf16CodeUnit);
}

void encodingServicePreservesDetectedEncoding() {
  constexpr std::string_view test = "encodingServicePreservesDetectedEncoding";
  const SakuraString source = u"UTF-16 😀";
  const auto input = Utf16Codec::encode(source, Utf16ByteOrder::littleEndian,
                                        BomPolicy::always);
  const auto decoded = sakura::core::defaultEncodingService().decode(input.bytes);
  EXPECT(test, decoded.ok());
  EXPECT(test, decoded.state ==
                   (EncodingState{TextEncoding::utf16LittleEndian, true}));
  EXPECT(test, decoded.text == source);

  const auto encoded = sakura::core::defaultEncodingService().encode(decoded.text,
                                                                        decoded.state);
  EXPECT(test, encoded.ok());
  EXPECT(test, encoded.state == decoded.state);
  EXPECT(test, encoded.bytes == input.bytes);
  EXPECT(test, EncodingService::name(encoded.state.encoding) == "UTF-16LE");
}

void documentSessionRoundTripsUtf16() {
  constexpr std::string_view test = "documentSessionRoundTripsUtf16";
  DocumentSession document;
  const auto source = Utf16Codec::encode(u"桜\r\n", Utf16ByteOrder::bigEndian,
                                         BomPolicy::always);
  EXPECT(test, source.ok());
  EXPECT(test, document.load(source.bytes).ok());
  EXPECT(test, document.encodingState() ==
                   (EncodingState{TextEncoding::utf16BigEndian, true}));
  document.insert(3, u"!\n");

  const auto saved = document.makeSaveSnapshot();
  EXPECT(test, saved.encoded.ok());
  EXPECT(test, saved.token.encodingState == document.encodingState());
  const auto decoded = sakura::core::defaultEncodingService().decode(
      saved.encoded.bytes);
  EXPECT(test, decoded.ok());
  EXPECT(test, decoded.state ==
                   (EncodingState{TextEncoding::utf16BigEndian, true}));
  EXPECT(test, decoded.text == u"桜\r\n!\n");
}

void failedLoadDoesNotReplaceTheDocument() {
  constexpr std::string_view test = "failedLoadDoesNotReplaceTheDocument";
  DocumentSession document;
  const auto valid = bytes({'s', 'a', 'f', 'e'});
  EXPECT(test, document.load(valid).ok());
  document.insert(4, u"!");

  const auto invalid = bytes({0xE3, 0x81});
  EXPECT(test, !document.load(invalid).ok());
  EXPECT(test, document.buffer().text() == u"safe!");
  EXPECT(test, document.isDirty());
}

void documentSessionPreservesSourceBom() {
  constexpr std::string_view test = "documentSessionPreservesSourceBom";
  DocumentSession document;
  const auto source = bytes({0xEF, 0xBB, 0xBF, 'o', 'k', '\n'});
  EXPECT(test, document.load(source).ok());
  EXPECT(test, document.sourceHadBom());
  document.insert(2, u"!");

  const auto saved = document.makeSaveSnapshot();
  EXPECT(test, saved.encoded.ok());
  EXPECT(test, saved.encoded.bytes[0] == std::byte{0xEF});
  const auto decoded = Utf8Codec::decode(saved.encoded.bytes);
  EXPECT(test, decoded.text == u"ok!\n");
}

void saveSnapshotDoesNotHideSubsequentEdits() {
  constexpr std::string_view test = "saveSnapshotDoesNotHideSubsequentEdits";
  DocumentSession document;
  const auto source = bytes({'a'});
  EXPECT(test, document.load(source).ok());
  document.insert(1, u"b");
  const auto snapshot = document.makeSaveSnapshot();
  document.insert(2, u"c");

  document.markSaved(snapshot.token);
  EXPECT(test, document.buffer().text() == u"abc");
  EXPECT(test, document.isDirty());
  EXPECT(test, Utf8Codec::decode(snapshot.encoded.bytes).text == u"ab");

  EXPECT(test, document.undo());
  EXPECT(test, !document.isDirty());
}

void saveTokensAreNotReusedAfterLoad() {
  constexpr std::string_view test = "saveTokensAreNotReusedAfterLoad";
  DocumentSession document;
  EXPECT(test, document.load(bytes({0xEF, 0xBB, 0xBF, 'a'})).ok());
  document.insert(1, u"b");
  const auto obsoleteSnapshot = document.makeSaveSnapshot();

  EXPECT(test, document.load(bytes({'x'})).ok());
  EXPECT(test, !document.sourceHadBom());
  document.insert(1, u"y");
  EXPECT(test, document.isDirty());
  document.markSaved(obsoleteSnapshot.token);
  EXPECT(test, document.isDirty());
  EXPECT(test, !document.sourceHadBom());
  EXPECT(test, document.buffer().text() == u"xy");
}

void successfulSaveUpdatesTheBomState() {
  constexpr std::string_view test = "successfulSaveUpdatesTheBomState";
  DocumentSession document;
  EXPECT(test, document.load(bytes({'x'})).ok());
  const auto withBom = document.makeSaveSnapshot(BomPolicy::always);
  EXPECT(test, withBom.token.encodingState.hadBom);
  document.markSaved(withBom.token);
  const auto preserved = document.makeSaveSnapshot(BomPolicy::preserve);
  EXPECT(test, preserved.encoded.bytes[0] == std::byte{0xEF});

  const auto withoutBom = document.makeSaveSnapshot(BomPolicy::never);
  EXPECT(test, !withoutBom.token.encodingState.hadBom);
  document.markSaved(withoutBom.token);
  const auto preservedWithoutBom =
      document.makeSaveSnapshot(BomPolicy::preserve);
  EXPECT(test, preservedWithoutBom.encoded.bytes[0] == std::byte{'x'});
}

void encodingMetadataParticipatesInDirtyState() {
  constexpr std::string_view test = "encodingMetadataParticipatesInDirtyState";
  DocumentSession document;
  EXPECT(test, document.load(bytes({'x'})).ok());
  EXPECT(test, !document.isDirty());

  document.setEncodingState({TextEncoding::utf16LittleEndian, true});
  EXPECT(test, document.isDirty());
  const auto snapshot = document.makeSaveSnapshot(BomPolicy::preserve);
  EXPECT(test, snapshot.encoded.ok());
  EXPECT(test, snapshot.token.encodingState ==
                   (EncodingState{TextEncoding::utf16LittleEndian, true}));
  document.markSaved(snapshot.token);
  EXPECT(test, !document.isDirty());

  document.markMetadataChanged();
  EXPECT(test, document.isDirty());
}

void saveCompletionPreservesNewEncodingChoices() {
  constexpr std::string_view test = "saveCompletionPreservesNewEncodingChoices";
  for (const auto policy : {BomPolicy::preserve, BomPolicy::always, BomPolicy::never}) {
    DocumentSession document;
    EXPECT(test, document.load(bytes({'x'})).ok());
    document.insert(1, u"!");
    const auto old = document.makeSaveSnapshot(policy);
    const EncodingState chosen{TextEncoding::utf16BigEndian, true};
    document.setEncodingState(chosen);
    document.markSaved(old.token);
    EXPECT(test, document.encodingState() == chosen);
    EXPECT(test, document.isDirty());
    const auto next = document.makeSaveSnapshot();
    EXPECT(test, next.encoded.ok());
    EXPECT(test, next.token.encodingState == chosen);
    document.markSaved(next.token);
    EXPECT(test, !document.isDirty());
    EXPECT(test, document.encodingState() == chosen);
  }
  // A newer explicit choice remains authoritative even after returning to the
  // original value; equality alone cannot authenticate an old BOM policy.
  DocumentSession document;
  EXPECT(test, document.load(bytes({'x'})).ok());
  const auto withBom = document.makeSaveSnapshot(BomPolicy::always);
  document.setEncodingState({TextEncoding::utf16LittleEndian, true});
  document.setEncodingState({TextEncoding::utf8, false});
  document.markSaved(withBom.token);
  EXPECT(test, document.encodingState() == (EncodingState{TextEncoding::utf8, false}));
  EXPECT(test, document.isDirty());
}

void unrelatedMetadataDoesNotDiscardSuccessfulBomPolicy() {
  constexpr std::string_view test = "unrelatedMetadataDoesNotDiscardSuccessfulBomPolicy";
  DocumentSession document;
  EXPECT(test, document.load(bytes({'x'})).ok());
  const auto withBom = document.makeSaveSnapshot(BomPolicy::always);
  document.markMetadataChanged(); // E.g. a preferred newline change.
  document.markSaved(withBom.token);
  EXPECT(test, document.encodingState() == (EncodingState{TextEncoding::utf8, true}));
  EXPECT(test, document.isDirty());
  document.markSaved(document.makeSaveSnapshot().token);
  EXPECT(test, !document.isDirty());
}

void documentSessionBatchesRectangularEdits() {
  constexpr std::string_view test = "documentSessionBatchesRectangularEdits";
  DocumentSession document;
  EXPECT(test, document.load(bytes({
      'a', 'b', 'c', 'd', '\n',
      'e', 'f', 'g', 'h', '\n',
      'i', 'j', 'k', 'l'})).ok());
  document.replaceMany({
      {{11, 2}, u"X"},
      {{6, 2}, u"X"},
      {{1, 2}, u"X"},
  });
  EXPECT(test, document.buffer().text() == u"aXd\neXh\niXl");
  EXPECT(test, document.undo());
  EXPECT(test, document.buffer().text() == u"abcd\nefgh\nijkl");
  EXPECT(test, document.redo());
  EXPECT(test, document.buffer().text() == u"aXd\neXh\niXl");
}

class ReplaceCommand final : public ICommandHandler {
 public:
  CommandResult execute(CommandContext& context, const CommandArgs& args) override {
    if (context.document == nullptr || !args.range.has_value()) {
      return CommandResult::failure("document and range are required");
    }
    context.document->replace(*args.range, args.text);
    return CommandResult::success();
  }
};

void commandBusDispatchesStableFunctionCodes() {
  constexpr std::string_view test = "commandBusDispatchesStableFunctionCodes";
  constexpr sakura::app::FunctionCode replaceCode = 30'123;
  CommandBus bus;
  EXPECT(test, bus.registerHandler(replaceCode, std::make_unique<ReplaceCommand>()));
  EXPECT(test, !bus.registerHandler(replaceCode, std::make_unique<ReplaceCommand>()));

  DocumentSession document;
  const auto source = bytes({'a', 'b', 'c'});
  EXPECT(test, document.load(source).ok());
  CommandContext context{&document, sakura::app::CommandSource::keyboard};
  CommandArgs args{TextRange{1, 1}, u"桜"};
  EXPECT(test, bus.execute(replaceCode, context, args).succeeded());
  EXPECT(test, document.buffer().text() == u"a桜c");
  EXPECT(test, !bus.execute(99, context).handled);
}

void documentOwnershipCannotBeAliased() {
  constexpr std::string_view test = "documentOwnershipCannotBeAliased";
  EXPECT(test, !std::is_copy_constructible_v<DocumentSession>);
  EXPECT(test, !std::is_copy_assignable_v<DocumentSession>);
  EXPECT(test, !std::is_move_constructible_v<DocumentSession>);
  EXPECT(test, !std::is_move_assignable_v<DocumentSession>);
  EXPECT(test, !std::is_copy_constructible_v<sakura::core::EditEngine>);
  EXPECT(test, !std::is_move_constructible_v<sakura::core::EditEngine>);
}

}  // namespace

int main() {
  textBufferPreservesMixedEndings();
  textBufferMapsUtf16Offsets();
  textBufferProtectsAliasingAndCrLf();
  incrementalReplaceMatchesSerializedText();
  textBufferRandomizedEditsKeepPrefixIndexConsistent();
  ordinaryLineEditsKeepOtherLineStorageStable();
  textBufferCopiesMovesAndFailuresKeepIndexConsistent();
  undoRedoHandlesNewCrLfBoundaries();
  failedBatchEditPreservesTextHistoryAndRevision();
  compoundBatchEditsRestoreJoinedBoundaries();
  layoutWrapsTabsAndUtf16Pairs();
  wrappedTabsUseTheDisplayLineOrigin();
  layoutKeepsExtendedGraphemesTogether();
  layoutHandlesMalformedAndOversizedGraphemes();
  literalSearchSkipsInvalidEditBoundaries();
  searchAndReplaceRespectUtf16Boundaries();
  unicodeRegexPreservesContextAndZeroWidthProgress();
  regexReplacementUsesOriginalCapturesAndContext();
  searchCancellationAndLimitsDoNotPartiallyReplace();
  syntaxHighlightingFindsCLikeTokens();
  editEngineSupportsUndoAndRedo();
  editEngineRejectsSplitSurrogates();
  utf8CodecRoundTripsUnicodeAndBom();
  utf8CodecReportsInvalidInput();
  utf16CodecHandlesByteOrderBomAndPairs();
  utf16CodecRejectsMalformedInput();
  encodingServicePreservesDetectedEncoding();
  documentSessionRoundTripsUtf16();
  failedLoadDoesNotReplaceTheDocument();
  documentSessionPreservesSourceBom();
  saveSnapshotDoesNotHideSubsequentEdits();
  saveTokensAreNotReusedAfterLoad();
  successfulSaveUpdatesTheBomState();
  encodingMetadataParticipatesInDirtyState();
  saveCompletionPreservesNewEncodingChoices();
  unrelatedMetadataDoesNotDiscardSuccessfulBomPolicy();
  documentSessionBatchesRectangularEdits();
  commandBusDispatchesStableFunctionCodes();
  documentOwnershipCannotBeAliased();

  if (failures != 0) {
    std::cerr << failures << " portable core test(s) failed\n";
    return 1;
  }
  std::cout << "All portable core tests passed\n";
  return 0;
}
