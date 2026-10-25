// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#include "sakura/app/DocumentSession.h"
#include <iostream>
#include <random>
#include <stdexcept>
using namespace sakura::core;
namespace {
int failures=0;
void check(bool ok,const char* message) {if(!ok){std::cerr<<message<<'\n';++failures;}}
void compare(const TextBuffer& buffer,SakuraStringView needle,SearchOptions options) {
  SearchEngine search;
  auto matches=search.findAll(buffer,needle,options);
  for(TextOffset cursor=0;cursor<=buffer.length()+2;++cursor) for(bool wrap:{false,true}) {
    options.wrap=wrap;
    std::optional<SearchMatch> expected;
    for(const auto& match:matches) if(match.range.location<cursor) expected=match;
    if(!expected && wrap && !matches.empty()) expected=matches.back();
    auto actual=search.findPrevious(buffer,needle,cursor,options);
    check(actual==expected,"streaming reverse search agrees with full-match reference");
  }
}
}
int main() {
  SearchEngine search;
  TextBuffer buffer(u"ab aa\r\naa 😀\nStraße STRASSE ab");
  compare(buffer,u"aa",{});
  compare(buffer,u"straße",{.caseSensitive=false});
  compare(buffer,u"a",{.wholeWord=true});
  compare(buffer,u"a+|(?=😀)|$",{.regularExpression=true});
  compare(buffer,u"(?<=(a))b",{.regularExpression=true});
  compare(TextBuffer(u"a xxx xx"),u"(\\Gx)|(x+)",{.regularExpression=true});
  compare(TextBuffer(u""),u"$",{.regularExpression=true});
  SearchOptions scoped{.regularExpression=true};scoped.range=TextRange{3,7};
  compare(buffer,u"a+|^|$",scoped);
  SearchOptions crossing{.regularExpression=true};crossing.range=TextRange{1,1};
  auto capture=search.findPrevious(buffer,u"(?<=(a))b",0,crossing);
  check(capture && capture->captures.size()==2 && capture->captures[1]==TextRange{0,1},"reverse captures retain source context outside selected region");
  SakuraString many;
  for(unsigned n=0;n<100005;++n) many.append(u"a ");
  TextBuffer large(many);
  SearchOptions limited;limited.maxMatches=1;
  auto last=search.findPrevious(large,u"a",0,limited);
  check(last && last->range.location==200008,"reverse search has no hundred-thousand-hit array limit");
  limited.regularExpression=true;limited.maxCaptureSlots=2;
  last=search.findPrevious(large,u"(a)",0,limited);
  check(last && last->range.location==200008 && last->captures.size()==2,"reverse capture budget applies to retained candidate, not aggregate discarded hits");
  bool stopped=false;limited.cancelled=[]{return true;};
  try{(void)search.findPrevious(large,u"a",0,limited);}catch(const std::runtime_error&){stopped=true;}
  check(stopped && large.text()==many,"cancel leaves reverse source unchanged");
  std::mt19937 random(0x53414b);
  for(unsigned trial=0;trial<120;++trial) {
    SakuraString text;
    for(unsigned n=0;n<30;++n)text.push_back(u"ab \n"[random()%4]);
    compare(TextBuffer(text),trial%2?u"a+":u"(?=b)|$",{.regularExpression=true});
  }
  sakura::app::DocumentSession session;session.insert(0,u"one two one");
  check(session.findPrevious(u"one",0)->range.location==8,"application reverse entry point");
  bool rejected=false;SearchOptions invalid;invalid.range=TextRange{1,1};
  try{(void)search.findPrevious(TextBuffer(u"😀"),u"",0,invalid);}catch(const std::out_of_range&){rejected=true;}
  check(rejected,"reverse validates region boundaries even for empty needle");
  return failures?1:0;
}
