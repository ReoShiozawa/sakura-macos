// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#include "sakura/app/DocumentSession.h"
#include <atomic>
#include <algorithm>
#include <chrono>
#include <iostream>
#include <random>
#include <thread>

namespace {
using namespace sakura::core;
using sakura::app::DocumentSession;
int failures{};
void check(bool value, const char* label) { if (!value) { ++failures; std::cerr << label << '\n'; } }
void originalRangeEditsMatchNaiveAssembly() {
  std::mt19937 random(0xA110ED17);
  for (int run = 0; run < 2000; ++run) {
    SakuraString text;
    const SakuraString pieces[]{u"a",u"b",u"\r",u"\n",u"😀",u"あ",u"\t"};
    for (int i = 0; i < 40; ++i) text += pieces[random() % std::size(pieces)];
    TextBuffer buffer(text); EditEngine editor(buffer);
    std::vector<TextOffset> boundaries;
    for (TextOffset offset = 0; offset <= buffer.length(); ++offset) if (buffer.isEditBoundary(offset)) boundaries.push_back(offset);
    std::vector<EditReplacement> edits;
    std::size_t cursor = 0;
    while (cursor < boundaries.size()) {
      const auto first = cursor;
      const auto last = std::min(boundaries.size() - 1, cursor + random() % 4);
      edits.push_back({{boundaries[first],boundaries[last]-boundaries[first]},pieces[random()%std::size(pieces)]});
      cursor = last + 1 + random() % 5;
    }
    auto expected = text;
    for (auto edit = edits.rbegin(); edit != edits.rend(); ++edit) expected.replace(edit->range.location,edit->range.length,edit->text);
    const auto revision = buffer.revision();
    auto prepared = EditEngine::prepareOriginalRanges(editor.snapshot(),edits);
    check(buffer.text() == text && buffer.revision() == revision && !editor.canUndo(), "preparation never edits source/history");
    check(editor.commitPrepared(prepared) && buffer.text() == expected, "grouped original-range edit matches naive assembly");
    check(!editor.commitPrepared(prepared), "prepared edit cannot commit twice");
    if (prepared.hasChanges()) {
      check(editor.undo() && buffer.text() == text && buffer.revision() > revision, "snapshot undo restores joined CRLF/surrogates exactly");
      check(editor.redo() && buffer.text() == expected, "snapshot redo restores prepared text exactly");
    }
    check(buffer.storageStatistics().valid, "bulk edit preserves AVL/text aggregate invariants");
  }
}
void staleOwnersHistoryAndSaveStates() {
  DocumentSession doc;
  doc.insert(0,u"cat cat"); const auto token = doc.makeSaveSnapshot().token; doc.markSaved(token);
  auto snapshot = doc.editSnapshot();
  auto prepared = DocumentSession::prepareReplaceAll(snapshot,u"cat",u"dog");
  doc.insert(0,u"!"); check(doc.undo(),"fixture undo");
  check(doc.buffer().text() == u"cat cat" && !doc.commitPreparedReplacement(prepared), "edit/undo to equal text still invalidates prepared version");
  auto fresh = DocumentSession::prepareReplaceAll(doc.editSnapshot(),u"cat",u"dog");
  DocumentSession other;
  other.insert(0,u"cat cat");
  check(!other.commitPreparedReplacement(fresh), "another editor cannot consume a foreign plan");
  check(!doc.commitPreparedReplacement(fresh), "a rejected commit attempt consumes the plan");
  auto applicable = DocumentSession::prepareReplaceAll(doc.editSnapshot(),u"cat",u"dog");
  doc.setEncodingState({TextEncoding::utf16BigEndian,true});
  check(doc.commitPreparedReplacement(applicable) && doc.buffer().text()==u"dog dog", "metadata change does not replace or corrupt prepared text");
  check(doc.encodingState() == EncodingState{TextEncoding::utf16BigEndian,true} && doc.isDirty(), "prepared commit preserves current encoding and dirty state");
  check(doc.undo() && doc.buffer().text()==u"cat cat" && doc.isDirty(), "undo keeps separately changed encoding metadata");
  doc.setEncodingState({TextEncoding::utf8,false});
  // Returning to a prior encoding still has a newer metadata revision.
  doc.markSaved(doc.makeSaveSnapshot().token);
  auto noOp = DocumentSession::prepareReplaceAll(doc.editSnapshot(),u"cat",u"cat");
  const auto revision = doc.buffer().revision();
  check(!noOp.result.changed && doc.commitPreparedReplacement(noOp) && !doc.isDirty() &&
        doc.buffer().revision()==revision && doc.canRedo(), "no-op commit preserves save marker, redo and text revision");
  auto reloaded = DocumentSession::prepareReplaceAll(doc.editSnapshot(),u"cat",u"dog");
  const auto encoded = doc.makeSaveSnapshot();
  check(doc.load(encoded.encoded.bytes).ok() && !doc.commitPreparedReplacement(reloaded), "same-content reload invalidates source owner generation/history");
}
void cancellationInvalidRangesAndLargeOneLine() {
  TextBuffer buffer(u"a\r\n😀b"); EditEngine editor(buffer);
  for (const std::vector<EditReplacement> edits : {
         std::vector<EditReplacement>{{{2,0},u"bad"}},
         std::vector<EditReplacement>{{{4,0},u"bad"}},
         std::vector<EditReplacement>{{{3,2},u"x"},{{0,1},u"y"}},
         std::vector<EditReplacement>{{{0,3},u"x"},{{1,0},u"y"}}}) {
    bool failed=false;
    try { auto prepared=EditEngine::prepareOriginalRanges(editor.snapshot(),edits); (void)prepared; }
    catch(const std::invalid_argument&) { failed=true; }
    check(failed && buffer.text()==u"a\r\n😀b" && !editor.canUndo(),"bad original ranges never partially edit history/text");
  }
  TextBuffer longLine(SakuraString(200000,u'a')); EditEngine longEditor(longLine);
  std::vector<EditReplacement> edits;
  for(TextOffset offset=0;offset<longLine.length();offset+=2) edits.push_back({{offset,1},u"b"});
  for (int budget : {0,1,20,1000,50000,100010}) {
    int checks=0; bool failed=false;
    try { auto prepared=EditEngine::prepareOriginalRanges(longEditor.snapshot(),edits,[&]{return ++checks>budget;}); (void)prepared; }
    catch(const std::runtime_error&){failed=true;}
    check(failed && !longEditor.canUndo() && longLine.characterAt(0)==u'a',"cancellation during validation/build leaves source unchanged");
  }
  auto prepared=EditEngine::prepareOriginalRanges(longEditor.snapshot(),edits);
  check(longEditor.commitPrepared(prepared) && longLine.slice({0,6})==u"bababa", "100000 changes on one line are grouped");
  check(longEditor.undo() && longLine.characterAt(0)==u'a' && longEditor.redo() && longLine.characterAt(0)==u'b', "large transaction undo/redo uses retained roots");
}
void retainedHistoryAndConcurrentPreparation() {
  EditEngine::PreparedEdit retained;
  {
    TextBuffer buffer(u"a"); EditEngine editor(buffer);
    for(int edit=0;edit<40000;++edit) editor.replace({0,1},edit%2?u"a":u"b");
    retained=EditEngine::prepareOriginalRanges(editor.snapshot(),{{{0,1},u"z"}});
    check(editor.commitPrepared(retained),"retain a prepared entry across owner destruction");
    editor.clearHistory();
  }
  // Destruction must iteratively release the retained history, not recurse.
  retained=EditEngine::PreparedEdit{};
  DocumentSession doc; doc.insert(0,u"a a a a");
  const auto snapshot=doc.editSnapshot();
  std::unique_ptr<sakura::app::PreparedReplaceAll> prepared;
  std::thread worker([&]{prepared=std::make_unique<sakura::app::PreparedReplaceAll>(DocumentSession::prepareReplaceAll(snapshot,u"a",u"longer"));});
  for(int edit=0;edit<200;++edit){doc.insert(0,u"!");doc.erase({0,1});}
  worker.join();
  check(prepared && !doc.commitPreparedReplacement(*prepared) && doc.buffer().text()==u"a a a a", "worker preparation races only independent snapshot, never live document");
}
void cancellationAtEveryPreparationCheckpoint() {
  TextBuffer buffer(u"head\r\na a a\nnext a\ntail");EditEngine editor(buffer);
  const std::vector<EditReplacement> edits{{{6,1},u"long\nvalue"},{{8,1},u"b"},{{17,1},u""}};
  std::size_t calls=0;
  auto complete=EditEngine::prepareOriginalRanges(editor.snapshot(),edits,[&]{++calls;return false;});
  check(complete.hasChanges() && calls>10,"fixture traverses build/copy/cancellation checkpoints");
  for(std::size_t budget=0;budget<calls;++budget) {
    std::size_t observed=0;bool cancelled=false;
    try {auto p=EditEngine::prepareOriginalRanges(editor.snapshot(),edits,[&]{return ++observed>budget;});(void)p;}
    catch(const std::runtime_error&){cancelled=true;}
    check(cancelled && buffer.text()==u"head\r\na a a\nnext a\ntail" && !editor.canUndo(),"every preparation cancellation point preserves live state");
  }
  DocumentSession doc;doc.insert(0,u"a a");
  const auto oldSave=doc.makeSaveSnapshot().token;
  auto p=DocumentSession::prepareReplaceAll(doc.editSnapshot(),u"a",u"b");
  check(doc.commitPreparedReplacement(p),"save/commit fixture applies");doc.markSaved(oldSave);
  check(doc.isDirty() && doc.undo() && !doc.isDirty(),"late old save cannot mark newly replaced text saved");
  SearchOptions limited;limited.maxReplacementCodeUnits=2;
  bool failed=false;
  try {auto oversized=DocumentSession::prepareReplaceAll(doc.editSnapshot(),u"a",u"long",limited);(void)oversized;}
  catch(const std::length_error&){failed=true;}
  check(failed && doc.buffer().text()==u"a a" && doc.canRedo(),"output resource failure preserves text and redo");
}
void untrackedBufferWritesCannotBeUndoneAway() {
  TextBuffer buffer(u"original");EditEngine editor(buffer);
  editor.insert(0,u"own edit ");
  auto plan=EditEngine::prepareOriginalRanges(editor.snapshot(),{{{0,3},u"new"}});
  buffer.replace({0,0},u"EXTERNAL ");
  const auto preserved=buffer.text();
  check(!editor.undo() && !editor.redo() && !editor.commitPrepared(plan) && buffer.text()==preserved,
        "snapshot history cannot overwrite untracked external buffer writes");
  bool rejected=false;
  try{editor.insert(0,u"new");}catch(const std::logic_error&){rejected=true;}
  check(rejected && buffer.text()==preserved,"new history requires explicit reset after untracked writes");
  editor.clearHistory();editor.insert(0,u"safe ");
  check(editor.undo() && buffer.text()==preserved,"explicit reset establishes fresh safe history baseline");
}
void benchmarkLargePreparation() {
  using Clock=std::chrono::steady_clock;
  constexpr std::size_t units=100*1024*1024,rows=1000000;
  SakuraString text(units,u'a');
  const auto content=units-(rows-1),perLine=content/rows,extra=content%rows;
  std::size_t cursor=0;
  for(std::size_t line=0;line<rows;++line){text.replace(cursor,6,u"needle");cursor+=perLine+(line<extra?1:0);if(line+1<rows)text[cursor++]=u'\n';}
  DocumentSession doc;doc.insert(0,text);text.clear();text.shrink_to_fit();
  const auto snapshot=doc.editSnapshot();
  auto start=Clock::now();auto p=DocumentSession::prepareReplaceAll(snapshot,u"needle",u"done");auto prepared=Clock::now();
  check(p.result.replacements==rows && p.result.changed,"million-match benchmark prepares every match");
  auto commit=Clock::now();check(doc.commitPreparedReplacement(p),"large prepared commit");auto committed=Clock::now();
  check(doc.buffer().length()==units-2*rows && doc.buffer().lineCount()==rows && doc.buffer().slice({0,4})==u"done","large output shape and prefix");
  bool everyLine=true;auto lines=doc.buffer().lineCursor();
  for(std::size_t line=0;line<rows;++line,lines.advance()) {
    const auto& value=lines.line();
    if(value.content.size()!=perLine+(line<extra?1:0)-2 || !value.content.starts_with(u"done") ||
       !std::all_of(value.content.begin()+4,value.content.end(),[](SakuraChar c){return c==u'a';}) ||
       value.ending!=(line+1<rows?LineEnding::lineFeed:LineEnding::none)){everyLine=false;break;}
  }
  check(everyLine,"every benchmark output character and line ending is validated");
  auto undo=Clock::now();check(doc.undo(),"large undo");auto undone=Clock::now();
  check(doc.buffer().length()==units && doc.buffer().slice({0,6})==u"needle","large undo restores root");
  auto redo=Clock::now();check(doc.redo(),"large redo");auto redone=Clock::now();
  const auto ms=[](auto t){return std::chrono::duration<double,std::milli>(t).count();};
  std::cout<<"UTF16Units="<<units<<" lines="<<rows<<" replacements="<<p.result.replacements
    <<" prepare_ms="<<ms(prepared-start)<<" commit_ms="<<ms(committed-commit)<<" undo_ms="<<ms(undone-undo)<<" redo_ms="<<ms(redone-redo)<<'\n';
}
}  // namespace
int main(int argc,char**){if(argc>1)benchmarkLargePreparation();else{originalRangeEditsMatchNaiveAssembly();staleOwnersHistoryAndSaveStates();cancellationInvalidRangesAndLargeOneLine();retainedHistoryAndConcurrentPreparation();cancellationAtEveryPreparationCheckpoint();untrackedBufferWritesCannotBeUndoneAway();}return failures?1:0;}
