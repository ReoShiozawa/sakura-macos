// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#include "sakura/core/syntax/IndexedSyntax.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <iostream>
#include <random>
#include <stdexcept>
#include <string_view>
#include <thread>

using namespace sakura::core;
using L = SyntaxLanguage;
int failures = 0;
void check(bool okay, const char* message) { if (!okay) { if (failures < 25) std::cerr << message << '\n'; ++failures; } }
bool same(const std::vector<SyntaxToken>& a, const std::vector<SyntaxToken>& b) {
  if (a.size() != b.size()) return false;
  for (std::size_t i=0;i<a.size();++i)
    if (a[i].range.location!=b[i].range.location || a[i].range.length!=b[i].range.length ||
        a[i].kind!=b[i].kind || a[i].keywordGroup!=b[i].keywordGroup) return false;
  return true;
}
SakuraString repeat(SakuraStringView text, std::size_t count) {
  SakuraString result; for (std::size_t i=0;i<count;++i) result+=text; return result;
}
void verify(const IndexedSyntax& index,const TextBuffer& source,L language) {
  auto expected=SyntaxHighlighter{}.highlight(source,language), actual=index.tokens();
  if (!same(expected,actual) && failures<25) {
    auto stats=index.lastUpdate();
    std::cerr<<"profile="<<static_cast<int>(language)<<" source="<<source.length()<<" expected="<<expected.size()
             <<" actual="<<actual.size()<<" parsed="<<stats.parsedUnits<<" reused="<<stats.reusedUnits<<'\n';
    for(std::size_t i=0;i<std::min(expected.size(),actual.size());++i)
      if(!same({expected[i]},{actual[i]})){std::cerr<<"first mismatch token "<<i<<" expected "<<expected[i].range.location<<':'<<expected[i].range.length
          <<" actual "<<actual[i].range.location<<':'<<actual[i].range.length<<'\n';break;}
  }
  check(same(expected,actual),"indexed syntax equals full lexical reference");
  check(index.matchesText(source) && index.tokenCount()==expected.size(),"source identity and token aggregate match");
  auto storage=index.storageStatistics();
  check(storage.valid && storage.height <= 2*std::ceil(std::log2(storage.blocks+1))+1,"persistent syntax tree invariants");
  for(auto start : {TextOffset{0},source.length()/3,source.length()}) {
    TextRange range{start,std::min<TextOffset>(17,source.length()-start)};
    std::vector<SyntaxToken> overlapping;
    for(auto t:expected) if(range.length && t.range.location<range.location+range.length && t.range.location+t.range.length>range.location) overlapping.push_back(t);
    check(same(overlapping,index.tokensIn(range)),"range query returns exact unclipped overlapping tokens");
  }
}
void randomizedModes() {
  std::mt19937 random(312019);
  const std::vector<SakuraString> fragments={u"x",u"\r",u"\n",u"\r\n",u"/*",u"*/",u"\"",u"'",u"`",u"#",u"\\\n",u"R\"x(",u")x\"",
      u"'''",u"<script>",u"</SCRIPT>",u"<!--",u"-->",u"[a](b)",u"$tag$",u"<<EOF\n",u"\nEOF\n",u"key: |\n  x\n",u"桜😀",u""};
  for(int value=0;value<=static_cast<int>(L::rust);++value) {
    auto language=static_cast<L>(value);
    TextBuffer source(repeat(u"int value = 7; // x\r\nname: '桜😀'\n",500));
    IndexedSyntax index; index.update(source,language); verify(index,source,language);
    for(int edit=0;edit<90;++edit) {
      const auto retained=index; const auto old=source;
      auto at=static_cast<TextOffset>(random()%(source.length()+1));
      while(at && !source.isEditBoundary(at)) --at;
      auto end=std::min(source.length(),at+random()%12);
      while(end<source.length() && !source.isEditBoundary(end)) ++end;
      source.replace({at,end-at},fragments[random()%fragments.size()]);
      index.update(source,language); verify(index,source,language);
      if(edit%30==0) {verify(retained,old,language); source.restoreSnapshot(old); index.update(source,language); verify(index,source,language);}
    }
  }
}
void multilineAndLookahead() {
  struct Example {L language; SakuraString source; SakuraString replacement; TextOffset offset;};
  auto padding=repeat(u"plain text\r\n",1500);
  std::vector<Example> examples={
    {L::markdown,u"``"+padding,u"``",2+padding.size()},
    {L::markdown,u"["+padding,u"](target)",1+padding.size()},
    {L::cpp,u"/*"+padding+u"*/\nint x;",u" ",0},
    {L::swift,u"/* outer /*"+padding+u"*/ */\nlet value = 1",u"*/",6000},
    {L::python,u"'''"+padding+u"'''\ndef real(): pass",u"'",3},
    {L::rust,u"r##\""+padding+u"\"##\nfn run(){}",u"#",1},
    {L::shell,u"cat <<'EOF'\n"+padding+u"EOF\necho x",u"x",padding.size()+12},
    {L::yaml,u"description: |\n"+repeat(u"  value\n",2000)+u"next: true",u"x",9000},
    {L::html,u"<SCRIPT\n"+repeat(u" attribute='v'\n",1000)+u">const value = 1;</SCRIPT>",u"x",8000},
    {L::xml,u"<tag\n"+repeat(u" attribute='v'\n",1000)+u">text</tag>",u"x",8000},
    {L::sql,u"$tag$"+padding+u"$tag$\nSELECT 1;",u"$",1},
    {L::csharp,u"var s = @\""+padding+u"\";\nint x;",u"\"",4000},
  };
  for(auto& example:examples) {
    TextBuffer text(example.source); IndexedSyntax index; index.update(text,example.language); verify(index,text,example.language);
    text.replace({example.offset,0},example.replacement); index.update(text,example.language); verify(index,text,example.language);
  }
  // A clipped input window is not EOF. A fake raw-text closing prefix exactly
  // at its edge must request more source, not accept a truncated delimiter.
  TextBuffer html(u"<script>\n"+repeat(u"x\n",32758)+u"xx\n</scriptFake>\nconst value = 1;\n</script>\n"+padding);
  IndexedSyntax index; index.update(html,L::html);
  html.replace({9,1},u"q"); index.update(html,L::html); verify(index,html,L::html);
  check(index.lastUpdate().attempts>1,"long constructs expand the input window rather than treating a chunk edge as EOF");
}
void partialWindowsInEveryMode() {
  for(int value=0;value<=static_cast<int>(L::rust);++value) {
    auto language=static_cast<L>(value);
    TextBuffer source(repeat(u"key = '桜😀'; // comment\r\n",3500));
    IndexedSyntax index; index.update(source,language);
    for(auto target : {TextOffset{0},TextOffset{65000},source.length()}) {
      while(target && !source.isEditBoundary(target)) --target;
      source.replace({target,0},u"\"桜😀\r\n");
      index.update(source,language); verify(index,source,language);
    }
  }
}
void localityAndAtomicCancellation() {
  TextBuffer text(repeat(u"int value = 7; // x\n",10000)); IndexedSyntax index; index.update(text,L::cpp);
  std::size_t coldCalls=0; IndexedSyntax cold;
  cold.update(text,L::cpp,[&]{++coldCalls;return false;});
  for(auto stop : {std::size_t{1},coldCalls/2,coldCalls}) {
    IndexedSyntax cancelledIndex; std::size_t at=0; bool cancelled=false;
    try {cancelledIndex.update(text,L::cpp,[&]{return ++at==stop;});}catch(const std::runtime_error&){cancelled=true;}
    check(cancelled && !cancelledIndex.matchesText(text) && cancelledIndex.tokenCount()==0 && cancelledIndex.storageStatistics().blocks==0,
          "cancelled cold parse never publishes a partial initial index");
  }
  const auto original=index; const auto originalText=text;
  text.replace({10,0},u"x");
  std::size_t calls=0; auto prepared=index;
  prepared.update(text,L::cpp,[&]{++calls;return false;}); verify(prepared,text,L::cpp);
  check(prepared.lastUpdate().parsedUnits<16384 && prepared.lastUpdate().reusedUnits>text.length()-16384,
        "front edit reparses bounded blocks and shares the long suffix");
  check(prepared.lastUpdate().serializedUnits<=65536,"front edit does not serialize the full document");
  for(auto stop : {std::size_t{1},std::size_t{2},std::size_t{3},calls/2,calls}) {
    auto candidate=index; std::size_t at=0; bool cancelled=false;
    try {candidate.update(text,L::cpp,[&]{return ++at==stop;});} catch(const std::runtime_error&){cancelled=true;}
    check(cancelled && candidate.matchesText(originalText) && same(candidate.tokens(),original.tokens()),"cancelled update retains original index atomically");
  }
  auto copied=prepared; auto moved=std::move(copied);
  check(copied.matchesText(text) && same(copied.tokens(),moved.tokens()),"moved-from indexes remain valid immutable snapshots");
  auto unchanged=text; unchanged.restoreSnapshot(text);
  prepared.update(unchanged,L::cpp);
  check(prepared.lastUpdate().parsedUnits==0 && prepared.lastUpdate().reusedUnits==text.length(),"new revision of identical storage reuses all syntax");
  prepared.update(unchanged,L::python); verify(prepared,unchanged,L::python);
  check(prepared.lastUpdate().fullRebuild,"language change rebuilds lexical state");
  bool invalid=false; try{(void)prepared.tokensIn({unchanged.length(),1});}catch(const std::out_of_range&){invalid=true;}
  check(invalid,"query bounds checked before arithmetic overflow");
  std::atomic<bool> okay{true}; std::vector<std::thread> workers;
  for(int i=0;i<4;++i) workers.emplace_back([&]{
    auto local=original; auto input=originalText;
    for(int j=0;j<40;++j){input.replace({0,0},u"x\n");local.update(input,L::cpp);if(!local.matchesText(input)||!local.storageStatistics().valid)okay=false;}
  });
  for(auto& worker:workers)worker.join();
  check(okay && original.matchesText(originalText),"independent incremental updates share immutable trees safely");
  TextBuffer empty; IndexedSyntax emptyIndex; emptyIndex.update(empty,L::cpp); verify(emptyIndex,empty,L::cpp);
  empty.replace({0,0},u"int x;\r\n");emptyIndex.update(empty,L::cpp);verify(emptyIndex,empty,L::cpp);
  empty.replace({0,empty.length()},u"");emptyIndex.update(empty,L::cpp);verify(emptyIndex,empty,L::cpp);
}
int main() {
  randomizedModes(); multilineAndLookahead(); partialWindowsInEveryMode(); localityAndAtomicCancellation();
  return failures ? 1 : 0;
}
