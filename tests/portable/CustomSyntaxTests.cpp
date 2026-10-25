// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#include "sakura/core/syntax/CustomSyntax.h"
#include <iostream>
using namespace sakura::core;
using S = CustomSyntaxStatus;
int failures = 0;
void check(bool ok, const char* label) { if (!ok) { std::cerr << label << '\n'; ++failures; } }
int main() {
  TextBuffer source(u"Widget x; // Widget\nconst char* s = \"Widget\"; special_42 日本語 Straße");
  auto base = SyntaxHighlighter{}.highlight(source, SyntaxLanguage::cpp);
  CustomSyntaxRules rules{{u"Widget", u"日本語", u"STRASSE"}, {u"special_[0-9]+"}, false};
  check(!validateCustomSyntaxRules(rules), "valid rules accepted");
  auto result = highlightCustomSyntax(source, base, rules);
  check(result.status == S::ok && result.tokens.size() == 4, "keywords regex and Unicode folding");
  for (auto token : result.tokens) {
    for (auto original : base) check(token.range.location >= original.range.location + original.range.length ||
        original.range.location >= token.range.location + token.range.length, "base syntax protected");
    check(source.isEditBoundary(token.range.location) && source.isEditBoundary(token.range.location + token.range.length), "safe token boundaries");
  }
  check(source.text() == u"Widget x; // Widget\nconst char* s = \"Widget\"; special_42 日本語 Straße", "source unchanged");
  auto priority = highlightCustomSyntax(TextBuffer(u"fooBar"), {}, {{}, {u"foo\\w+", u"Bar"}, true});
  check(priority.tokens.size() == 1 && priority.tokens[0].range.length == 6, "first regex wins overlapping ranges");
  auto zero = highlightCustomSyntax(TextBuffer(u"😀\r\nx"), {}, {{}, {u"(?=.)|$"}, true});
  check(zero.status == S::ok && zero.tokens.empty(), "zero-width rules do not create visible tokens");
  check(highlightCustomSyntax(source, base, rules, []{return true;}).status == S::cancelled, "cancellation obeyed");
  check(highlightCustomSyntax(source, base, {{}, {u"["}, true}).status == S::invalidRules, "invalid regex rejected");
  check(validateCustomSyntaxRules({{u"not-a-word"}, {}, true}).has_value(), "keyword punctuation rejected");
  check(validateCustomSyntaxRules({{}, std::vector<SakuraString>(9, u"ok"), true}).has_value(), "pattern count bounded");
  check(validateCustomSyntaxRules({{}, {SakuraString(513, u'a')}, true}).has_value(), "pattern length bounded");
  check(validateCustomSyntaxRules({{SakuraString(129, u'a')}, {}, true}).has_value(), "keyword length bounded");
  TextBuffer huge(SakuraString(kCustomSyntaxTextLimit + 1, u'a'));
  check(highlightCustomSyntax(huge, {}, rules).status == S::tooLarge, "document limit enforced");
  SakuraString repeated;
  for (std::size_t i = 0; i <= kCustomSyntaxMatchLimit; ++i) repeated += u"foo ";
  auto many = highlightCustomSyntax(TextBuffer(repeated), {}, {{u"foo"}, {}, true});
  check(many.status == S::tooManyMatches && many.tokens.empty(), "match limit fails closed without partial result");
  SakuraString expensive(16000, u'a'); expensive += u'!';
  auto timeout = highlightCustomSyntax(TextBuffer(expensive), {}, {{}, {u"(a+)+$"}, true});
  check(timeout.status == S::timedOut && timeout.tokens.empty(), "pathological regex bounded and fails closed");
  std::vector<SyntaxToken> bad{{{0, source.length() + 1}, SyntaxTokenKind::comment}};
  check(highlightCustomSyntax(source, bad, rules).status == S::invalidRules, "invalid base ranges rejected");
  CustomSyntaxRules grouped{{u"First"}, {}, true};
  grouped.additionalGroups.resize(9);
  grouped.additionalGroups[0] = {{u"SECOND"}, {u"rx[0-9]+"}, false};
  grouped.additionalGroups[8].keywords = {u"Tenth"};
  auto colors = highlightCustomSyntax(TextBuffer(u"First second Tenth rx42"), {}, grouped);
  check(colors.status == S::ok && colors.tokens.size() == 4, "all keyword groups evaluated");
  if (colors.tokens.size() == 4) check(colors.tokens[0].keywordGroup == 1 && colors.tokens[1].keywordGroup == 2 &&
      colors.tokens[2].keywordGroup == 10 && colors.tokens[3].keywordGroup == 2, "literal and regex group metadata preserved");
  grouped.keywords = {u"SECOND"};
  auto priorityGroup = highlightCustomSyntax(TextBuffer(u"SECOND"), {}, grouped);
  check(priorityGroup.tokens.size() == 1 && priorityGroup.tokens[0].keywordGroup == 1, "lower keyword group wins duplicate word");
  grouped.keywords = {}; grouped.patterns = {u"Tenth"};
  auto literalPriority = highlightCustomSyntax(TextBuffer(u"Tenth"), {}, grouped);
  check(literalPriority.tokens.size() == 1 && literalPriority.tokens[0].keywordGroup == 10, "literal words precede all regex groups");
  grouped.additionalGroups.resize(10);
  check(validateCustomSyntaxRules(grouped).has_value(), "group count bounded");
  grouped.additionalGroups.resize(9); grouped.patterns.assign(8, u"x");
  check(validateCustomSyntaxRules(grouped).has_value(), "regex quota shared across groups");
  for (std::size_t padding : {8190,8191,8192,16383}) {
    SakuraString text(padding,u' ');
    text += u"𐐀name Straße\r\n日本語 foo\u0301 ";
    text += SakuraString(10000,u'x')+u" Widget";
    TextBuffer buffer(text);
    const auto retained=buffer;
    CustomSyntaxRules streamed{{u"𐐨NAME",u"STRASSE",u"日本語",u"foo\u0301",u"Widget"},{},false};
    auto result=highlightCustomSyntax(buffer,{},streamed);
    check(result.status==S::ok && result.tokens.size()==5,"streamed custom words cross UTF-16 windows without splitting code points");
    if (result.tokens.size()==5) {
      const TextRange expected[]{{padding,6},{padding+7,6},{padding+15,3},{padding+19,4},{padding+10025,6}};
      for (std::size_t at=0;at<5;++at)
        check(result.tokens[at].range==expected[at] && result.tokens[at].keywordGroup==1,
            "streamed Unicode words retain exact UTF-16 ranges and keyword groups");
    }
    auto patternOnly=highlightCustomSyntax(buffer,{},{{},{u"Widget"},true});
    check(patternOnly.status==S::ok && patternOnly.tokens.size()==1 &&
          patternOnly.tokens[0].range==TextRange{padding+10025,6},"regex-only custom rules do not require a flattened keyword source");
    check(buffer.sharesStorageWith(retained) && buffer.revision()==retained.revision(),"streamed custom syntax preserves shared source identity/revision");
  }
  return failures ? 1 : 0;
}
