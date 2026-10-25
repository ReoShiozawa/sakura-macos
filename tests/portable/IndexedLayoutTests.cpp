// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include "sakura/core/layout/IndexedLayout.h"
#include <array>
#include <atomic>
#include <chrono>
#include <iostream>
#include <random>
#include <stdexcept>
#include <thread>

namespace {
using namespace sakura::core;
int failures{};
void check(bool value, const char* label) { if (!value) { ++failures; std::cerr << label << '\n'; } }
struct Metrics final : ITextMetrics {
  mutable std::size_t calls{};
  float spacing{};
  bool throws{};
  float advance(SakuraChar c, const FontStyle&) const override {
    ++calls;
    if (throws) throw std::runtime_error("injected measurement failure");
    return (c >= 0x80 ? 2 : 1) + spacing;
  }
  float lineHeight(const FontStyle& style) const override { return style.pointSize > 0 ? style.pointSize : 1; }
};
constexpr FontStyle style{0, 13, 400, false};
void compare(const IndexedLayout& index, const TextBuffer& buffer, Metrics& metrics, LayoutOptions options) {
  const auto expected = LayoutEngine{}.layout(buffer, metrics, style, options);
  check(index.size() == expected.visualLines.size(), "indexed and full visual-row counts agree");
  if (index.size() != expected.visualLines.size()) return;
  float widest = 0;
  for (std::size_t row = 0; row < index.size(); ++row) {
    const auto actual = index.row(row);
    const auto& reference = expected.visualLines[row];
    check(actual.visual.logicalLine == reference.logicalLine && actual.visual.startColumn == reference.startColumn &&
          actual.visual.endColumn == reference.endColumn && actual.visual.width == reference.width &&
          actual.visual.height == reference.height, "all indexed row fields match full layout");
    check(actual.range.location == buffer.offsetAt({reference.logicalLine, reference.startColumn}) &&
          actual.range.length == reference.endColumn - reference.startColumn, "indexed serialized offsets match buffer");
    for (auto column : {reference.startColumn, reference.endColumn})
      check(index.visualLineFor({reference.logicalLine, column}) == expected.visualLineFor({reference.logicalLine, column}),
            "visual lookup preserves preceding-fragment affinity");
    widest = std::max(widest, reference.width);
  }
  check(index.widestLine() == widest && index.lineHeight() == expected.lineHeight, "width/height aggregates match");
  for (TextOffset offset = 0; offset <= buffer.length(); ++offset) {
    if (buffer.length() > 1000 && offset > 100 && offset % 1009 != 0 && offset != buffer.length()) continue;
    check(index.visualLineForOffset(offset) == expected.visualLineFor(buffer.positionAt(offset)),
          "offset lookup handles EOL code units, empty lines and soft-wrap affinity");
  }
  const auto invariants = index.storageStatistics();
  check(invariants.valid && invariants.logicalLines == buffer.lineCount(), "layout tree aggregate/AVL invariants");
}
void validatesTextDelta(const TextBuffer& previous, const TextBuffer& next) {
  const auto delta = next.changesFrom(previous);
  const auto before = previous.text(), after = next.text();
  check(delta.firstLine + delta.oldLineCount <= previous.lineCount() &&
        delta.firstLine + delta.newLineCount <= next.lineCount(), "delta line bounds");
  check(previous.lineCount() - delta.oldLineCount == next.lineCount() - delta.newLineCount, "delta row count conservation");
  check(before.substr(0, delta.oldText.location) == after.substr(0, delta.newText.location), "delta prefix remains unchanged");
  check(before.substr(delta.oldText.location + delta.oldText.length) ==
        after.substr(delta.newText.location + delta.newText.length), "delta suffix remains unchanged");
}
void arbitraryUtf16CopiesAndRanges() {
  TextBuffer buffer(u"a\r\nあ😀\re\u0301\n\n");
  const auto text = buffer.text();
  for (std::size_t start = 0; start <= text.size(); ++start)
    for (std::size_t length = 0; length <= text.size() - start; ++length) {
      SakuraString copied(length + 1, u'!');
      buffer.copyText({start, length}, copied);
      check(copied.substr(0, length) == text.substr(start, length) && copied.back() == u'!',
            "copyText supports arbitrary UTF-16/CRLF subranges without overwriting tail");
    }
  for (std::size_t index = 0; index < text.size(); ++index) check(buffer.characterAt(index) == text[index], "characterAt exact code units");
  bool rejected = false;
  try { (void)buffer.characterAt(text.size()); } catch (const std::out_of_range&) { rejected = true; }
  check(rejected, "characterAt rejects end offset");
  rejected = false;
  try { std::array<SakuraChar, 1> output; buffer.copyText({0, 2}, output); } catch (const std::out_of_range&) { rejected = true; }
  check(rejected, "copyText validates capacity before writing");
}
void randomizedEditsAndSnapshots() {
  Metrics metrics;
  LayoutOptions options{9, 4};
  TextBuffer buffer(u"aa\tbb\r\n日本語e\u0301😀\n// last\n");
  IndexedLayout index;
  index.update(buffer, metrics, style, options);
  std::mt19937 random(0x1A90);
  const SakuraString edits[]{u"", u"a", u"int x", u"\n", u"\r", u"\r\n", u"あ\nい", u"e\u0301", u"😀", u"\t\t"};
  for (int edit = 0; edit < 4500; ++edit) {
    const auto previous = buffer;
    const auto oldIndex = index;
    auto start = random() % (buffer.length() + 1);
    while (!buffer.isEditBoundary(start)) --start;
    auto end = std::min<TextOffset>(buffer.length(), start + random() % 12);
    while (!buffer.isEditBoundary(end)) --end;
    buffer.replace({start, end - start}, edits[random() % std::size(edits)]);
    validatesTextDelta(previous, buffer);
    if (edit % 53 == 0) options.wrapWidth = options.wrapWidth == 9 ? 0 : 9;
    index.update(buffer, metrics, style, options);
    compare(index, buffer, metrics, options);
    check(oldIndex.storageStatistics().valid, "retained old layout remains valid after update");
    if (edit % 79 == 0) {
      auto unrelated = TextBuffer(u"unrelated\ntext\r\n");
      index.update(unrelated, metrics, style, options); compare(index, unrelated, metrics, options);
      index.update(buffer, metrics, style, options); compare(index, buffer, metrics, options);
    }
  }
  auto moved = std::move(index);
  index.update(buffer, metrics, style, options); compare(index, buffer, metrics, options);
  compare(moved, buffer, metrics, options);
}
void localWorkAndStrongFailureGuarantee() {
  SakuraString text;
  for (std::size_t line = 0; line < 64000; ++line) text += u"abcd\txyz\n";
  TextBuffer buffer(text);
  Metrics metrics;
  IndexedLayout index;
  const LayoutOptions options{12, 4};
  index.update(buffer, metrics, style, options);
  auto delta = buffer.changesFrom(buffer);
  check(delta.oldLineCount == 0 && delta.newLineCount == 0 && delta.comparedNodes == 1,
        "unchanged snapshots skip root in one comparison");
  for (std::size_t edit = 0; edit < 150; ++edit) {
    const auto line = (edit * 423) % 64000;
    buffer.replace({buffer.offsetAt({line, 1}), 1}, edit % 2 ? u"xx" : u"z");
    metrics.calls = 0;
    index.update(buffer, metrics, style, options);
    check(index.lastUpdate().measuredLines == 1 && !index.lastUpdate().fullRebuild && metrics.calls < 100,
          "local edit measures one line without traversing suffix");
    check(index.lastUpdate().comparedTextNodes < 300, "local delta skips shared subtrees");
  }
  check(index.storageStatistics().nodes < 2100, "block merging avoids per-edit node fragmentation");
  const auto old = index;
  const auto firstRow = old.row(0);
  buffer.replace({0, 0}, u"new\nlines\n");
  metrics.throws = true;
  bool failed = false;
  try { index.update(buffer, metrics, style, options); } catch (const std::runtime_error&) { failed = true; }
  check(failed && index.size() == old.size() && index.row(0).range == firstRow.range,
        "measurement failure cannot publish partial layout");
  metrics.throws = false;
  index.update(buffer, metrics, style, options);
  check(index.lastUpdate().measuredLines <= 5, "structural edit remeasures boundary neighbors only");
  compare(index, buffer, metrics, options);
  metrics.spacing = 1;
  index.update(buffer, metrics, style, options, 1);
  check(index.lastUpdate().fullRebuild && index.lastUpdate().measuredLines == buffer.lineCount(),
        "metrics revision invalidates all widths");
  compare(index, buffer, metrics, options);
}
void benchmark() {
  using Clock = std::chrono::steady_clock;
  constexpr std::size_t units = 100 * 1024 * 1024, rows = 1000000;
  SakuraString text(units, u'a');
  const auto content = units - (rows - 1), perLine = content / rows, extra = content % rows;
  std::size_t cursor = 0;
  for (std::size_t line = 0; line < rows; ++line) {
    cursor += perLine + (line < extra ? 1 : 0);
    if (line + 1 < rows) text[cursor++] = u'\n';
  }
  TextBuffer buffer(text); text.clear(); text.shrink_to_fit();
  Metrics metrics; IndexedLayout index;
  auto start = Clock::now(); index.update(buffer, metrics, style, {80, 4}); auto cold = Clock::now();
  buffer.replace({buffer.offsetAt({500000, 50}), 1}, u"あ");
  metrics.calls = 0;
  auto edit = Clock::now(); index.update(buffer, metrics, style, {80, 4}); auto hot = Clock::now();
  check(index.lastUpdate().measuredLines == 1, "million-line benchmark local work");
  std::cout << "UTF16Units=" << buffer.length() << " lines=" << buffer.lineCount() << " visualRows=" << index.size()
            << " cold_ms=" << std::chrono::duration<double,std::milli>(cold-start).count()
            << " edit_update_ms=" << std::chrono::duration<double,std::milli>(hot-edit).count()
            << " measuredLines=" << index.lastUpdate().measuredLines << " textNodes=" << index.lastUpdate().comparedTextNodes
            << " metricCalls=" << metrics.calls << '\n';
}
void readersRetainOldLayoutDuringEdits() {
  TextBuffer buffer(u"one\r\nあ😀\nlast");
  Metrics metrics; IndexedLayout index;
  index.update(buffer, metrics, style, {5, 4});
  const auto snapshot = index;
  const auto expected = snapshot.row(snapshot.size() - 1);
  std::atomic<unsigned int> errors{};
  std::vector<std::thread> readers;
  for (int reader = 0; reader < 4; ++reader) readers.emplace_back([&] {
    for (int query = 0; query < 2000; ++query) {
      const auto last = snapshot.row(snapshot.size() - 1);
      if (last.range != expected.range || snapshot.visualLineFor({2, 4}) != snapshot.size() - 1) ++errors;
    }
  });
  for (int edit = 0; edit < 300; ++edit) {
    buffer.replace({0, 1}, edit % 2 ? u"abcd\n" : u"x");
    index.update(buffer, metrics, style, {5, 4});
  }
  for (auto& reader : readers) reader.join();
  check(errors == 0, "immutable indexed-layout readers survive source edits");
}
void cancelledLayoutNeverPublishesPartialRows() {
  Metrics metrics;TextBuffer source(u"original\ntext");IndexedLayout index;
  index.update(source,metrics,style,{5,4});
  TextBuffer replacement(SakuraString(10000,u'a')+u"\nnext");
  for(int budget : {0,1,2,5,10}) {
    int calls=0;bool cancelled=false;
    try{index.update(replacement,metrics,style,{5,4},0,[&]{return ++calls>budget;});}
    catch(const std::runtime_error&){cancelled=true;}
    check(cancelled && index.matchesText(source) && !index.matchesText(replacement),"cancelled layout retains exact original text root/revision");
  }
}
}  // namespace
int main(int argc, char**) {
  if (argc > 1) benchmark();
  else { arbitraryUtf16CopiesAndRanges(); randomizedEditsAndSnapshots(); localWorkAndStrongFailureGuarantee(); readersRetainOldLayoutDuringEdits(); cancelledLayoutNeverPublishesPartialRows(); }
  return failures ? 1 : 0;
}
