// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#include "BufferUText.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <iostream>
#include <limits>
#include <memory>
#include <random>
#include <stdexcept>
#include <thread>
#include <vector>

using namespace sakura::core;
using sakura::core::detail::BufferUText;
namespace {
int failures = 0;
std::string scenario;
void check(bool condition, const char* label) {
  if (!condition) {
    if (failures < 35) std::cerr << scenario << ": " << label << '\n';
    ++failures;
  }
}
using Text = std::unique_ptr<UText, decltype(&utext_close)>;
Text reference(const SakuraString& source) {
  UErrorCode status = U_ZERO_ERROR;
  Text result(utext_openUChars(nullptr, reinterpret_cast<const UChar*>(source.data()),
                              source.size(), &status), utext_close);
  check(U_SUCCESS(status) && result != nullptr, "open contiguous ICU reference");
  return result;
}
void samePosition(UText* actual, UText* expected) {
  check(utext_getNativeIndex(actual) == utext_getNativeIndex(expected), "native iterator position agrees");
}
std::vector<SakuraString> fixtures() {
  std::vector<SakuraString> result{u"", u"abc", u"😀", u"a\r\nb\rc\n", u"桜 e\u0301 🇯🇵 𐐨"};
  SakuraString broken{SakuraChar(0xD800),u'a',SakuraChar(0xDC00),SakuraChar(0xD801)};
  result.push_back(broken);
  result.emplace_back(u"a\0b\0😀", 7);
  for (std::size_t seam : {BufferUText::chunkUnits-1,BufferUText::chunkUnits,BufferUText::chunkUnits+1}) {
    SakuraString source(seam,u'x');
    source.append(u"😀\r\n桜 e\u0301");
    source.append(BufferUText::chunkUnits-10,u'y');
    source.append(broken);
    source.append(u"\r\n𐐨 end");
    result.push_back(std::move(source));
  }
  SakuraString lines;
  for (unsigned index=0; index<2000; ++index) lines.append(u"桜😀\r\n");
  result.push_back(std::move(lines));
  return result;
}
void iterationAndRandomAccess() {
  unsigned fixture = 0;
  for (const auto& source : fixtures()) {
    scenario = "iteration fixture " + std::to_string(fixture++);
    TextBuffer buffer(source);
    BufferUText provider(buffer);
    auto expected = reference(source);
    UText* actual = provider.get();
    check(utext_nativeLength(actual) == static_cast<std::int64_t>(source.size()), "length is UTF-16 units");
    check(!utext_isWritable(actual), "provider is read-only");
    for (;;) {
      const auto a=utext_next32(actual), b=utext_next32(expected.get());
      check(a==b, "forward code points agree"); samePosition(actual,expected.get());
      if (a==U_SENTINEL || b==U_SENTINEL) break;
    }
    for (;;) {
      const auto a=utext_previous32(actual), b=utext_previous32(expected.get());
      check(a==b, "backward code points agree"); samePosition(actual,expected.get());
      if (a==U_SENTINEL || b==U_SENTINEL) break;
    }
    std::mt19937 random(0x55544558+fixture);
    for (unsigned step=0; step<3000; ++step) {
      const auto index = static_cast<std::int64_t>(random()%(source.size()+9))-4;
      switch (random()%9) {
        case 0: utext_setNativeIndex(actual,index); utext_setNativeIndex(expected.get(),index); break;
        case 1: check(utext_next32(actual)==utext_next32(expected.get()),"random next agrees"); break;
        case 2: check(utext_previous32(actual)==utext_previous32(expected.get()),"random previous agrees"); break;
        case 3: check(utext_current32(actual)==utext_current32(expected.get()),"random current agrees"); break;
        case 4: check(utext_next32From(actual,index)==utext_next32From(expected.get(),index),"random nextFrom agrees"); break;
        case 5: check(utext_previous32From(actual,index)==utext_previous32From(expected.get(),index),"random previousFrom agrees"); break;
        case 6: check(utext_char32At(actual,index)==utext_char32At(expected.get(),index),"random charAt agrees"); break;
        case 7: {
          const auto delta=static_cast<std::int32_t>(random()%15)-7;
          check(utext_moveIndex32(actual,delta)==utext_moveIndex32(expected.get(),delta),"random code-point move agrees");
          break;
        }
        case 8: check(utext_getPreviousNativeIndex(actual)==utext_getPreviousNativeIndex(expected.get()),"previous native index agrees"); break;
      }
      samePosition(actual,expected.get());
      provider.rethrowFailure();
    }
    const auto stats = provider.statistics();
    check(stats.peakChunkUnits<=BufferUText::chunkUnits+2,"chunk storage remains bounded");
    check(stats.extractedUnits==0,"iteration never extracts full text");
    check(buffer.text()==source,"read-only traversal preserves source text");
  }
}
void directAccessContract() {
  for (const auto& source : fixtures()) {
    scenario = "direct access length " + std::to_string(source.size());
    BufferUText provider{TextBuffer(source)};
    auto expected = reference(source);
    for (auto index : std::vector<std::int64_t>{-5,-1,0,1,2,8191,8192,8193,
        static_cast<std::int64_t>(source.size()),static_cast<std::int64_t>(source.size()+1)}) {
      for (bool forward : {false,true}) {
        const auto a=provider.get()->pFuncs->access(provider.get(),index,forward);
        const auto b=expected->pFuncs->access(expected.get(),index,forward);
        check(a==b,"access validity agrees with builtin provider");
        const auto clamped = utext_getNativeIndex(expected.get());
        check(provider.get()->chunkNativeStart+provider.get()->chunkOffset==clamped,"access pins and normalizes iterator like builtin");
        if (a) {
          check(provider.get()->chunkNativeStart<=clamped && clamped<=provider.get()->chunkNativeLimit,"valid access contains requested position");
          const auto begin=static_cast<TextOffset>(provider.get()->chunkNativeStart);
          const auto end=static_cast<TextOffset>(provider.get()->chunkNativeLimit);
          TextBuffer buffer(source);
          check(buffer.isCodePointBoundary(begin) && buffer.isCodePointBoundary(end),"chunk never splits a surrogate pair");
          check(provider.get()->chunkLength==static_cast<std::int32_t>(end-begin),"native UTF-16 mapping is identity");
          for (std::size_t at=0; at<static_cast<std::size_t>(provider.get()->chunkLength); ++at)
            check(provider.get()->chunkContents[at]==source[begin+at],"accessed chunk preserves raw units");
        }
      }
    }
    provider.rethrowFailure();
  }
}
void extractionContract() {
  unsigned fixture = 0;
  for (const auto& source : fixtures()) {
    const auto length=static_cast<std::int64_t>(source.size());
    BufferUText provider{TextBuffer(source)};
    auto expected = reference(source);
    TextBuffer boundaries(source);
    std::vector<std::pair<std::int64_t,std::int64_t>> ranges{{0,length},{0,0},{length,length},
      {0,1},{1,2},{-4,3},{length+1,length+4},{length+4,0},{8190,8195},
      {std::numeric_limits<std::int64_t>::min(),std::numeric_limits<std::int64_t>::max()}};
    for (const auto& [begin,end] : ranges) {
      auto normalizedBegin=std::clamp<std::int64_t>(begin,0,length);
      auto normalizedEnd=std::clamp<std::int64_t>(end,0,length);
      if (begin<=end) {
        if (normalizedBegin && normalizedBegin<length && !boundaries.isCodePointBoundary(normalizedBegin)) --normalizedBegin;
        if (normalizedEnd && normalizedEnd<length && !boundaries.isCodePointBoundary(normalizedEnd)) ++normalizedEnd;
      }
      for (auto capacity : {0,1,2,static_cast<int>(source.size()),static_cast<int>(source.size()+1)}) {
        scenario = "extract fixture " + std::to_string(fixture) + " range " + std::to_string(begin) + ":" + std::to_string(end) + " capacity " + std::to_string(capacity);
        for (bool nullDestination : {false,true}) {
          std::vector<UChar> a(capacity+4,0x5555), b(capacity+4,0x5555);
          UErrorCode aStatus=U_ZERO_ERROR,bStatus=U_ZERO_ERROR;
          utext_setNativeIndex(provider.get(),1); utext_setNativeIndex(expected.get(),1);
          const auto aLength=utext_extract(provider.get(),begin,end,nullDestination?nullptr:a.data()+2,capacity,&aStatus);
          // Compare ordinary boundaries verbatim. For a deliberately split
          // pair, use the documented outward normalization before asking the
          // independent builtin provider; its raw split-end preflight has a
          // capacity-dependent historical quirk (tested explicitly below).
          const auto bLength=utext_extract(expected.get(),begin<=end?normalizedBegin:begin,
              begin<=end?normalizedEnd:end,nullDestination?nullptr:b.data()+2,capacity,&bStatus);
          check(aLength==bLength,"extract/preflight length agrees");
          check(aStatus==bStatus,"extract status agrees");
          check(a==b,"extract UTF-16 units and destination guards agree");
          samePosition(provider.get(),expected.get());
          provider.rethrowFailure();
        }
      }
    }
    UErrorCode aStatus=U_ILLEGAL_ARGUMENT_ERROR,bStatus=U_ILLEGAL_ARGUMENT_ERROR;
    check(utext_extract(provider.get(),0,length,nullptr,0,&aStatus)==
          utext_extract(expected.get(),0,length,nullptr,0,&bStatus),"preexisting error is preserved");
    check(aStatus==bStatus,"preexisting error status agrees");
    ++fixture;
  }
}
void splitEndpointPreflightIsConsistent() {
  scenario="split surrogate endpoint normalization";
  const SakuraString source=u"😀x";
  BufferUText provider{TextBuffer(source)};
  auto expected=reference(source);
  UErrorCode aStatus=U_ZERO_ERROR,bStatus=U_ZERO_ERROR;
  const auto aPreflight=utext_extract(provider.get(),0,1,nullptr,0,&aStatus);
  const auto bPreflight=utext_extract(expected.get(),0,1,nullptr,0,&bStatus);
  check(aPreflight==2 && aStatus==U_BUFFER_OVERFLOW_ERROR,"split-end preflight reserves the complete code point");
  // Record the reference's anomaly explicitly, not as provider equivalence.
  // A future ICU may fix this; the provider's normalized required size above
  // remains strict regardless of the reference implementation's version.
  check((bPreflight==1 || bPreflight==2) && bStatus==U_BUFFER_OVERFLOW_ERROR,
        "builtin split-end preflight is either legacy raw length or normalized length");
  std::array<UChar,4> actual{},referenceOutput{};
  aStatus=bStatus=U_ZERO_ERROR;
  const auto aFull=utext_extract(provider.get(),0,1,actual.data(),actual.size(),&aStatus);
  const auto bFull=utext_extract(expected.get(),0,1,referenceOutput.data(),referenceOutput.size(),&bStatus);
  check(aFull==2 && bFull==2 && actual==referenceOutput && aStatus==bStatus,
        "full split-end extraction agrees while provider preflight remains consistent");
  std::cout << "ICU split-end extraction observation: preflight=" << bPreflight
            << " full=" << bFull << (bPreflight==1?" (legacy capacity-dependent quirk)":" (consistent normalized length)") << '\n';
  check(utext_getNativeIndex(provider.get())==2 && utext_getNativeIndex(expected.get())==2,
        "split-end extraction leaves iterator after the complete code point");
  aStatus=bStatus=U_ZERO_ERROR;
  const auto aStart=utext_extract(provider.get(),1,2,actual.data(),actual.size(),&aStatus);
  const auto bStart=utext_extract(expected.get(),1,2,referenceOutput.data(),referenceOutput.size(),&bStatus);
  check(aStart==2 && bStart==2 && actual==referenceOutput && aStatus==bStatus,
        "split-start extraction snaps backward rather than returning a lone trail");
}
void incomingWarningStatus() {
  scenario="incoming ICU warnings";
  const SakuraString source=u"abc";
  BufferUText provider{TextBuffer(source)};
  auto expected=reference(source);
  for (const auto initial : {U_USING_DEFAULT_WARNING,U_STRING_NOT_TERMINATED_WARNING}) {
    for (const auto capacity : {0,1,3,4}) {
      std::array<UChar,5> actual{},referenceOutput{};
      auto aStatus=initial,bStatus=initial;
      const auto aLength=utext_extract(provider.get(),0,3,actual.data(),capacity,&aStatus);
      const auto bLength=utext_extract(expected.get(),0,3,referenceOutput.data(),capacity,&bStatus);
      check(aLength==bLength && actual==referenceOutput,"incoming warning preserves exact extraction");
      if (aStatus!=bStatus) std::cerr<<"initial="<<initial<<" capacity="<<capacity<<" actual="<<aStatus<<" builtin="<<bStatus<<'\n';
      check(aStatus==bStatus,"incoming warning status agrees with builtin");
      samePosition(provider.get(),expected.get());
    }
  }
}
void cloningLifetimeAndReuse() {
  scenario="clone ownership and stack reuse";
  const SakuraString original=fixtures().back();
  auto buffer=std::make_unique<TextBuffer>(original);
  auto provider=std::make_unique<BufferUText>(*buffer);
  utext_setNativeIndex(provider->get(),8193);
  std::array<Text,2> clones{Text(nullptr,utext_close),Text(nullptr,utext_close)};
  for (unsigned deep=0;deep<2;++deep) {
    UErrorCode status=U_ZERO_ERROR;
    clones[deep].reset(utext_clone(nullptr,provider->get(),deep,false,&status));
    check(U_SUCCESS(status) && clones[deep]!=nullptr,"shallow and deep immutable clones succeed");
    check(utext_getNativeIndex(clones[deep].get())==utext_getNativeIndex(provider->get()),"clone preserves native position");
    check(static_cast<bool>(utext_equals(clones[deep].get(),provider->get()))==!deep,
          "shallow clones share source identity and deep clones are logically independent");
    (void)utext_next32(clones[deep].get());
    check(!utext_equals(clones[deep].get(),provider->get()),"iterator movement changes clone equality");
    utext_setNativeIndex(clones[deep].get(),utext_getNativeIndex(provider->get()));
  }
  buffer->assign(u"source was edited");
  buffer.reset(); provider.reset();
  for (auto& clone : clones) {
    auto expected=reference(original);
    utext_setNativeIndex(clone.get(),0);
    for (;;) {
      const auto a=utext_next32(clone.get()),b=utext_next32(expected.get());
      check(a==b,"clone owns original snapshot after source edit and destruction");
      if (a==U_SENTINEL || b==U_SENTINEL) break;
    }
    UErrorCode status=U_ZERO_ERROR;
    const UChar replacement=u'x';
    (void)utext_replace(clone.get(),0,1,&replacement,1,&status);
    check(status==U_NO_WRITE_PERMISSION && !utext_isWritable(clone.get()),"clones never permit mutation");
  }
  UText stack=UTEXT_INITIALIZER;
  for (unsigned index=0;index<20;++index) {
    UErrorCode status=U_ZERO_ERROR;
    auto* result=utext_clone(&stack,clones[index%2].get(),index%2,false,&status);
    check(result==&stack && U_SUCCESS(status),"stack provider can be repeatedly reopened/cloned");
    status=U_ZERO_ERROR;
    result=utext_openUChars(&stack,reinterpret_cast<const UChar*>(original.data()),original.size(),&status);
    check(result==&stack && U_SUCCESS(status),"reopening provider with builtin releases its owned context");
  }
  utext_close(&stack);
}
void parallelClones() {
  scenario="four parallel clones";
  const auto original=fixtures()[7];
  TextBuffer buffer(original);
  BufferUText provider(buffer);
  std::atomic<unsigned> mismatches{};
  std::vector<std::thread> readers;
  for (unsigned reader=0;reader<4;++reader) {
    UErrorCode status=U_ZERO_ERROR;
    Text clone(utext_clone(nullptr,provider.get(),reader%2,false,&status),utext_close);
    check(U_SUCCESS(status) && clone!=nullptr,"parallel clone initializes");
    readers.emplace_back([text=std::move(clone),&original,&mismatches,reader]() mutable {
      auto expected=reference(original);
      std::mt19937 random(reader+555);
      for (unsigned iteration=0;iteration<2500;++iteration) {
        const auto index=static_cast<std::int64_t>(random()%(original.size()+4))-2;
        if (utext_next32From(text.get(),index)!=utext_next32From(expected.get(),index) ||
            utext_getNativeIndex(text.get())!=utext_getNativeIndex(expected.get())) ++mismatches;
      }
    });
  }
  for (unsigned edit=0;edit<300;++edit) buffer.assign(edit%2?u"edited\n":u"other😀");
  for (auto& reader:readers) reader.join();
  check(mismatches==0,"independent clone windows survive concurrent reads and source edits");
  provider.rethrowFailure();
  check(provider.statistics().peakChunkUnits<=BufferUText::chunkUnits+2,"all clone windows remain bounded");
}
void cancellationAndExceptionBoundary() {
  scenario="cancellation and throwing callbacks";
  TextBuffer buffer(SakuraString(BufferUText::chunkUnits*4,u'x'));
  for (bool throws : {false,true}) {
    auto cancelled=std::make_shared<std::atomic<bool>>(false);
    BufferUText provider(buffer,[cancelled,throws] {
      if (cancelled->load() && throws) throw std::logic_error("original cancellation exception");
      return cancelled->load();
    });
    check(utext_next32(provider.get())==u'x',"ordinary access succeeds before cancellation");
    *cancelled=true;
    bool crossed=false;
    try { (void)utext_next32From(provider.get(),BufferUText::chunkUnits*2); }
    catch (...) { crossed=true; }
    check(!crossed,"access callback never lets a C++ exception cross ICU");
    bool reported=false,original=false;
    try { provider.rethrowFailure(); }
    catch (const std::logic_error& error) { reported=true;original=std::string(error.what())=="original cancellation exception"; }
    catch (const std::runtime_error&) { reported=true; }
    check(reported && (!throws || original),"access failure is rethrown explicitly with original exception");
  }
  auto cancelled=std::make_shared<std::atomic<bool>>(false);
  BufferUText provider(buffer,[cancelled] { return cancelled->load(); });
  *cancelled=true;
  UErrorCode status=U_ZERO_ERROR;
  std::array<UChar,8> output{};
  bool crossed=false;
  try { (void)utext_extract(provider.get(),0,8,output.data(),output.size(),&status); }
  catch (...) { crossed=true; }
  check(!crossed && U_FAILURE(status),"extract cancellation stays inside ICU C boundary and reports status");
  bool reported=false;
  try { provider.rethrowFailure(); } catch (const std::runtime_error&) { reported=true; }
  check(reported,"extract cancellation can be explicitly rethrown");
}
} // namespace
int main() {
  iterationAndRandomAccess();
  directAccessContract();
  extractionContract();
  splitEndpointPreflightIsConsistent();
  incomingWarningStatus();
  cloningLifetimeAndReuse();
  parallelClones();
  cancellationAndExceptionBoundary();
  if (failures) std::cerr<<failures<<" buffer UText test(s) failed\n";
  else std::cout<<"All buffer UText tests passed\n";
  return failures?1:0;
}
