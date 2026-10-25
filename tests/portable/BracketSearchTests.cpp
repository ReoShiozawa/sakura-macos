// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#include "sakura/core/search/BracketSearch.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <iostream>
#include <limits>
#include <random>
#include <stdexcept>
#include <thread>

namespace {
using namespace sakura::core;
int failures{};
void check(bool okay,const char* label) {
  if (!okay) { if (failures<30) std::cerr<<label<<'\n'; ++failures; }
}
// Independently transcribed from the upstream help's published pair table.
constexpr SakuraStringView opening=u"([{<｢【『「＜≪《（〈｛〔［“〝";
constexpr SakuraStringView closing=u")]}>｣】』」＞≫》）〉｝〕］”〟";
bool boundary(SakuraStringView text,std::size_t at) {
  return at<=text.size() && (!at || at==text.size() ||
      !((text[at-1]==u'\r' && text[at]==u'\n') ||
        (text[at-1]>=0xD800 && text[at-1]<=0xDBFF &&
         text[at]>=0xDC00 && text[at]<=0xDFFF)));
}
std::optional<BracketMatch> reference(SakuraStringView text,std::size_t caret,
    const std::vector<BracketPair>& custom={},bool previous=true) {
  std::vector<BracketPair> table=custom;
  if (table.empty()) for (std::size_t at=0;at<opening.size();++at)
    table.push_back({opening[at],closing[at]});
  std::size_t origin=caret;
  bool fromPrevious=false,forward=false;
  std::optional<BracketPair> pair;
  const auto inspect=[&](std::size_t at) {
    if (at>=text.size()) return false;
    for (const auto entry:table) {
      if (text[at]==entry.opening) { pair=entry;forward=true;origin=at;return true; }
      if (text[at]==entry.closing) { pair=entry;forward=false;origin=at;return true; }
    }
    return false;
  };
  if (!inspect(caret) && previous && caret) {
    auto start=caret;
    while (start && text[start-1]!=u'\n' && text[start-1]!=u'\r') --start;
    if (caret>start && inspect(caret-1)) fromPrevious=true;
  }
  if (!pair) return std::nullopt;
  std::size_t cursor=origin,nesting=1;
  while (forward ? cursor+1<text.size() : cursor>0) {
    if (forward) ++cursor; else --cursor;
    if (text[cursor]==(forward?pair->opening:pair->closing)) ++nesting;
    if (text[cursor]==(forward?pair->closing:pair->opening)) --nesting;
    if (!nesting) return BracketMatch{{origin,1},{cursor,1},fromPrevious,forward,
                                    forward?cursor-origin:origin-cursor};
  }
  return std::nullopt;
}

void upstreamPairsAndSelection() {
  check(opening.size()==18 && closing.size()==18,"reference contains every documented upstream pair");
  const auto defaults=defaultBracketPairs();
  check(defaults.size()==18,"production default pair count matches upstream");
  for (std::size_t at=0;at<18;++at) {
    check(defaults[at]==BracketPair{opening[at],closing[at]},"default pairs/order match independent upstream table");
    SakuraString source{opening[at],u'x',closing[at]};
    TextBuffer buffer(source);
    for (TextOffset caret:{0,1,2,3}) {
      check(findBracketPair(buffer,caret)==reference(source,caret),"every default pair supports both source sides and directions");
      BracketSearchOptions options;options.inspectPrevious=false;
      check(findBracketPair(buffer,caret,options)==reference(source,caret,{},false),"previous-character inspection can be disabled");
    }
  }
  check(!findBracketPair(TextBuffer(u""),0),"empty document is a harmless no-match");
  check(!findBracketPair(TextBuffer(u"abc"),2),"nonbracket caret and predecessor do not navigate");
  check(!findBracketPair(TextBuffer(u"(x)("),3),"unmatched right opener never falls back to the matched bracket on the left");
  check(!findBracketPair(TextBuffer(u"()]"),2),"unmatched right closer never falls back to the matched bracket on the left");
  const TextBuffer nested(u"((x)(y))");
  const std::array<std::pair<TextOffset,TextOffset>,6> expected{{{0,7},{1,3},{3,1},{4,6},{6,4},{7,0}}};
  for (const auto [caret,target]:expected) {
    const auto result=findBracketPair(nested,caret);
    check(result && result->source==TextRange{caret,1} && result->target==TextRange{target,1},"same-type nesting matches at every depth in both directions");
  }
  const auto crossed=findBracketPair(TextBuffer(u"([)]"),0);
  check(crossed && crossed->target.location==2,"upstream nesting ignores other bracket types instead of inventing mixed-stack semantics");
  const auto comment=findBracketPair(TextBuffer(u"( // )\n)"),0);
  check(comment && comment->target.location==5,"comments are raw bracket-search text as in upstream command");
  const auto quoted=findBracketPair(TextBuffer(u"(\")\")"),0);
  check(quoted && quoted->target.location==2,"quoted brackets are not silently filtered out");
}

void unicodeBoundariesAndWindows() {
  for (const std::size_t count:{std::size_t{8190},std::size_t{8191},std::size_t{8192},std::size_t{16383}}) {
    SakuraString text(count,u' ');
    text+=u"(桜😀\r\n";
    text.append(20000,u'x');
    text+=u"(inner)終)";
    TextBuffer buffer(text);
    const auto retained=buffer;
    for (const auto caret:{static_cast<TextOffset>(count),static_cast<TextOffset>(count+1),
                           static_cast<TextOffset>(text.size()-1),static_cast<TextOffset>(text.size())}) {
      BracketSearchStatistics statistics;
      BracketSearchOptions options;options.statistics=&statistics;
      const auto match=findBracketPair(buffer,caret,options);
      check(match==reference(text,caret),"window-crossing forward/reverse matches retain absolute UTF-16 positions");
      check(match && statistics.scannedCodeUnits==match->scannedCodeUnits &&
            statistics.peakChunkCodeUnits<=8192 && statistics.chunkLoads>=3,
            "bounded windows and examined-unit statistics remain valid across lines and supplementary characters");
    }
    check(buffer.sharesStorageWith(retained) && buffer.revision()==retained.revision(),"bracket search never changes shared source storage/revision");
  }
  const SakuraString broken{u'(',0xD800,u'x',0xDC00,u'\r',u'\n',u')'};
  check(findBracketPair(TextBuffer(broken),0)==reference(broken,0),"unpaired surrogate units are ordinary nonbracket text");
  const SakuraString embedded{u'(',0,u')'};
  check(findBracketPair(TextBuffer(embedded),0)==reference(embedded,0),"embedded NUL does not terminate scanning");
  for (const auto caret:{TextOffset{2},TextOffset{4},TextOffset{100}}) {
    bool rejected=false;
    try { (void)findBracketPair(TextBuffer(u"(😀\r\n)"),caret); }
    catch (const std::out_of_range&) { rejected=true; }
    check(rejected,"caret inside a surrogate, CRLF or outside the source is rejected");
  }
  check(!findBracketPair(TextBuffer(u"()\r\n"),4),"empty final logical line does not borrow a bracket from the preceding line");
}

void configurationAndFailures() {
  BracketSearchOptions custom;
  custom.pairs={{u'«',u'»'},{u'「',u'」'}};
  const TextBuffer source(u"«a«b»c» ()");
  check(findBracketPair(source,0,custom)==reference(u"«a«b»c» ()",0,custom.pairs),"custom pair configuration supports independent nesting");
  check(!findBracketPair(source,8,custom),"custom configuration replaces rather than silently extends the default table");
  for (const std::vector<BracketPair>& invalid : {
        std::vector<BracketPair>{{u'x',u'x'}}, {{u'(',u')'},{u')',u']'}},
        {{u'\r',u')'}}, {{u'(',u'\n'}}, {{0xD800,u')'}}, {{u'(',0xDC00}}}) {
    BracketSearchOptions options;options.pairs=invalid;
    bool rejected=false;
    try { (void)findBracketPair(source,0,options); }
    catch (const std::invalid_argument&) { rejected=true; }
    check(rejected,"ambiguous/symmetric/surrogate/newline bracket configurations fail explicitly");
  }
  TextBuffer large(SakuraString(u"(")+SakuraString(200000,u'x')+u')');
  const auto retained=large;
  BracketSearchStatistics statistics;
  BracketSearchOptions limited;limited.maxScanCodeUnits=100;limited.statistics=&statistics;
  bool bounded=false;
  try { (void)findBracketPair(large,0,limited); }
  catch (const std::length_error&) { bounded=true; }
  check(bounded && statistics.scannedCodeUnits==100 && statistics.peakChunkCodeUnits<=8192,"scan budget stops incomplete search rather than publishing a false no-match");
  limited.maxScanCodeUnits=1;
  check(findBracketPair(TextBuffer(u"()"),0,limited).has_value(),"adjacent matching bracket fits a one-unit scan budget");
  check(!findBracketPair(TextBuffer(u"(x"),0,limited),"exhausting the document exactly at the budget is a genuine no-match");
  limited.maxScanCodeUnits=0;
  const auto complete=findBracketPair(large,0,limited);
  check(complete && complete->target.location==200001 && statistics.scannedCodeUnits==200001,"zero scan cap means complete unrestricted search");
  for (const bool throwing:{false,true}) {
    unsigned calls=0;
    BracketSearchOptions options;options.statistics=&statistics;
    options.cancelled=[&] {
      if (++calls<6) return false;
      if (throwing) throw std::logic_error("isolated bracket cancellation failure");
      return true;
    };
    bool cancelled=false;
    try { (void)findBracketPair(large,0,options); }
    catch (const std::runtime_error&) { cancelled=true; }
    catch (const std::logic_error&) { cancelled=throwing; }
    check(cancelled && statistics.scannedCodeUnits>0 && statistics.scannedCodeUnits<large.length(),"mid-scan cancellation or throwing callback returns no partial match");
  }
  BracketSearchOptions cancelled;cancelled.cancelled=[]{return true;};
  bool stopped=false;
  try { (void)findBracketPair(large,0,cancelled); } catch (const std::runtime_error&) { stopped=true; }
  check(stopped && large.sharesStorageWith(retained) && large.revision()==retained.revision(),"immediate/late failures preserve source identity and revision");
  bool rejected=false;
  try { (void)findBracketPair(large,std::numeric_limits<TextOffset>::max()); }
  catch (const std::out_of_range&) { rejected=true; }
  check(rejected,"overflowing caret cannot wrap into a valid source range");
}

void randomIndependentReference() {
  std::mt19937 random(0x42524b54);
  std::vector<SakuraString> pieces{u" ",u"a",u"_",u"😀",u"桜",u"\r",u"\n",u"\r\n",u"\u0301",
      SakuraString(1,0),SakuraString(1,0xD800),SakuraString(1,0xDC00)};
  for (std::size_t at=0;at<opening.size();++at) {
    pieces.emplace_back(1,opening[at]);pieces.emplace_back(1,closing[at]);
  }
  unsigned comparisons=0;
  for (unsigned run=0;run<1800;++run) {
    SakuraString text;
    for (unsigned count=0;count<35;++count) text+=pieces[random()%pieces.size()];
    TextBuffer source(text);
    for (std::size_t caret=0;caret<=text.size();++caret) if (boundary(text,caret)) {
      BracketSearchOptions options;options.inspectPrevious=run%2;
      check(findBracketPair(source,caret,options)==reference(text,caret,{},options.inspectPrevious),"random malformed/mixed text agrees with independent simple-string reference");
      ++comparisons;
    }
  }
  check(comparisons>50000,"fixed-seed reference exercises at least fifty thousand valid caret positions");
}

void sharedLifetimeAndParallelReaders() {
  const SakuraString original=SakuraString(u"(")+SakuraString(100000,u'x')+u')';
  TextBuffer live(original);
  const auto retained=live;
  std::atomic<bool> okay{true};
  std::vector<std::thread> readers;
  for (unsigned thread=0;thread<4;++thread) readers.emplace_back([&,snapshot=retained] {
    for (unsigned run=0;run<4;++run) {
      const auto match=findBracketPair(snapshot,run%2?0:snapshot.length());
      if (!match || match->target.location!=(run%2?snapshot.length()-1:0)) okay=false;
    }
  });
  for (unsigned edit=0;edit<150;++edit) live.assign(edit%2?u"new document":u"other😀");
  for (auto& reader:readers) reader.join();
  check(okay && retained.text()==original,"parallel independent snapshots outlive source edits without stale or partial matching");
}
} // namespace

int main() {
  upstreamPairsAndSelection();
  unicodeBoundariesAndWindows();
  configurationAndFailures();
  randomIndependentReference();
  sharedLifetimeAndParallelReaders();
  if (failures) std::cerr<<failures<<" bracket search test(s) failed\n";
  else std::cout<<"All bracket search tests passed\n";
  return failures?1:0;
}
