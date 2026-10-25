// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#include "sakura/app/DocumentSession.h"
#include <iostream>
using namespace sakura::core;
int failures = 0;
void check(bool ok, const char* label) { if (!ok) { std::cerr << label << '\n'; ++failures; } }
int main() {
  SearchEngine search;
  TextBuffer source(u"OUT aa aa OUT aa");
  SearchOptions selected; selected.range = TextRange{4, 5};
  auto matches = search.findAll(source, u"aa", selected);
  check(matches.size() == 2 && matches[0].range.location == 4 && matches[1].range.location == 7, "literal region bounds");
  check(search.findNext(source, u"aa", 0, selected)->range.location == 4, "cursor clamped to region");
  check(search.findNext(source, u"aa", 9, selected)->range.location == 4, "wrap stays in region");
  selected.wrap = false;
  check(!search.findNext(source, u"aa", 9, selected), "no wrap outside region");
  selected.regularExpression = true;
  auto greedy = search.findNext(source, u".+", 4, selected);
  check(greedy && greedy->range == TextRange{4, 5}, "greedy regex stops at selected boundary");
  check(search.findAll(source, u"^aa", selected).empty(), "selection does not invent line start");
  check(search.findAll(source, u"aa$", selected).empty(), "selection does not invent line end");
  SearchOptions context{.regularExpression=true}; context.range = TextRange{4, 2};
  auto look = search.findNext(TextBuffer(u"OUT aa AFTER"), u"(?<=(OUT ))aa(?= AFTER)", 4, context);
  check(look && look->captures.size() == 2 && look->captures[1] == TextRange{0, 4}, "lookaround and captures retain outside source context");
  sakura::app::DocumentSession session;
  session.insert(0, u"OUT aa AFTER");
  auto changed = session.replaceAll(u"(?<=(OUT ))aa(?= AFTER)", u"<$1>", context);
  check(changed.replacements == 1 && changed.resultingRange == TextRange{4, 6} && session.buffer().text() == u"OUT <OUT > AFTER", "scoped replacement retains context and outside text");
  check(session.undo() && session.buffer().text() == u"OUT aa AFTER", "scoped replacement is one undo");
  check(session.redo() && session.buffer().text() == u"OUT <OUT > AFTER", "scoped replacement redo");
  SearchOptions caseless{.caseSensitive=false}; caseless.range = TextRange{7, 7};
  auto folded = search.findAll(TextBuffer(u"Straße STRASSE"), u"straße", caseless);
  check(folded.size() == 1 && folded[0].range == TextRange{7, 7}, "Unicode folding respects region");
  SearchOptions word{.wholeWord=true}; word.range = TextRange{1, 3};
  check(search.findAll(TextBuffer(u"scatters"), u"cat", word).empty(), "word boundaries use full context");
  SearchOptions zero{.regularExpression=true}; zero.range = TextRange{1, 1};
  auto empty = search.findAll(TextBuffer(u"aa"), u"(?=a)|(?<=a)", zero);
  check(empty.size() == 2 && empty[0].range.location == 1 && empty[1].range.location == 2, "zero width includes region endpoint once");
  for (auto range : {TextRange{1, 1}, TextRange{0, 1}, TextRange{99, 1}}) {
    bool rejected = false;
    SearchOptions invalid; invalid.range = range;
    try { (void)search.findAll(TextBuffer(u"😀\r\nX"), u"x", invalid); } catch (...) { rejected = true; }
    check(rejected, "invalid/surrogate-splitting region rejected");
  }
  bool crlf = false; selected.range = TextRange{0, 2};
  try { (void)search.findAll(TextBuffer(u"a\r\nb"), u"a", selected); } catch (...) { crlf = true; }
  check(crlf, "CRLF-splitting region rejected");
  sakura::app::DocumentSession limited; limited.insert(0, u"aa");
  SearchOptions budget{.regularExpression=true}; budget.maxCaptureSlots = 3;
  bool captureLimit = false;
  try { (void)limited.replaceAll(u"(a)", u"$1X", budget); } catch (...) { captureLimit = true; }
  check(captureLimit && limited.buffer().text() == u"aa", "capture budget fails before edits");
  budget.captureGroups = false;
  auto rangesOnly = search.findAll(TextBuffer(u"aa"), u"(a)", budget);
  check(rangesOnly.size() == 2 && rangesOnly[0].captures.empty(), "range-only search avoids capture allocation");
  budget.maxCaptureSlots = 0;
  check(limited.replaceAll(u"(a)", u"X", budget).replacements == 2 && limited.buffer().text() == u"XX", "constant regex replacement needs no captures");
  limited.undo(); budget.regularExpression = false; budget.maxReplacementMatches = 1;
  bool countLimit = false;
  try { (void)limited.replaceAll(u"a", u"b", budget); } catch (...) { countLimit = true; }
  check(countLimit && limited.buffer().text() == u"aa", "replacement count limit prevents partial edits");
  return failures ? 1 : 0;
}
