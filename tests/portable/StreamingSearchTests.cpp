// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#include "sakura/core/search/SearchEngine.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <iomanip>
#include <iostream>
#include <limits>
#include <memory>
#include <random>
#include <stdexcept>
#include <string_view>
#include <type_traits>
#include <vector>
#if defined(__APPLE__) || defined(__unix__)
#include <sys/resource.h>
#endif
#include <unicode/uchar.h>
#include <unicode/uregex.h>
#include <unicode/utf16.h>
#if defined(__APPLE__)
#include <mach/mach.h>
#endif

namespace {
using namespace sakura::core;
int failures{};
std::uint64_t comparisons{};
std::uint64_t valueComparisons{}, matchingTimeOutRefusals{};
void check(bool okay, const char* message) {
  if (!okay) { ++failures; std::cerr << message << '\n'; }
}
bool boundary(SakuraStringView source, std::size_t at) {
  if (at > source.size()) return false;
  return !at || at == source.size() ||
      !((source[at-1] == u'\r' && source[at] == u'\n') ||
        (U16_IS_LEAD(source[at-1]) && U16_IS_TRAIL(source[at])));
}
bool word(UChar32 value) {
  const auto kind = u_charType(value);
  return u_isalnum(value) || u_hasBinaryProperty(value,UCHAR_ALPHABETIC) ||
      kind == U_NON_SPACING_MARK || kind == U_COMBINING_SPACING_MARK ||
      kind == U_ENCLOSING_MARK || kind == U_CONNECTOR_PUNCTUATION ||
      kind == U_LETTER_NUMBER || kind == U_OTHER_NUMBER ||
      u_hasBinaryProperty(value,UCHAR_JOIN_CONTROL);
}
bool wholeWord(SakuraStringView source, std::size_t begin, std::size_t end) {
  UChar32 before = U_SENTINEL, after = U_SENTINEL;
  const auto* data = reinterpret_cast<const UChar*>(source.data());
  auto previous = static_cast<std::int64_t>(begin), next = static_cast<std::int64_t>(end);
  if (begin) U16_PREV(data,0,previous,before);
  if (end < source.size()) U16_NEXT(data,next,static_cast<std::int64_t>(source.size()),after);
  return !word(before) && !word(after);
}

// Independent contiguous reference: never uses BufferUText, TextBuffer traversal,
// the production prefix table, or the production boundary/whole-word helpers.
// ICU sees one uregex_setText UTF-16 string, as it did before the streaming change.
class Reference {
 public:
  Reference(const SakuraString& source, SakuraStringView pattern, SearchOptions options)
      : source_(source), pattern_(pattern), options_(std::move(options)) {
    region_ = options_.range.value_or(TextRange{0,source.size()});
    if (region_.location > source.size() || region_.length > source.size()-region_.location ||
        !boundary(source,region_.location) || !boundary(source,region_.location+region_.length))
      throw std::out_of_range("invalid reference search range");
    if (options_.regularExpression || !options_.caseSensitive) {
      UErrorCode status = U_ZERO_ERROR;
      const auto flags = (options_.caseSensitive ? 0 : UREGEX_CASE_INSENSITIVE) |
          (options_.regularExpression ? (options_.regexMultiline ? UREGEX_MULTILINE : 0) : UREGEX_LITERAL);
      regex_.reset(uregex_open(reinterpret_cast<const UChar*>(pattern.data()),
          static_cast<std::int32_t>(pattern.size()),flags,nullptr,&status));
      if (U_FAILURE(status)) { regex_.reset(); return; }
      uregex_setText(regex_.get(),reinterpret_cast<const UChar*>(source.data()),
          static_cast<std::int32_t>(source.size()),&status);
      uregex_setTimeLimit(regex_.get(),std::max(1,options_.regexTimeLimitMilliseconds),&status);
      statusCheck(status);
    }
  }
  std::vector<SearchMatch> all(bool obeyMatchCap = true) {
    std::vector<SearchMatch> result;
    if (pattern_.empty()) return result;
    std::size_t at = region_.location;
    const auto end = static_cast<std::size_t>(region_.location+region_.length);
    while (at <= end) {
      auto found = find(at,end);
      if (!found) break;
      result.push_back(std::move(*found));
      if (obeyMatchCap && options_.maxMatches && result.size() >= options_.maxMatches) break;
      at = result.back().range.location+result.back().range.length;
      if (!result.back().range.length) {
        if (at == end) break;
        do { ++at; } while (at < end && !boundary(source_,at));
      }
    }
    return result;
  }
  std::optional<SearchMatch> next(TextOffset from) {
    if (pattern_.empty()) return std::nullopt;
    const auto begin = static_cast<std::size_t>(region_.location);
    const auto end = static_cast<std::size_t>(region_.location+region_.length);
    const auto at = static_cast<std::size_t>(std::clamp<TextOffset>(from,begin,end));
    if (auto found = find(at,end)) return found;
    return options_.wrap && at != begin ? find(begin,at) : std::nullopt;
  }
  std::optional<SearchMatch> previous(TextOffset cursor) {
    const auto matches = all(false);
    std::optional<SearchMatch> result;
    for (const auto& match : matches)
      if (match.range.location < cursor) result = match;
    if (!result && options_.wrap && !matches.empty()) result = matches.back();
    return result;
  }
 private:
  static void statusCheck(UErrorCode status) {
    if (U_FAILURE(status))
      throw std::runtime_error(std::string("contiguous reference ICU failure: ")+u_errorName(status));
  }
  std::optional<SearchMatch> find(std::size_t begin, std::size_t end) {
    if (options_.regularExpression || !options_.caseSensitive) {
      if (!regex_) return std::nullopt;
      UErrorCode status = U_ZERO_ERROR;
      uregex_useTransparentBounds(regex_.get(),true,&status);
      uregex_useAnchoringBounds(regex_.get(),false,&status);
      uregex_setRegionAndStart(regex_.get(),region_.location,region_.location+region_.length,begin,&status);
      UBool found = uregex_findNext(regex_.get(),&status);
      while (found && U_SUCCESS(status)) {
        const auto start = uregex_start(regex_.get(),0,&status);
        const auto limit = uregex_end(regex_.get(),0,&status);
        statusCheck(status);
        if (static_cast<std::size_t>(limit) > end) return std::nullopt;
        if (boundary(source_,start) && boundary(source_,limit) &&
            (!options_.wholeWord || wholeWord(source_,start,limit))) {
          SearchMatch match{{static_cast<TextOffset>(start),static_cast<TextOffset>(limit-start)},{}};
          if (options_.regularExpression && options_.captureGroups) {
            const auto count = uregex_groupCount(regex_.get(),&status);
            for (std::int32_t group=0; group<=count; ++group) {
              const auto first = uregex_start(regex_.get(),group,&status);
              const auto last = uregex_end(regex_.get(),group,&status);
              if (first < 0) match.captures.push_back(std::nullopt);
              else match.captures.push_back(TextRange{static_cast<TextOffset>(first),static_cast<TextOffset>(last-first)});
            }
          }
          statusCheck(status);
          return match;
        }
        found = uregex_findNext(regex_.get(),&status);
      }
      statusCheck(status);
      return std::nullopt;
    }
    if (pattern_.size() > end-begin) return std::nullopt;
    // Deliberately simple raw UTF-16 scanning, independent of KMP/chunks.
    for (std::size_t at=begin; at<=end-pattern_.size(); ++at) {
      if (source_.compare(at,pattern_.size(),pattern_) == 0 &&
          boundary(source_,at) && boundary(source_,at+pattern_.size()) &&
          (!options_.wholeWord || wholeWord(source_,at,at+pattern_.size())))
        return SearchMatch{{at,pattern_.size()},{}};
    }
    return std::nullopt;
  }
  const SakuraString& source_;
  SakuraStringView pattern_;
  SearchOptions options_;
  TextRange region_{};
  std::unique_ptr<URegularExpression,decltype(&uregex_close)> regex_{nullptr,uregex_close};
};

void dumpUnits(SakuraStringView text) {
  std::cerr << '[';
  const auto limit = std::min<std::size_t>(text.size(),120);
  for (std::size_t index=0; index<limit; ++index)
    std::cerr << (index ? " " : "") << std::hex << static_cast<unsigned>(text[index]);
  std::cerr << std::dec << (text.size()>limit ? " ...]" : "]");
}
void mismatch(const char* label, const char* operation, const SakuraString& source,
              SakuraStringView pattern, const SearchOptions& options, TextOffset position) {
  ++failures;
  if (failures > 20) return;
  std::cerr << label << ' ' << operation << " sourceUnits=" << source.size()
            << " position=" << position << " regex=" << options.regularExpression
            << " sensitive=" << options.caseSensitive << " word=" << options.wholeWord
            << " wrap=" << options.wrap << " pattern=";
  dumpUnits(pattern);
  std::cerr << " source="; dumpUnits(source); std::cerr << '\n';
}
template<class Result> struct Outcome {
  // The outer optional records successful execution. For navigation the stored
  // Result is itself optional, preserving success-with-no-match distinctly.
  std::optional<Result> value;
  bool timeOut{};
};
template<class Operation> auto outcome(Operation&& operation) {
  Outcome<std::invoke_result_t<Operation>> result;
  try { result.value.emplace(operation()); }
  catch (const std::runtime_error& error) {
    // Only the named ICU time-limit refusal is comparable as a resource
    // outcome. Cancellation, bounds, provider and other ICU failures still fail.
    if (!std::string_view(error.what()).ends_with(": U_REGEX_TIME_OUT")) throw;
    result.timeOut=true;
  }
  return result;
}
template<class Result> bool equalOutcome(const Outcome<Result>& actual, const Outcome<Result>& reference) {
  if (actual.timeOut || reference.timeOut) {
    if (actual.timeOut && reference.timeOut) { ++matchingTimeOutRefusals; return true; }
    std::cerr << "resource mismatch: actualTimeOut=" << actual.timeOut
              << " referenceTimeOut=" << reference.timeOut << '\n';
    return false;
  }
  if (actual.value == reference.value) { ++valueComparisons; return true; }
  return false;
}
void compare(const SakuraString& source, SakuraStringView pattern, SearchOptions options,
             const char* label, std::vector<TextOffset> positions = {}) {
  const TextBuffer buffer(source);
  const auto retained = buffer;
  if (positions.empty()) positions = {0,1,source.size()/3,source.size()/2,
      source.empty()?0:source.size()-1,source.size(),source.size()+3};
  const char* operation="reference all constructor";
  TextOffset position=0;
  try {
    Reference allReference(source,pattern,options);
    ++comparisons;
    operation="actual all";
    const auto actualAll=outcome([&]{ return SearchEngine{}.findAll(buffer,pattern,options); });
    operation="reference all";
    const auto referenceAll=outcome([&]{ return allReference.all(); });
    if (!equalOutcome(actualAll,referenceAll)) mismatch(label,"all",source,pattern,options,0);
    for (const bool wrap : {false,true}) {
      options.wrap = wrap;
      for (const auto requested : positions) {
        position=requested;
        operation="reference next constructor";
        Reference nextReference(source,pattern,options);
        ++comparisons;
        operation="actual next";
        const auto actualNext=outcome([&]{ return SearchEngine{}.findNext(buffer,pattern,position,options); });
        operation="reference next";
        const auto referenceNext=outcome([&]{ return nextReference.next(position); });
        if (!equalOutcome(actualNext,referenceNext)) mismatch(label,"next",source,pattern,options,position);
        operation="reference previous constructor";
        Reference previousReference(source,pattern,options);
        ++comparisons;
        operation="actual previous";
        const auto actualPrevious=outcome([&]{ return SearchEngine{}.findPrevious(buffer,pattern,position,options); });
        operation="reference previous";
        const auto referencePrevious=outcome([&]{ return previousReference.previous(position); });
        if (!equalOutcome(actualPrevious,referencePrevious)) mismatch(label,"previous",source,pattern,options,position);
      }
    }
  } catch (const std::exception& error) {
    mismatch(label,operation,source,pattern,options,position);
    std::cerr << "comparison exception: " << error.what() << '\n';
    throw;
  }
  check(buffer.sharesStorageWith(retained) && buffer.revision() == retained.revision(),
        "search leaves immutable source/revision unchanged");
}

void basicSemantics() {
  const SakuraString source = u"ab aa\r\naa 😀 𐐀 𐐨\nStraße STRASSE Σ σ ς\r猫 猫犬 _猫 café cafe\u0301\nfoo² foo\u200d foo\n";
  const SakuraString literalPatterns[]{u"aa",u"😀",u"𐐀",u"strasse",u"Σ",u"猫",u"foo",u"e",u"\r",u"\n",u"\r\n",u""};
  for (const auto& pattern : literalPatterns)
    for (const bool sensitive : {false,true}) for (const bool whole : {false,true}) {
      SearchOptions options; options.caseSensitive=sensitive; options.wholeWord=whole;
      compare(source,pattern,options,"literal Unicode");
    }
  const SakuraString patterns[]{u"(a+)|(😀)",u"(?=(a))|$",u"(?<=(a))b",u"\\G(a)|a+",
      u"\\A|\\z|^|$",u"\\R",u"\\X",u"(Straße)|(strasse)",u"(?<=猫 )猫(?=犬)",
      u"(a)?(b)",u"foo\\b",u"(\\w+)\\s+\\1",u"("};
  for (const auto& pattern : patterns)
    for (const bool sensitive : {false,true}) for (const bool multiline : {false,true}) {
      SearchOptions options; options.regularExpression=true; options.caseSensitive=sensitive;
      options.regexMultiline=multiline;
      compare(source,pattern,options,"regex context");
      options.captureGroups=false; options.maxMatches=3;
      compare(source,pattern,options,"regex no capture cap");
    }
  compare(u"",u"$",{.regularExpression=true},"empty source anchor");
  compare(u"",u"a",{},"empty source literal");
  SearchOptions scoped; scoped.regularExpression=true; scoped.range=TextRange{4,2};
  compare(u"OUT aa AFTER",u"(?<=(OUT ))aa(?=( AFTER))",scoped,"captures outside region");
  compare(u"OUT aa AFTER",u"\\A|\\z|^|$|a+",scoped,"scoped true anchors");
  scoped.range=TextRange{4,0};
  compare(u"OUT aa AFTER",u"(?=aa)|$",scoped,"zero-length selected region");
}

void chunkBoundariesAndLongPatterns() {
  for (const std::size_t padding : {8190,8191,8192,8193,16383}) {
    SakuraString source(padding,u'.');
    source += u"before\r\nStraße 😀 👩🏽‍💻 𐐀\r\nA\u0301e aaaa ab ab\nEND";
    std::vector<TextOffset> positions{0,padding?padding-1:0,padding,padding+7,padding+8,
        padding+9,padding+17,padding+18,source.size(),source.size()+1};
    for (const auto& pattern : {u"Straße",u"\r\n",u"😀",u"👩🏽‍💻",u"𐐀",u"aaa"})
      compare(source,pattern,{},"cross-chunk literal",positions);
    for (const auto& pattern : {u"STRASSE",u"𐐨"})
      compare(source,pattern,{.caseSensitive=false},"cross-chunk folding",positions);
    for (const auto& pattern : {u"(?<=(before\\r\\n))(Straße)(?= 😀)",u"\\R",u"\\X",u"^|$",
         u"(a{2,4})",u"(ab)(?: )(\\1)",u"(?=😀)|(?<=😀)",u"(?s)\\A.*?END\\z"}) {
      SearchOptions options; options.regularExpression=true;
      compare(source,pattern,options,"cross-chunk regex",positions);
    }
    SearchOptions scoped; scoped.regularExpression=true; scoped.range=TextRange{padding+8,6};
    compare(source,u"(?<=(before\\r\\n))(Straße)(?= 😀)",scoped,"cross-chunk scoped lookaround",positions);
  }
  SakuraString paired(8191,u'.'); paired += u"😀\r\nSTRASSE 𐐀 foo\u0301";
  for (const auto& pattern : {u"😀",u"\\X",u"\\R",u"(?=😀)|(?<=😀)",u"(STRASSE)"})
    compare(paired,pattern,{.regularExpression=true},"surrogate exactly over chunk",{8190,8191,8192,8193,8194,8195,paired.size()});
  SakuraString endings(8191,u'.'); endings += u"\r\nword\rnext\nlast";
  compare(endings,u"\\R|^|$",{.regularExpression=true},"CRLF exactly over chunk",{8190,8191,8192,8193,endings.size()});
  SakuraString broken(8191,u'.');
  const SakuraChar units[]{0xd800,u'a',0xdc00,u' ',0xd800,0xdc00,u'\r',u'\n',0xdc00,0xd800,u'z'};
  broken.append(std::begin(units),std::end(units));
  const std::vector<TextOffset> positions{8190,8191,8192,8193,8194,8195,8196,8197,8198,broken.size()};
  for (const auto unit : {static_cast<SakuraChar>(0xd800),static_cast<SakuraChar>(0xdc00)}) {
    SakuraString pattern(1,unit);
    compare(broken,pattern,{},"unpaired raw unit",positions);
    compare(broken,pattern,{.caseSensitive=false},"unpaired folded unit",positions);
  }
  compare(broken,u".|\\R|$",{.regularExpression=true},"unpaired Unicode regex",positions);
  SakuraString needle(9003,u'a'); needle += u'b';
  SakuraString longSource(8191,u'.'); longSource += needle+u" "+needle;
  compare(longSource,needle,{},"needle larger than chunk",{0,8191,8192,17194,longSource.size()});
  compare(longSource,needle,{.caseSensitive=false},"folded needle larger than chunk",{0,8191,8192,17194,longSource.size()});
  compare(longSource,u"(a{9003})(b)",{.regularExpression=true},"capture larger than chunk",{0,8191,8192,17194,longSource.size()});
  SakuraString withNul = u"aa"; withNul.push_back(0); withNul += u"bb";
  compare(withNul,SakuraString(1,0),{},"explicit embedded NUL literal");
  compare(withNul,u"a+(\\x{0})b+",{.regularExpression=true},"embedded NUL regex capture");
}

void surrogateAndCrLfCaptureAttempts() {
  // A provider must not change regex behavior merely because ICU requests a
  // raw UTF-16 extraction/preflight ending inside a surrogate pair or CRLF.
  // Most split-surrogate expressions are expected not to match, but standalone
  // surrogate controls and full-pair expressions exercise positive paths too.
  const SakuraString patterns[]{
    u"\\uD83D",u"\\uDE00",u"(\\uD83D)\\uDE00",u"\\uD83D(\\uDE00)",
    u"(\\uD83D)(\\uDE00)",u"A(\\uD83D)\\uDE00B",u"A\\uD83D(\\uDE00)B",
    u"(?=(\\uD83D))",u"(?<=(\\uD83D))",u"(\\uD83D)(?=\\uDE00)",
    u"(?<=\\uD83D)(\\uDE00)",u"[\\uD83D]",u"[\\uDE00]",u"(\\uD83D\\uDE00)",
    u"(?<=(A))(\\uD83D\\uDE00)(?=(B))",u"(\\r)(\\n)",u"(?=(\\r))\\r\\n",
    u"\\r(?=(\\n))\\n",u"\\r(?<=(\\r))\\n",u"(?<=(\\r))\\n",u"\\r(?=(\\n))",
    u"(?<=(B))(\\r)(\\n)(?=(C))",u"(?<=(\\r\\n))C"
  };
  for (const std::size_t padding : {0,8191,8192}) {
    SakuraString paired(padding,u'.'); paired += u"A😀B\r\nC";
    SakuraString broken(padding,u'.'); broken += u'A';
    broken.push_back(static_cast<SakuraChar>(0xd83d)); broken += u"B ";
    broken.push_back(static_cast<SakuraChar>(0xde00)); broken += u"C\r\nD";
    const std::vector<TextOffset> positions{padding,padding+1,padding+2,padding+3,
        padding+4,padding+5,padding+6,paired.size(),broken.size()+1};
    for (const auto& pattern : patterns) for (const bool sensitive : {false,true}) {
      SearchOptions options; options.regularExpression=true; options.caseSensitive=sensitive;
      compare(paired,pattern,options,"paired surrogate or CRLF capture split",positions);
      compare(broken,pattern,options,"standalone surrogate capture control",positions);
    }
    SearchOptions scoped; scoped.regularExpression=true; scoped.range=TextRange{padding+1,2};
    compare(paired,u"(?<=(A))(\\uD83D\\uDE00)(?=(B))",scoped,
        "paired capture with context outside fixed region",positions);
    scoped.range=TextRange{padding+4,2};
    compare(paired,u"(?<=(B))(\\r)(\\n)(?=(C))",scoped,
        "raw CR LF capture ranges inside whole selected CRLF",positions);
  }
}

void randomizedComparison() {
  std::mt19937 random(0x7354726d);
  const SakuraString fragments[]{u"a",u"aa",u"b",u" ",u"_",u"\r\n",u"\r",u"\n",u"桜",u"😀",
      u"𐐀",u"𐐨",u"Straße",u"STRASSE",u"Σ",u"ς",u"\u0301",u"²",u"\u200d"};
  const SakuraString literals[]{u"a",u"aa",u"ab",u"STRASSE",u"σ",u"桜",u"😀",u"𐐨",u"\r\n",u"_"};
  const SakuraString patterns[]{u"(a+)|(b)",u"(?=(a))|$",u"(?<=a)b",u"(?<=(a))a",u"\\G(a)|a+",
      u"^|$",u"\\R",u"(Straße)|(STRASSE)",u"(桜)?(😀)",u"[ab]+",u"𐐀|𐐨",u"a.*?b"};
  for (unsigned trial=0; trial<360; ++trial) {
    SakuraString source;
    if (trial%60 == 0) source.assign(8191,u'.');
    for (unsigned count=0; count<25+random()%30; ++count) source += fragments[random()%std::size(fragments)];
    SearchOptions options;
    options.regularExpression = trial%3 == 0;
    options.caseSensitive = trial%4 != 0;
    options.wholeWord = trial%7 == 0;
    options.captureGroups = trial%5 != 0;
    options.regexMultiline = trial%2 != 0;
    if (trial%9 == 0) options.maxMatches=1+random()%7;
    if (trial%4 == 0) {
      auto first = static_cast<std::size_t>(random()%(source.size()+1));
      auto last = static_cast<std::size_t>(random()%(source.size()+1));
      if (first > last) std::swap(first,last);
      while (first && !boundary(source,first)) --first;
      while (last && !boundary(source,last)) --last;
      options.range = TextRange{first,last-first};
    }
    const auto& pattern = options.regularExpression ? patterns[random()%std::size(patterns)]
                                                  : literals[random()%std::size(literals)];
    compare(source,pattern,options,"fixed-seed mixed Unicode");
  }
}

void resourceFailuresAndLimits() {
  const TextBuffer source(SakuraString(200000,u'a')+u'!');
  const auto retained=source;
  for (unsigned mode=0; mode<3; ++mode) for (const bool throwing : {false,true}) {
    auto calls=std::make_shared<std::atomic<unsigned>>(0);
    SearchOptions options;
    options.regularExpression=mode==2;
    options.caseSensitive=mode!=1;
    options.wrap=false;
    options.cancelled=[calls,throwing] {
      if (++*calls < 8) return false;
      if (throwing) throw std::runtime_error("isolated streaming cancellation failure");
      return true;
    };
    bool stopped=false;
    try { (void)SearchEngine{}.findAll(source,mode==2?u"z+$":u"z",options); }
    catch (const std::runtime_error&) { stopped=true; }
    check(stopped,"streaming scanning cancellation/throw is observed without crossing a C callback");
  }
  SearchOptions capped; capped.regularExpression=true; capped.maxMatches=7;
  compare(u"aaaaaaaaaaaaaaaaaa",u"(?=a)",capped,"bounded zero-width result count");
  capped.maxMatches=0; capped.maxCaptureSlots=2;
  bool limited=false;
  try { (void)SearchEngine{}.findAll(TextBuffer(u"aa"),u"(a)",capped); }
  catch (const std::length_error&) { limited=true; }
  check(limited,"streaming provider keeps aggregate capture slot limit");
  SearchOptions timed; timed.regularExpression=true; timed.regexTimeLimitMilliseconds=1;
  bool stopped=false;
  try { (void)SearchEngine{}.findNext(source,u"(a+)+$",0,timed); }
  catch (const std::runtime_error&) { stopped=true; }
  check(stopped,"pathological backtracking still reports a resource failure");
  check(source.sharesStorageWith(retained) && source.revision()==retained.revision(),
        "cancellation and resource failures preserve source root/revision");
}

void diagnoseAmbiguousCapture() {
  SakuraString needle(9003,u'a'); needle += u'b';
  SakuraString source(8191,u'.'); source += needle+u" "+needle;
  const TextBuffer buffer(source);
  const SakuraStringView pattern=u"(a{9003})(b)";
  SearchOptions options; options.regularExpression=true; options.wrap=false;
  std::cout << "diagnosis=ambiguous-capture sourceUnits=" << source.size()
            << " start=8192 regexTimeLimitMilliseconds=" << options.regexTimeLimitMilliseconds
            << " sourceConstructionOutsideTimer=1 referenceUsesContiguousUregexSetText=1\n";
  const auto construction=std::chrono::steady_clock::now();
  Reference reference(source,pattern,options);
  std::cout << "referenceConstructionMilliseconds="
            << std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-construction).count() << '\n';
  const auto report=[](const char* backend, auto&& operation) {
    const auto begin=std::chrono::steady_clock::now();
    try {
      const auto match=operation();
      const auto elapsed=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count();
      std::cout << "backend=" << backend << " completed=1 matched=" << match.has_value()
                << " milliseconds=" << std::setprecision(12) << elapsed;
      if (match) std::cout << " range=" << match->range.location << ':' << match->range.length
                          << " captureSlots=" << match->captures.size();
      std::cout << '\n';
    } catch (const std::exception& error) {
      const auto elapsed=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count();
      std::cout << "backend=" << backend << " completed=0 milliseconds=" << std::setprecision(12) << elapsed
                << " error=" << error.what() << '\n';
    }
  };
  report("contiguous-reference",[&]{return reference.next(8192);});
  report("streaming-actual",[&]{return SearchEngine{}.findNext(buffer,pattern,8192,options);});
}

std::uint64_t peakRssBytes() {
#if defined(__APPLE__) || defined(__unix__)
  rusage usage{};
  if (getrusage(RUSAGE_SELF,&usage)) return 0;
#if defined(__APPLE__)
  return usage.ru_maxrss;
#else
  return static_cast<std::uint64_t>(usage.ru_maxrss)*1024;
#endif
#else
  return 0; // Unsupported host; the benchmark prints unavailable explicitly.
#endif
}
std::uint64_t residentBytes() {
#if defined(__APPLE__)
  mach_task_basic_info_data_t info{};
  mach_msg_type_number_t count=MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(),MACH_TASK_BASIC_INFO,reinterpret_cast<task_info_t>(&info),&count)==KERN_SUCCESS)
    return info.resident_size;
#endif
  return 0; // Zero means unavailable, not a zero-memory measurement.
}
constexpr std::size_t benchmarkUnits=100ULL*1024*1024;
constexpr std::size_t benchmarkRows=1000000;
constexpr std::size_t benchmarkRowBase=benchmarkUnits/benchmarkRows;
constexpr std::size_t benchmarkExtraRows=benchmarkUnits%benchmarkRows;
std::size_t benchmarkStart(std::size_t row) {
  return row*benchmarkRowBase+std::min(row,benchmarkExtraRows);
}
TextBuffer benchmarkSource() {
  SakuraString source(benchmarkUnits,u'x');
  for (std::size_t row=0; row<benchmarkRows; ++row) {
    const auto start=benchmarkStart(row);
    source.replace(start,6,u"needle");
    if (row+1<benchmarkRows) source[benchmarkStart(row+1)-1]=u'\n';
  }
  TextBuffer result(source);
  check(result.length()==benchmarkUnits && result.lineCount()==benchmarkRows,"large synthetic source shape");
  std::size_t row=0;
  for (auto lines=result.lineCursor(); lines; lines.advance(),++row) {
    const auto& line=lines.line();
    const auto expected=benchmarkRowBase+(row<benchmarkExtraRows)-(row+1<benchmarkRows);
    check(line.content.size()==expected && line.content.compare(0,6,u"needle")==0 &&
          std::all_of(line.content.begin()+6,line.content.end(),[](SakuraChar value){return value==u'x';}) &&
          line.ending==(row+1<benchmarkRows?LineEnding::lineFeed:LineEnding::none),
          "large source verifies every character and ending before measurement");
  }
  check(row==benchmarkRows,"large source validates all logical rows");
  return result;
}
void benchmark(std::string_view selectedMode, std::string_view selectedOperation) {
  const auto source=benchmarkSource(); // Construction and validation are outside measured queries.
  const auto retained=source;
  for (const std::string_view mode : {"literal","fold","regex"}) {
    if (!selectedMode.empty() && selectedMode!=mode) continue;
    SearchOptions options; options.wrap=false; options.captureGroups=false;
    options.caseSensitive=mode!="fold"; options.regularExpression=mode=="regex";
    const SakuraStringView pattern=mode=="fold"?u"NEEDLE":u"needle";
    for (const std::string_view operation : {"next","next-tail","previous","all"}) {
      if (!selectedOperation.empty() && selectedOperation!=operation) continue;
      const auto rssBefore=residentBytes(), peakBefore=peakRssBytes();
      std::optional<SearchMatch> single;
      std::vector<SearchMatch> matches;
      const auto begin=std::chrono::steady_clock::now();
      if (operation=="all") matches=SearchEngine{}.findAll(source,pattern,options);
      else if (operation=="previous") single=SearchEngine{}.findPrevious(source,pattern,source.length(),options);
      else single=SearchEngine{}.findNext(source,pattern,operation=="next"?0:benchmarkStart(benchmarkRows-1),options);
      const auto elapsed=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count();
      const auto rssAfter=residentBytes(), peakAfter=peakRssBytes();
      bool valid=source.sharesStorageWith(retained) && source.revision()==retained.revision();
      if (operation=="all") {
        valid=valid && matches.size()==benchmarkRows;
        for (std::size_t row=0; row<matches.size(); ++row)
          valid=valid && matches[row].range==TextRange{benchmarkStart(row),6} && matches[row].captures.empty();
      } else valid=valid && single && single->range==TextRange{operation=="next"?0:benchmarkStart(benchmarkRows-1),6}
          && single->captures.empty();
      check(valid,"large measured query validates every returned range/capture and unchanged source");
      std::cout << "mode=" << mode << " operation=" << operation << " sourceAsciiBytes=" << benchmarkUnits
                << " logicalRows=" << benchmarkRows << " milliseconds=" << std::setprecision(12) << elapsed
                << " setupAndValidationOutsideTimer=1 rssScope=process lifetimePeakIncludesSetup=1"
                << " rssBeforeBytes=" << (rssBefore ? std::to_string(rssBefore) : "unavailable")
                << " rssAfterBytes=" << (rssAfter ? std::to_string(rssAfter) : "unavailable")
                << " peakBeforeBytes=" << (peakBefore ? std::to_string(peakBefore) : "unavailable")
                << " peakAfterBytes=" << (peakAfter ? std::to_string(peakAfter) : "unavailable")
                << " verified=" << valid << '\n';
    }
  }
}
} // namespace

int main(int argc, char** argv) {
  try {
    if (argc>1 && std::string_view(argv[1])=="--diagnose-ambiguous-capture") {
      diagnoseAmbiguousCapture();
    } else if (argc>1 && std::string_view(argv[1])=="--benchmark") {
      const std::string_view mode=argc>2?argv[2]:"", operation=argc>3?argv[3]:"";
      if ((!mode.empty() && mode!="literal" && mode!="fold" && mode!="regex") ||
          (!operation.empty() && operation!="next" && operation!="next-tail" && operation!="previous" && operation!="all"))
        throw std::invalid_argument("benchmark arguments: [literal|fold|regex] [next|next-tail|previous|all]");
      benchmark(mode,operation);
    } else {
      basicSemantics();
      chunkBoundariesAndLongPatterns();
      surrogateAndCrLfCaptureAttempts();
      randomizedComparison();
      resourceFailuresAndLimits();
      if (!failures) std::cout << "Streaming search comparisons passed: " << comparisons
          << " exactValueComparisons=" << valueComparisons
          << " matchingIcuTimeOutRefusals=" << matchingTimeOutRefusals << '\n';
    }
  } catch (const std::exception& error) {
    ++failures;
    std::cerr << "streaming search test exception: " << error.what() << '\n';
  }
  if (failures) std::cerr << failures << " streaming search failure(s)\n";
  return failures?1:0;
}
