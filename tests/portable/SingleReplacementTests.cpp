// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#include "sakura/app/DocumentSession.h"
#include <atomic>
#include <iostream>
#include <limits>
#include <random>
#include <stdexcept>
#include <thread>

namespace {
using namespace sakura::core;
using sakura::app::DocumentSession;
int failures{};
void check(bool okay,const char* message){if(!okay){++failures;std::cerr<<message<<'\n';}}
void randomReferenceAndFallback() {
  std::mt19937 random(702561);
  const SakuraString fragments[]{u"a",u"aa",u"x",u" ",u"\r\n",u"桜",u"😀",u"b",u"A",u"Straße"};
  const SakuraString patterns[]{u"a",u"(a+)",u"(?=(a))",u"(?<=x)(a)",u"\\G(a)",u"$",u"桜",u"😀",u"STRASSE"};
  const SakuraString templates[]{u"X",u"$1",u"$$",u"$&",u"$`",u"$'",u"😀",u"\n",u""};
  for(int run=0;run<700;++run) {
    SakuraString source;for(int i=0;i<20;++i)source+=fragments[random()%std::size(fragments)];
    DocumentSession doc;doc.insert(0,source);doc.markSaved(doc.makeSaveSnapshot().token);
    SearchOptions options;options.regularExpression=run%3!=0;options.wrap=run%2;options.caseSensitive=run%5!=0;
    options.wholeWord=run%7==0;
    if(run%4==0)options.range=TextRange{0,doc.buffer().length()};
    const auto& needle=patterns[random()%std::size(patterns)];const auto& replacement=templates[random()%std::size(templates)];
    auto start=static_cast<TextOffset>(random()%(source.size()+1));while(start && !doc.buffer().isEditBoundary(start))--start;
    auto match=SearchEngine{}.findNext(doc.buffer(),needle,start,options);
    TextRange selection{start,0};
    if(match && run%2==0)selection=match->range;
    const bool exact=match && selection.location==match->range.location && selection.length==match->range.length;
    auto expected=source;
    if(exact) {
      const auto expanded=options.regularExpression ? SearchEngine::expandReplacement(source,*match,replacement) : replacement;
      expected.replace(selection.location,selection.length,expanded);
    }
    auto prepared=DocumentSession::prepareSingleReplacement(doc.editSnapshot(),selection,needle,replacement,options);
    check(prepared.result.valid && doc.buffer().text()==source && !doc.isDirty(),"single preparation does not edit live source/history");
    check(prepared.result.replacements==(exact?1U:0U) && prepared.result.changed==(expected!=source),"exact selection and no-op flags match synchronous reference");
    check(exact ? prepared.selectionAfter.has_value() : prepared.fallbackSelection==(match?std::optional{match->range}:std::nullopt),"nonmatching selection returns navigation only");
    check(doc.commitPreparedReplacement(prepared) && doc.buffer().text()==expected,"prepared single edit equals full-context reference");
    if(exact)check(doc.buffer().isEditBoundary(prepared.selectionAfter->location),"resulting caret never splits surrogate or CRLF");
    if(expected!=source) {
      check(doc.undo() && doc.buffer().text()==source && !doc.isDirty(),"one undo restores the saved original");
      check(doc.redo() && doc.buffer().text()==expected,"one redo restores single replacement");
    }
  }
}
void scopesZeroWidthAndJoins() {
  DocumentSession doc;doc.insert(0,u"OUT aa AFTER");
  SearchOptions options;options.regularExpression=true;options.range=TextRange{4,2};
  auto p=DocumentSession::prepareSingleReplacement(doc.editSnapshot(),{4,2},u"(?<=(OUT ))aa(?= AFTER)",u"<$1>",options);
  check(p.result.resultingRange && p.result.resultingRange->location==4 && p.result.resultingRange->length==6,"single scope expands with replacement length");
  check(doc.commitPreparedReplacement(p) && doc.buffer().text()==u"OUT <OUT > AFTER","lookaround captures retain original context outside scope");
  DocumentSession zero;zero.insert(0,u"aa");options.range.reset();
  auto z=DocumentSession::prepareSingleReplacement(zero.editSnapshot(),{0,0},u"(?=a)|$",u"X",options);
  check(z.nextSearchStart==2 && zero.commitPreparedReplacement(z) && zero.buffer().text()==u"Xaa","zero-width insertion advances past original character");
  options.wrap=false;
  auto end=DocumentSession::prepareSingleReplacement(zero.editSnapshot(),{3,0},u"$",u"",options);
  check(!end.result.changed && !end.nextSearchStart && zero.commitPreparedReplacement(end),"no-wrap empty replacement at EOF terminates navigation");
  DocumentSession newline;newline.insert(0,u"\n");
  auto joined=DocumentSession::prepareSingleReplacement(newline.editSnapshot(),{0,0},u"\\A",u"\r",options);
  check(joined.selectionAfter->location==2 && joined.nextSearchStart==2 && newline.commitPreparedReplacement(joined),"new CRLF join advances exactly once across original LF");
  DocumentSession scoped;scoped.insert(0,u"\rX\n");options.range=TextRange{1,1};options.regularExpression=false;
  auto boundary=DocumentSession::prepareSingleReplacement(scoped.editSnapshot(),{1,1},u"X",u"",options);
  check(boundary.result.resultingRange->location==1 && boundary.result.resultingRange->length==0 &&
        !boundary.nextSearchStart && boundary.selectionAfter->location==2 && scoped.commitPreparedReplacement(boundary),
        "scope endpoint joining CRLF invalidates follow-up without widening scope");
  DocumentSession pair;pair.insert(0,SakuraString(1,static_cast<SakuraChar>(0xdc00)));
  options.range.reset();options.regularExpression=true;
  auto surrogate=DocumentSession::prepareSingleReplacement(pair.editSnapshot(),{0,0},u"\\A",SakuraString(1,static_cast<SakuraChar>(0xd800)),options);
  check(surrogate.selectionAfter->location==2 && surrogate.nextSearchStart==2 && pair.commitPreparedReplacement(surrogate),"new surrogate join preserves edit boundary and zero-width progress");
}
void limitsNoOpsAndVersions() {
  DocumentSession doc;doc.insert(0,u"cat cat");const auto saved=doc.makeSaveSnapshot().token;doc.markSaved(saved);
  doc.insert(0,u"!");doc.undo();const auto revision=doc.buffer().revision();
  auto noop=DocumentSession::prepareSingleReplacement(doc.editSnapshot(),{0,3},u"cat",u"cat");
  check(!noop.result.changed && doc.commitPreparedReplacement(noop) && !doc.isDirty() && doc.canRedo() && doc.buffer().revision()==revision,"no-op preserves redo, saved state and revision");
  auto stale=DocumentSession::prepareSingleReplacement(doc.editSnapshot(),{0,0},u"cat",u"dog");
  doc.insert(0,u"!");doc.undo();
  check(!doc.commitPreparedReplacement(stale),"navigation-only fallback also rejects edit/undo generation changes");
  auto other=DocumentSession::prepareSingleReplacement(doc.editSnapshot(),{0,3},u"cat",u"dog");
  DocumentSession foreign;foreign.insert(0,u"cat cat");
  check(!foreign.commitPreparedReplacement(other) && !doc.commitPreparedReplacement(other),"foreign or reused prepared single plan rejected");
  SearchOptions cap;cap.maxReplacementCodeUnits=1;
  auto small=DocumentSession::prepareSingleReplacement(doc.editSnapshot(),{0,3},u"cat",u"x",cap);
  check(doc.commitPreparedReplacement(small) && doc.buffer().text()==u"x cat","small single replacement allowed when original/final document is larger than output cap");
  bool limited=false;try{(void)DocumentSession::prepareSingleReplacement(doc.editSnapshot(),{0,1},u"x",u"xx",cap);}catch(const std::length_error&){limited=true;}
  check(limited && doc.buffer().text()==u"x cat","output cap failure leaves live source untouched");
  cap.maxReplacementMatches=0;limited=false;
  try{(void)DocumentSession::prepareSingleReplacement(doc.editSnapshot(),{0,1},u"x",u"y",cap);}catch(const std::length_error&){limited=true;}
  check(limited && doc.buffer().text()==u"x cat","explicit zero replacement-count cap also forbids one single edit");
  SearchOptions invalid;invalid.regularExpression=true;
  auto bad=DocumentSession::prepareSingleReplacement(doc.editSnapshot(),{0,1},u"(",u"x",invalid);
  check(!bad.result.valid && !doc.commitPreparedReplacement(bad),"invalid regex never produces a committable plan");
  for(TextRange range: {TextRange{999,0},TextRange{0,999}}) {
    bool rejected=false;try{(void)DocumentSession::prepareSingleReplacement(doc.editSnapshot(),range,u"x",u"y");}catch(const std::invalid_argument&){rejected=true;}
    check(rejected,"invalid selection bounds rejected before preparation");
  }
  doc.markSaved(doc.makeSaveSnapshot().token);
  auto pending=DocumentSession::prepareSingleReplacement(doc.editSnapshot(),{0,1},u"x",u"y");
  auto reload=doc.makeSaveSnapshot();check(doc.load(reload.encoded.bytes).ok() && !doc.commitPreparedReplacement(pending),"same-content reload rejects a prepared single edit");
  auto metadata=DocumentSession::prepareSingleReplacement(doc.editSnapshot(),{0,1},u"x",u"y");
  doc.setEncodingState({TextEncoding::utf16BigEndian,true});
  check(doc.commitPreparedReplacement(metadata) && doc.encodingState()==EncodingState{TextEncoding::utf16BigEndian,true},"commit keeps current encoding metadata");
  DocumentSession late;late.insert(0,u"cat");const auto lateSaved=late.makeSaveSnapshot().token;late.markSaved(lateSaved);
  auto changed=DocumentSession::prepareSingleReplacement(late.editSnapshot(),{0,3},u"cat",u"dog");
  check(late.commitPreparedReplacement(changed),"late-save single fixture commits");late.markSaved(lateSaved);
  check(late.isDirty() && late.undo() && !late.isDirty(),"late completion of an old save cannot mark new single-replacement text saved");
}
void cancellationAndConcurrency() {
  DocumentSession doc;doc.insert(0,SakuraString(90000,u'a'));
  SearchOptions options;options.regularExpression=true;
  std::size_t calls=0;options.cancelled=[&]{++calls;return false;};
  (void)DocumentSession::prepareSingleReplacement(doc.editSnapshot(),{0,90000},u"(a+)",u"$1X",options);
  for(auto stop: {std::size_t{1},std::size_t{2},calls/2,calls}) {
    std::size_t at=0;options.cancelled=[&]{return ++at==stop;};bool cancelled=false;
    try{(void)DocumentSession::prepareSingleReplacement(doc.editSnapshot(),{0,90000},u"(a+)",u"$1X",options);}catch(const std::runtime_error&){cancelled=true;}
    check(cancelled && doc.buffer().length()==90000,"cancellation during match/expansion/edit preparation publishes nothing");
  }
  const auto snapshot=doc.editSnapshot();std::atomic<bool> okay{true};std::vector<std::thread> workers;
  for(int i=0;i<4;++i)workers.emplace_back([&]{
    for(int n=0;n<12;++n){auto p=DocumentSession::prepareSingleReplacement(snapshot,{0,1},u"a",u"b");if(!p.result.changed||p.edit.resultingBuffer().characterAt(0)!=u'b')okay=false;}
  });
  for(int n=0;n<30;++n)doc.insert(0,u"x");for(auto& worker:workers)worker.join();
  check(okay && doc.buffer().characterAt(0)==u'x',"parallel preparation uses immutable snapshot, not live document");
}

void expansionReadsSharedOriginalRanges() {
  SakuraString source(8190,u'x');
  source += u"HEAD aaa TAIL";
  source.append(90000,u'b');
  source += u"\r\n😀";
  TextBuffer live(source), frozen(live);
  const TextRange range{8195,3};
  SearchMatch match{range,{range,TextRange{8190,5},range,TextRange{8198,5},std::nullopt}};
  const std::pair<SakuraString,SakuraString> cases[]{
    {u"$1:$2:$3:$4",u"HEAD :aaa: TAIL:"},
    {u"$0/$&",u"aaa/aaa"},
    {u"$$ $9 $12",u"$ $9 HEAD 2"},
    {u"$`",source.substr(0,range.location)},
    {u"$'",source.substr(range.location+range.length)},
    {u"$",u"$"}, {u"$x",u"$x"}, {u"",u""},
  };
  live.assign(u"new live document");
  for (const auto& [replacement,expected] : cases) {
    const auto viewResult = SearchEngine::expandReplacement(SakuraStringView(source),match,replacement);
    check(viewResult == expected, "expansion reference has explicit capture/prefix/suffix semantics");
    check(SearchEngine::expandReplacement(frozen,match,replacement) == expected,
        "shared-root expansion reads only original referenced ranges across chunks");
    check(SearchEngine::expandReplacement(frozen,match,replacement,expected.size()) == expected,
        "shared expansion accepts the exact output budget, including zero");
    if (!expected.empty()) {
      bool limited = false;
      try { (void)SearchEngine::expandReplacement(frozen,match,replacement,expected.size()-1); }
      catch (const std::length_error&) { limited = true; }
      check(limited, "shared expansion rejects output-budget overflow before publication");
    }
  }
  SearchMatch overflow{{std::numeric_limits<TextOffset>::max(),2},{}};
  for (const auto& replacement : {SakuraString(u"$'"),SakuraString(u"$&"),SakuraString(u"$`")}) {
    bool rejected = false;
    try { (void)SearchEngine::expandReplacement(frozen,overflow,replacement); }
    catch (const std::out_of_range&) { rejected = true; }
    check(rejected, "forged overflowing capture/match cannot wrap into a valid source range");
  }
  unsigned calls=0; bool stopped=false;
  try { (void)SearchEngine::expandReplacement(frozen,match,u"$'",std::nullopt,[&]{ return ++calls==3; }); }
  catch (const std::runtime_error&) { stopped=true; }
  check(stopped && calls==3 && frozen.text()==source && live.text()==u"new live document",
      "cancellation partway through shared capture expansion preserves every source");
  std::atomic<bool> okay{true}; std::vector<std::thread> workers;
  for (unsigned worker=0;worker<4;++worker) workers.emplace_back([&,snapshot=frozen] {
    for (unsigned run=0;run<12;++run) for (const auto& [replacement,expected] : cases)
      if (SearchEngine::expandReplacement(snapshot,match,replacement) != expected) okay=false;
  });
  for (auto& worker:workers) worker.join();
  check(okay, "independent readers expand captures concurrently from shared immutable roots");
}
}
int main(){randomReferenceAndFallback();scopesZeroWidthAndJoins();limitsNoOpsAndVersions();cancellationAndConcurrency();expansionReadsSharedOriginalRanges();return failures?1:0;}
