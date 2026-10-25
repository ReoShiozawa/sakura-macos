// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#include "sakura/app/DocumentSession.h"
#include <algorithm>
#include <atomic>
#include <barrier>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <new>
#include <random>
#include <stdexcept>
#include <thread>
#include <type_traits>

namespace allocationAudit {
std::atomic<bool> active{};
std::atomic<std::size_t> allocations{}, releases{};
}
void* operator new(std::size_t count) {
  if (allocationAudit::active.load()) ++allocationAudit::allocations;
  if (void* value = std::malloc(count ? count : 1)) return value;
  throw std::bad_alloc();
}
void* operator new[](std::size_t count) { return ::operator new(count); }
void operator delete(void* value) noexcept {
  if (value && allocationAudit::active.load()) ++allocationAudit::releases;
  std::free(value);
}
void operator delete[](void* value) noexcept { ::operator delete(value); }
void operator delete(void* value, std::size_t) noexcept { ::operator delete(value); }
void operator delete[](void* value, std::size_t) noexcept { ::operator delete(value); }

namespace {
using namespace sakura::core;
using sakura::app::DocumentSession;
using Direction = EditEngine::HistoryDirection;
int failures{};
void check(bool value, const char* label) {
  if (!value) { ++failures; std::cerr << label << '\n'; }
}
bool commitWithoutHeapWork(EditEngine& engine, EditEngine::PreparedHistory& prepared) {
  allocationAudit::allocations = 0; allocationAudit::releases = 0;
  allocationAudit::active = true;
  const bool committed = engine.commitPreparedHistory(prepared);
  allocationAudit::active = false;
  check(allocationAudit::allocations == 0, "publication performs no normal new/new[] allocation");
  check(allocationAudit::releases == 0, "publication retains retired roots/history instead of deleting them");
  return committed;
}
bool boundary(SakuraStringView text, std::size_t at) {
  if (!at || at == text.size()) return true;
  return !(text[at-1]==u'\r' && text[at]==u'\n') &&
      !(text[at-1]>=0xd800 && text[at-1]<=0xdbff && text[at]>=0xdc00 && text[at]<=0xdfff);
}
void randomHistoryMatchesStringStates() {
  TextBuffer buffer(u"head\r\n😀 tail"); EditEngine engine(buffer);
  std::vector<SakuraString> states{buffer.text()}; std::size_t position=0;
  const SakuraString pieces[]{u"a",u"\r",u"\n",u"\r\n",u"😀",u"桜",u"",u"ab"};
  std::mt19937 random(0x48495354);
  for (unsigned run=0;run<1200;++run) {
    if (random()%3==0) {
      auto text=states[position];
      std::vector<std::size_t> bounds;
      for (std::size_t at=0;at<=text.size();++at) if (boundary(text,at)) bounds.push_back(at);
      auto first=random()%bounds.size(), last=random()%bounds.size();
      if (first>last) std::swap(first,last);
      const auto& replacement=pieces[random()%std::size(pieces)];
      engine.replace({bounds[first],bounds[last]-bounds[first]},replacement);
      auto expected=text; expected.replace(bounds[first],bounds[last]-bounds[first],replacement);
      if (expected!=text) {
        states.resize(position+1); states.push_back(std::move(expected)); ++position;
      }
    } else {
      const bool undoing=random()%2==0;
      const auto direction=undoing?Direction::undo:Direction::redo;
      const auto expectedPosition=undoing ? (position?position-1:position)
          : std::min(position+1,states.size()-1);
      const auto before=buffer;
      const auto state=engine.stateId();
      const auto snapshot=engine.historySnapshot();
      check(snapshot.canUndo()==(position!=0) && snapshot.canRedo()==(position+1<states.size()),
          "immutable snapshot reports the captured history availability");
      auto prepared=EditEngine::prepareHistory(snapshot,direction);
      const bool changed=expectedPosition!=position;
      check(prepared.hasChanges()==changed && prepared.resultingBuffer().text()==states[expectedPosition],
          "prepared history agrees with independent serialized string-state model");
      check(prepared.resultingBuffer().revision()==before.revision()+(changed?1:0),
          "prepared result predicts the exact monotonic committed revision");
      check(buffer.sharesStorageWith(before) && buffer.revision()==before.revision() && engine.stateId()==state,
          "history preparation does not change live source or state ID");
      check(commitWithoutHeapWork(engine,prepared),"current history plan publishes successfully");
      check(buffer.revision()==prepared.resultingBuffer().revision() && buffer.sharesStorageWith(prepared.resultingBuffer()),
          "published history root and revision match the layout-preparation result");
      check(!commitWithoutHeapWork(engine,prepared),"every history plan is one-shot, including no-op plans");
      position=expectedPosition;
    }
    check(buffer.text()==states[position] && engine.canUndo()==(position!=0) && engine.canRedo()==(position+1<states.size()),
        "mixed edits/undo/redo preserve the independent history state sequence");
  }
}
void compoundRevisionAndHeapChecks() {
  TextBuffer buffer(u"abc\r\n😀"); EditEngine engine(buffer);
  const auto original=buffer; const auto originalState=engine.stateId();
  engine.replaceMany({{{0,0},u"X"},{{1,0},u"Y"},{{2,0},u"Z"}});
  const auto edited=buffer;
  const auto editedState=engine.stateId();
  const auto steps=edited.revision()-original.revision();
  check(steps==3,"compound action has a multi-step revision fixture");
  allocationAudit::allocations=0; allocationAudit::active=true;
  auto prepared=EditEngine::prepareHistory(engine.historySnapshot(),Direction::undo);
  allocationAudit::active=false;
  check(allocationAudit::allocations>0,"heap audit observes worker preparation allocations");
  check(prepared.resultingBuffer().revision()==edited.revision()+steps && prepared.resultingBuffer().text()==original.text(),
      "compound undo prepares the action's complete revision step count");
  check(commitWithoutHeapWork(engine,prepared) && engine.stateId()==originalState,
      "compound undo publishes the original saved state ID without heap work");
  auto redo=EditEngine::prepareHistory(engine.historySnapshot(),Direction::redo);
  check(redo.resultingBuffer().revision()==buffer.revision()+steps && redo.resultingBuffer().text()==edited.text(),
      "compound redo predicts the published revision and full text");
  check(commitWithoutHeapWork(engine,redo) && engine.stateId()==editedState,
      "compound redo restores the action state ID without allocating");
  static_assert(!std::is_copy_constructible_v<EditEngine::PreparedHistory>);
  static_assert(std::is_nothrow_move_constructible_v<EditEngine::PreparedHistory>);
  EditEngine::PreparedHistory moved=std::move(redo);
  check(!redo.hasChanges() && moved.hasChanges(),"moving a prepared history plan transfers opaque ownership");
  bool absent=false;
  try { (void)redo.resultingBuffer(); } catch (const std::logic_error&) { absent=true; }
  check(absent,"moved-from history plans cannot expose a false result");
}
void stalePlansAndUntrackedWrites() {
  TextBuffer buffer(u"a"); EditEngine engine(buffer); engine.insert(1,u"b");
  auto plan=EditEngine::prepareHistory(engine.historySnapshot(),Direction::undo);
  const auto root=buffer;
  check(engine.undo() && engine.redo() && buffer.sharesStorageWith(root),"edit/undo cycle returns to identical retained root");
  check(!commitWithoutHeapWork(engine,plan) && buffer.text()==u"ab","new revision rejects a plan even at identical text/state");
  plan=EditEngine::prepareHistory(engine.historySnapshot(),Direction::undo);
  engine.clearHistory();
  check(!commitWithoutHeapWork(engine,plan) && !engine.canUndo() && !engine.canRedo(),"clearHistory invalidates captured plans without changing text");
  auto noHistory=EditEngine::prepareHistory(engine.historySnapshot(),Direction::undo);
  check(!noHistory.hasChanges() && commitWithoutHeapWork(engine,noHistory),"empty history still creates an authenticated no-op plan");
  noHistory=EditEngine::prepareHistory(engine.historySnapshot(),Direction::redo);
  engine.insert(2,u"c");
  check(!commitWithoutHeapWork(engine,noHistory) && buffer.text()==u"abc","stale no-op cannot authenticate a later source");
  auto foreign=EditEngine::prepareHistory(engine.historySnapshot(),Direction::undo);
  TextBuffer otherBuffer(u"abc"); EditEngine other(otherBuffer); other.insert(3,u"!");
  check(!commitWithoutHeapWork(other,foreign) && !commitWithoutHeapWork(engine,foreign),"foreign attempt rejects and consumes a one-shot plan");
  auto direct=EditEngine::prepareHistory(engine.historySnapshot(),Direction::undo);
  buffer.assign(u"external");
  check(!engine.canUndo() && !engine.canRedo() && !engine.undo() && !engine.redo(),"untracked buffer mutation invalidates synchronous history too");
  check(!commitWithoutHeapWork(engine,direct) && buffer.text()==u"external","prepared history cannot erase an untracked external write");
  bool rejected=false;
  try { (void)engine.historySnapshot(); } catch (const std::logic_error&) { rejected=true; }
  check(rejected,"capturing history after untracked writes requires explicit clearHistory");
  engine.clearHistory();
  check(engine.historySnapshot().buffer().text()==u"external","clearHistory explicitly accepts the externally supplied root");
  EditEngine::HistorySnapshot empty;
  rejected=false;
  try { (void)EditEngine::prepareHistory(empty,Direction::undo); } catch (const std::invalid_argument&) { rejected=true; }
  check(rejected,"default history snapshot cannot forge an authenticated source");
  rejected=false;
  try { (void)EditEngine::prepareHistory(engine.historySnapshot(),static_cast<Direction>(99)); }
  catch (const std::invalid_argument&) { rejected=true; }
  check(rejected,"invalid direction cannot select an implicit history branch");
}
void documentMetadataSaveAndReload() {
  DocumentSession document;
  document.insert(0,u"one"); document.markSaved(document.makeSaveSnapshot().token);
  document.insert(3,u" two"); const auto lateSave=document.makeSaveSnapshot().token;
  auto undo=DocumentSession::prepareHistory(document.historySnapshot(),Direction::undo);
  document.setEncodingState({TextEncoding::utf16BigEndian,true});
  check(document.commitPreparedHistory(undo) && document.buffer().text()==u"one" && document.isDirty(),
      "history restores text but keeps independently changed encoding metadata dirty");
  check(document.encodingState()==EncodingState{TextEncoding::utf16BigEndian,true},"history publication preserves current encoding and BOM");
  document.markSaved(lateSave);
  check(document.isDirty() && document.buffer().text()==u"one" && document.encodingState()==EncodingState{TextEncoding::utf16BigEndian,true},
      "late save cannot mark the newly restored state or newer metadata saved");
  document.markSaved(document.makeSaveSnapshot().token);
  auto redo=DocumentSession::prepareHistory(document.historySnapshot(),Direction::redo);
  document.markMetadataChanged();
  check(document.commitPreparedHistory(redo) && document.isDirty() && document.buffer().text()==u"one two",
      "unrelated metadata changes do not corrupt a prepared redo");
  auto obsolete=DocumentSession::prepareHistory(document.historySnapshot(),Direction::undo);
  const auto encoded=document.makeSaveSnapshot();
  check(document.load(encoded.encoded.bytes).ok(),"same-content reload fixture succeeds");
  check(!document.commitPreparedHistory(obsolete) && !document.isDirty(),"reload invalidates prepared history even when text matches");
  DocumentSession saved;
  saved.insert(0,u"saved"); saved.markSaved(saved.makeSaveSnapshot().token); saved.insert(5,u"!");
  auto toSaved=DocumentSession::prepareHistory(saved.historySnapshot(),Direction::undo);
  check(saved.commitPreparedHistory(toSaved) && !saved.isDirty(),"undo to the saved text state clears only text dirty state");
  auto toEdited=DocumentSession::prepareHistory(saved.historySnapshot(),Direction::redo);
  check(saved.commitPreparedHistory(toEdited) && saved.isDirty(),"redo away from saved state restores text dirty state");
}
void cancellationAndConcurrentPreparation() {
  DocumentSession document; document.insert(0,u"base");
  for (unsigned index=0;index<400;++index) document.insert(0,u"x");
  const auto snapshot=document.historySnapshot(); const auto original=snapshot.buffer().text();
  for (unsigned stop : {1u,2u}) {
    unsigned calls=0; bool stopped=false;
    try { (void)DocumentSession::prepareHistory(snapshot,Direction::undo,[&]{return ++calls==stop;}); }
    catch (const std::runtime_error&) { stopped=true; }
    check(stopped && calls==stop && document.buffer().text()==original && document.canUndo() && !document.canRedo(),
        "every preparation cancellation checkpoint preserves source and both stacks");
  }
  bool propagated=false;
  try { (void)DocumentSession::prepareHistory(snapshot,Direction::undo,[]{throw std::logic_error("history callback");return false;}); }
  catch (const std::logic_error& error) { propagated=std::string(error.what())=="history callback"; }
  check(propagated,"throwing cancellation callback preserves its exception outside C++ preparation");
  std::atomic<bool> okay{true}; std::vector<std::thread> readers;
  for (unsigned reader=0;reader<4;++reader) readers.emplace_back([snapshot,&okay,&original] {
    for (unsigned run=0;run<80;++run) {
      auto undo=DocumentSession::prepareHistory(snapshot,Direction::undo);
      auto redo=DocumentSession::prepareHistory(snapshot,Direction::redo);
      if (!undo.hasChanges() || undo.resultingBuffer().text()!=original.substr(1) ||
          undo.resultingBuffer().revision()!=snapshot.buffer().revision()+1 || redo.hasChanges() ||
          redo.resultingBuffer().text()!=original) okay=false;
    }
  });
  for (unsigned index=0;index<200;++index) { document.insert(0,u"z"); document.erase({0,1}); }
  for (auto& reader:readers) reader.join();
  check(okay && document.buffer().text()==original,"four workers prepare immutable history while the live document is edited");
  auto stale=DocumentSession::prepareHistory(snapshot,Direction::undo);
  check(!document.commitPreparedHistory(stale),"worker result still rejects newer history after equal-text edits");
}
void deadOwnerAndLongHistoryRelease() {
  EditEngine::HistorySnapshot retained;
  {
    TextBuffer buffer(u"a"); EditEngine engine(buffer); engine.insert(1,u"b");
    retained=engine.historySnapshot();
  }
  auto afterDeath=EditEngine::prepareHistory(retained,Direction::undo);
  check(afterDeath.resultingBuffer().text()==u"a","captured immutable history can be prepared after its owner dies");
  TextBuffer foreignBuffer(u"ab"); EditEngine foreign(foreignBuffer);
  check(!foreign.commitPreparedHistory(afterDeath),"a dead owner's token cannot authenticate a new editor");
  for (unsigned round=0;round<5;++round) {
    TextBuffer buffer(u"a");
    auto engine=std::make_unique<EditEngine>(buffer);
    for (unsigned edit=0;edit<40000;++edit) engine->replace({0,1},edit%2?u"a":u"b");
    std::vector<EditEngine::HistorySnapshot> snapshots;
    for (unsigned owner=0;owner<8;++owner) snapshots.push_back(engine->historySnapshot());
    auto prepared=EditEngine::prepareHistory(snapshots.front(),Direction::undo);
    engine.reset();
    // Each independently captured pimpl owns the same long chain. The final
    // shared_ptr release can race in different threads, not just one pimpl.
    std::barrier gate(5);
    std::vector<std::thread> owners;
    for (unsigned owner=0;owner<4;++owner) {
      auto first=std::move(snapshots[owner*2]), second=std::move(snapshots[owner*2+1]);
      owners.emplace_back([first=std::move(first),second=std::move(second),&gate]() mutable {
        gate.arrive_and_wait(); first={}; second={};
      });
    }
    snapshots.clear();
    if (round%2) prepared=EditEngine::PreparedHistory{};
    gate.arrive_and_wait();
    for (auto& owner:owners) owner.join();
    std::thread disposal([prepared=std::move(prepared)]() mutable { prepared=EditEngine::PreparedHistory{}; });
    disposal.join();
  }
  check(true,"long history snapshots and prepared plans release without recursive stack overflow");
}
} // namespace
int main() {
  randomHistoryMatchesStringStates();
  compoundRevisionAndHeapChecks();
  stalePlansAndUntrackedWrites();
  documentMetadataSaveAndReload();
  cancellationAndConcurrentPreparation();
  deadOwnerAndLongHistoryRelease();
  if (failures) std::cerr << failures << " prepared history test(s) failed\n";
  else std::cout << "All prepared history tests passed\n";
  return failures?1:0;
}
