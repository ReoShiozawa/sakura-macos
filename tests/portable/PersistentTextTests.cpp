// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#include "sakura/core/text/TextBuffer.h"
#include "sakura/core/search/SearchEngine.h"
#include <atomic>
#include <iostream>
#include <random>
#include <thread>
#include <vector>
using namespace sakura::core;
namespace {
int failures = 0;
void check(bool ok, const char* message) { if (!ok) { std::cerr << message << '\n'; ++failures; } }
void valid(const TextBuffer& buffer) {
  auto stats = buffer.storageStatistics();
  check(stats.valid && stats.nodes == buffer.lineCount(), "persistent AVL metadata and balancing invariants");
  unsigned logarithm = 0; for (auto n = stats.nodes; n; n >>= 1) ++logarithm;
  check(stats.height <= 2 * logarithm, "structural edits retain logarithmic tree height");
}
}
int main() {
  SakuraString original;
  for (unsigned n=0;n<5000;++n) original.append(u"a😀\r\nb\nc\rd\n");
  TextBuffer buffer(original), snapshot = buffer;
  const auto* far = &snapshot.line(1000);
  check(&buffer.line(1000) == far && &buffer.line(0) == &snapshot.line(0), "snapshots share immutable line payloads");
  buffer.replace({0,1},u"Z");
  check(snapshot.text() == original && &buffer.line(1000) == far && &buffer.line(0) != &snapshot.line(0), "ordinary edit copies only changed line and tree path");
  buffer.replace({0,0},u"\nnew\r");
  check(&buffer.line(1002) == far && snapshot.text() == original, "newline edits share distant payload and preserve old snapshot");
  valid(buffer); valid(snapshot);
  {
    for(auto first : {std::size_t{0},std::size_t{1},std::size_t{1000},snapshot.lineCount()-1,snapshot.lineCount()}) {
      auto cursor=snapshot.lineCursor(first); auto index=first;
      while(cursor) {
        if(index==first || index%127==0) check(&cursor.line()==&snapshot.line(index),"linear cursor follows exact immutable line order");
        ++index; cursor.advance();
      }
      check(index==snapshot.lineCount(),"cursor covers remaining logical lines exactly once");
      cursor.advance(); check(!cursor,"end cursor advance is harmless");
    }
    bool rejected=false;
    try { (void)snapshot.lineCursor(snapshot.lineCount()+1); } catch(const std::out_of_range&) { rejected=true; }
    check(rejected,"invalid cursor start rejected");
    TextBuffer temporary(u"first\nsecond"); auto heldCursor=temporary.lineCursor();
    temporary.assign(u"other");
    check(heldCursor.line().content==u"first","cursor survives replacing its source root");
    heldCursor.advance();check(heldCursor.line().content==u"second","cursor keeps old suffix alive");
    TextBuffer moved(std::move(temporary));
    check(temporary.text()==u"other" && moved.text()==u"other" && temporary.storageStatistics().valid,"moved-from shared-root buffer remains usable");
  }
  {
    std::atomic<bool> start{false}, correct{true};
    std::vector<std::thread> readers;
    for (unsigned n=0;n<4;++n) {
      TextBuffer ownSnapshot = snapshot;
      readers.emplace_back([ownSnapshot, &original, &start, &correct] {
        while (!start.load(std::memory_order_acquire)) std::this_thread::yield();
        for(unsigned iteration=0; iteration<12; ++iteration) {
          if(ownSnapshot.text() != original || !ownSnapshot.storageStatistics().valid) correct=false;
          SearchOptions options; options.maxMatches=2;
          if(SearchEngine{}.findAll(ownSnapshot,u"😀",options).size()!=2) correct=false;
        }
      });
    }
    start.store(true,std::memory_order_release);
    for (unsigned iteration=0;iteration<1000;++iteration) {
      buffer.replace({0,0},u"line\r\n"); buffer.replace({0,6},u"");
    }
    for(auto& reader:readers) reader.join();
    check(correct, "worker snapshots remain stable during concurrent original edits"); valid(buffer);
  }
  {
    SakuraString naive(1000,u'x'); naive.append(u"\nlast"); TextBuffer edited(naive);
    std::mt19937 random(0x5a4b1);
    std::vector<std::pair<TextBuffer,SakuraString>> held;
    for(unsigned iteration=0; iteration<12000; ++iteration) {
      auto start = static_cast<std::size_t>(random() % (naive.size()+1));
      std::size_t length = start < naive.size() && random()%2 ? 1 : 0;
      if(!edited.isEditBoundary(start) || !edited.isEditBoundary(start+length)) continue;
      SakuraStringView insert = iteration%4==0 ? u"\r\n" : iteration%4==1 ? u"\n" : iteration%4==2 ? u"x" : u"\r";
      edited.replace({start,length},insert); naive.replace(start,length,insert);
      if(iteration%300==0) {
        check(edited.text()==naive, "persistent structural edit matches naive text"); valid(edited);
        held.emplace_back(edited,naive);
      }
    }
    check(edited.text()==naive,"stress final text exact"); valid(edited);
    for(const auto& [old,text]:held) { check(old.text()==text,"retained historical root unchanged"); valid(old); }
  }
  {
    bool stopped=false; unsigned calls=0;
    try { (void)snapshot.text([&]{return ++calls>4;}); } catch (const std::runtime_error&) { stopped=true; }
    check(stopped && snapshot.text()==original,"serialization cancellation leaves immutable snapshot unchanged");
    TextBuffer longLine(SakuraString(200000,u'a')); calls=0; stopped=false;
    try { (void)longLine.text([&]{return ++calls>3;}); } catch(const std::runtime_error&) {stopped=true;}
    check(stopped,"serialization also cancels within one very long logical line");
  }
  return failures ? 1 : 0;
}
