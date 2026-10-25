// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#include "sakura/app/DocumentSession.h"
#include <iostream>
using namespace sakura::core;
int failures = 0;
void check(bool ok, const char* label) { if (!ok) { std::cerr << label << '\n'; ++failures; } }
int main() {
  SearchEngine engine;
  SearchOptions insensitive{.caseSensitive=false, .wrap=false};
  auto matches = engine.findAll(TextBuffer(u"Straße STRASSE straße"), u"strasse", insensitive);
  check(matches.size() == 3, "Unicode full folding matches sharp s");
  if (matches.size() == 3) check(matches[0].range.length == 6 && matches[1].range.length == 7 &&
      matches[2].range.location == 15 && matches[0].captures.empty(), "folded matches retain source offsets and literal semantics");
  check(engine.findAll(TextBuffer(u"Σ σ ς"), u"σ", insensitive).size() == 3, "Greek sigma folds");
  check(engine.findAll(TextBuffer(u"ПРИВЕТ привет"), u"Привет", insensitive).size() == 2, "Cyrillic folds");
  check(engine.findAll(TextBuffer(u"[X] [x]"), u"[x]", insensitive).size() == 2, "literal syntax is not regex syntax");
  check(engine.findAll(TextBuffer(u"😀\r\n𐐀 𐐨"), u"𐐨", insensitive).size() == 2, "supplementary plane case folding");
  SearchOptions word{.caseSensitive=false, .wholeWord=true};
  check(engine.findAll(TextBuffer(u"猫 猫犬 _猫 猫_"), u"猫", word).size() == 1, "Japanese word boundaries not ASCII only");
  check(engine.findAll(TextBuffer(u"café décafé café_"), u"CAFÉ", word).size() == 1, "accented word boundaries");
  check(engine.findAll(TextBuffer(u"e\u0301 e"), u"e", word).size() == 1, "combining mark belongs to word");
  check(engine.findAll(TextBuffer(u"foo² foo"), u"foo", word).size() == 1, "Unicode numeric categories belong to word");
  check(engine.findAll(TextBuffer(u"𐐀foo foo𐐀 foo"), u"foo", word).size() == 1, "supplementary letters belong to word");
  check(engine.findAll(TextBuffer(u"foo\r\nfoo\rfoobar\nfoo"), u"^foo$",
      {.regularExpression=true}).size() == 3, "regex anchors work across CRLF CR and LF");
  check(engine.findAll(TextBuffer(u"foo\nfoo"), u"^foo", {.regularExpression=true, .regexMultiline=false}).size() == 1,
      "document-anchor mode remains available");
  check(engine.findAll(TextBuffer(u"foo\nfoo"), u"\\Afoo", {.regularExpression=true}).size() == 1,
      "explicit document anchor unchanged");
  sakura::app::DocumentSession session;
  session.insert(0, u"Straße STRASSE");
  auto replaced = session.replaceAll(u"strasse", u"$1", insensitive);
  check(replaced.replacements == 2 && session.buffer().text() == u"$1 $1", "literal replacement does not expand captures");
  check(session.undo() && session.buffer().text() == u"Straße STRASSE", "Unicode replace is one undo");
  bool cancelled = false;
  insensitive.cancelled = [] { return true; };
  try { (void)engine.findAll(TextBuffer(u"STRASSE"), u"strasse", insensitive); }
  catch (...) { cancelled = true; }
  check(cancelled, "literal folded search obeys cancellation");
  return failures ? 1 : 0;
}
