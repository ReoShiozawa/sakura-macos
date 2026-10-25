// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import "SakuraDocument.h"
#import "SakuraEditorView.h"
#import "SakuraWindowController.h"
#include "sakura/core/syntax/SyntaxHighlighter.h"
#include <iostream>
#include <algorithm>
#include <random>
#include <set>
#include "sakura/core/encoding/Utf8Codec.h"
#import "SyntaxTestSupport.h"

@interface SakuraEditorView (SyntaxTesting)
- (const std::vector<sakura::core::SyntaxToken>&)activeSyntaxTokens;
@end
@interface SakuraDocument (BookmarkTesting)
- (NSDictionary*)bookmarkSynchronizationStatistics;
@end
@interface SakuraWindowController (OutlineTesting)
- (NSArray<NSDictionary*>*)buildOutlineEntries;
- (void)prepareGrepPanel;
@end
@interface CoreFeatureDocument : SakuraDocument
@end
@implementation CoreFeatureDocument
- (void)noteEditorChange:(NSDocumentChangeType)change { (void)change; }
@end
namespace {
int failures = 0;
void check(bool ok, const char* label) { if (!ok) { std::cerr << label << '\n'; ++failures; } }
void checkOutline(NSString* extension, NSString* text, NSUInteger count) {
  CoreFeatureDocument* doc = [[CoreFeatureDocument alloc] init];
  doc.fileURL = [NSURL fileURLWithPath:[@"/Demo/file." stringByAppendingString:extension]];
  check([doc readFromData:[text dataUsingEncoding:NSUTF8StringEncoding] ofType:@"public.plain-text" error:nil], "load syntax fixture");
  SakuraWindowController* controller = [[SakuraWindowController alloc] initWithDocument:doc];
  [doc addWindowController:controller];
  check(SakuraWaitForSyntax(controller.editorView), "language syntax worker completes");
  const auto& tokens = [controller.editorView activeSyntaxTokens];
  check(!tokens.empty(), "file extension selects language in editor renderer");
  NSRect visible = NSMakeRect(0, 0, 700, MIN(250.0, controller.editorView.bounds.size.height));
  NSBitmapImageRep* bitmap = [controller.editorView bitmapImageRepForCachingDisplayInRect:visible];
  [controller.editorView cacheDisplayInRect:visible toBitmapImageRep:bitmap];
  check(bitmap != nil, "language colors render to an offscreen bitmap");
  auto entries = [controller buildOutlineEntries];
  if (entries.count != count) {
    std::cerr << extension.UTF8String << " outline count " << entries.count << " expected " << count << '\n'; ++failures;
  }
  for (NSDictionary* entry in entries) check(![entry[@"title"] containsString:@"hidden"], "outline excludes comments and multiline strings");
  [controller.window close]; [doc removeWindowController:controller];
}

using namespace sakura::core;
std::vector<TextOffset> referenceLineStarts(SakuraStringView text) {
  std::vector<TextOffset> result{0};
  for (TextOffset at=0;at<text.size();) {
    const auto value=text[at++];
    if (value==u'\r') {
      if (at<text.size() && text[at]==u'\n') ++at;
      result.push_back(at);
    } else if (value==u'\n') result.push_back(at);
  }
  return result;
}
NSUInteger referenceLine(SakuraStringView text,TextOffset offset) {
  const auto starts=referenceLineStarts(text);
  return std::upper_bound(starts.begin(),starts.end(),offset)-starts.begin()-1;
}
bool referenceBoundary(SakuraStringView text,TextOffset offset) {
  return !offset || offset==text.size() ||
      !((text[offset-1]==u'\r' && text[offset]==u'\n') ||
        (text[offset-1]>=0xd800 && text[offset-1]<=0xdbff &&
         text[offset]>=0xdc00 && text[offset]<=0xdfff));
}
std::set<TextOffset> referenceBookmarks(SakuraStringView old,SakuraStringView text,
                                       const std::set<TextOffset>& anchors) {
  std::size_t prefix=0,suffix=0;
  while (prefix<old.size() && prefix<text.size() && old[prefix]==text[prefix]) ++prefix;
  while (suffix<old.size()-prefix && suffix<text.size()-prefix &&
         old[old.size()-suffix-1]==text[text.size()-suffix-1]) ++suffix;
  std::set<TextOffset> result;
  for (const auto anchor:anchors) result.insert(anchor<prefix ? anchor :
      anchor>=old.size()-suffix ? text.size()-(old.size()-anchor) : prefix);
  return result;
}
struct BookmarkFixture {
  CoreFeatureDocument* document;
  SakuraString previous;
  std::set<TextOffset> anchors;
  explicit BookmarkFixture(SakuraStringView text) : previous(text) {
    document=[[CoreFeatureDocument alloc]init];
    document.documentSession.insert(0,text);
  }
  void verify() {
    NSIndexSet* raw=[document valueForKey:@"bookmarkAnchors"];
    NSMutableIndexSet* expectedRaw=[NSMutableIndexSet indexSet];
    NSMutableIndexSet* expectedLines=[NSMutableIndexSet indexSet];
    for (const auto anchor:anchors) {
      [expectedRaw addIndex:anchor];
      [expectedLines addIndex:referenceLine(previous,anchor)];
    }
    check([(raw?raw:NSIndexSet.indexSet) isEqualToIndexSet:expectedRaw],"bookmark raw offsets equal the independent legacy prefix/suffix reference");
    NSIndexSet* lines=document.bookmarkLines;
    check([lines isEqualToIndexSet:expectedLines],"bookmark logical lines agree with the independent mixed-EOL reference");
    for (NSUInteger line=lines.firstIndex;line!=NSNotFound;line=[lines indexGreaterThanIndex:line])
      check(document.documentSession.buffer().isEditBoundary(document.documentSession.buffer().lineStartOffset(line)),
          "public bookmark jump positions remain valid CRLF/surrogate boundaries");
    NSDictionary* statistics=document.bookmarkSynchronizationStatistics;
    check([statistics[@"hasSnapshot"] boolValue]==!anchors.empty(),"only documents with bookmarks retain a text snapshot");
    if (!anchors.empty()) check([statistics[@"snapshotMatchesCurrent"] boolValue],"bookmark snapshot authenticates both source root and revision");
  }
  void sync(bool refresh=true) {
    auto text=document.documentSession.buffer().text();
    anchors=referenceBookmarks(previous,text,anchors);
    previous=std::move(text);
    if (refresh) [document refreshEditorViews]; else (void)document.bookmarkLines;
    verify();
  }
  void toggle(NSUInteger line) {
    sync();
    const auto starts=referenceLineStarts(previous);
    if (line<starts.size()) {
      bool removed=false;
      for (auto cursor=anchors.begin();cursor!=anchors.end();) {
        if (referenceLine(previous,*cursor)==line) { cursor=anchors.erase(cursor);removed=true; }
        else ++cursor;
      }
      if (!removed) anchors.insert(starts[line]);
    }
    const auto source=document.documentSession.buffer();
    const auto dirty=document.isDocumentEdited;
    [document toggleBookmarkAtLine:line];
    verify();
    check(document.documentSession.buffer().sharesStorageWith(source) &&
          document.documentSession.buffer().revision()==source.revision() && document.isDocumentEdited==dirty,
        "toggling bookmarks never changes text/history or saved state");
  }
};

void sharedBookmarkSemantics() {
  BookmarkFixture f(u"a\nb\nc\n");
  f.document.documentSession.markSaved(f.document.documentSession.makeSaveSnapshot().token);
  for (NSUInteger line:{0,1,2,3}) f.toggle(line);
  f.document.documentSession.insert(0,u"prefix\n");f.sync(false);
  check([f.document.bookmarkLines containsIndex:1] && [f.document.bookmarkLines containsIndex:4],"prefix insertion shifts original lines and EOF bookmark");
  check(f.document.documentSession.undo(),"bookmark prefix fixture Undo");f.sync();
  check(!f.document.isDocumentEdited,"bookmark correction keeps the restored saved text clean");
  f.document.documentSession.replace({2,1},u"B");f.sync();
  f.document.documentSession.insert(4,u"new\n");f.sync();
  f.document.documentSession.insert(f.document.documentSession.buffer().length(),u"tail");f.sync();
  check(f.anchors.contains(f.previous.size()),"an old EOF anchor always follows the new EOF");
  check(f.document.documentSession.undo(),"bookmark suffix fixture Undo");f.sync();
  check(f.document.documentSession.redo(),"bookmark suffix fixture Redo");f.sync();
  f.toggle(9999);

  BookmarkFixture separated(u"alpha\nbeta\ngamma\ndelta\n");
  for (NSUInteger line:{0,1,2,3,4}) separated.toggle(line);
  separated.document.documentSession.replace({0,1},u"A");
  separated.document.documentSession.replace({17,1},u"D");
  separated.sync();
  check(separated.anchors==std::set<TextOffset>{0,separated.previous.size()},
      "batched disjoint edits retain the legacy enclosing-change collapse, not invented per-edit tracking");
  separated.toggle(0);check(separated.document.bookmarkLines.count==1,"toggling a line removes every collapsed bookmark anchor on that line");

  BookmarkFixture repeated(u"foo\nfoo\n");
  repeated.toggle(0);repeated.toggle(1);repeated.toggle(2);
  repeated.document.documentSession.insert(0,u"foo\n");repeated.sync();
  check(repeated.anchors==std::set<TextOffset>{0,4,12},"a maximal common character prefix may extend into the shared suffix after repeated-line insertion");
  repeated.document.documentSession.erase({0,4});repeated.sync();

  BookmarkFixture empty(u"");empty.toggle(0);
  empty.document.documentSession.insert(0,u"first\nsecond\n");empty.sync();
  check(empty.anchors==std::set<TextOffset>{empty.previous.size()},"bookmark from an empty document preserves legacy EOF anchoring");
  empty.document.documentSession.erase({0,empty.previous.size()});empty.sync();
}

void bookmarkUnicodeReloadAndFailures() {
  for (const auto& original:{SakuraString(u"\rX\nfoo"),SakuraString{SakuraChar(0xd83d),u'\n',SakuraChar(0xde00)}}) {
    BookmarkFixture f(original);f.toggle(0);f.toggle(1);
    f.document.documentSession.erase({1,1});f.sync();
    check(f.anchors.contains(1),"legacy raw anchors may remain inside a newly joined CRLF/surrogate");
    check(f.document.documentSession.undo(),"Unicode join bookmark Undo");f.sync();
    check(f.document.documentSession.redo(),"Unicode join bookmark Redo");f.sync();
  }
  BookmarkFixture f(u"桜😀\r\nnext\rlast\n");
  f.toggle(0);f.toggle(1);f.toggle(2);f.toggle(3);
  f.document.documentSession.setEncodingState({sakura::core::TextEncoding::utf16BigEndian,true});
  f.sync();check(f.document.isDocumentEdited,"bookmark synchronization preserves unsaved encoding metadata");
  f.document.documentSession.markSaved(f.document.documentSession.makeSaveSnapshot().token);
  const auto savedAnchors=f.anchors;
  f.sync();check(!f.document.isDocumentEdited && f.anchors==savedAnchors,"successful save leaves bookmarks and clean state unchanged");
  for (const auto& replacement:{SakuraString(u"桜😀\r\nnext\rlast\n"),SakuraString(u"new\n😀\r\n"),SakuraString(u"")}) {
    const auto encoded=Utf8Codec::encode(replacement);
    check(encoded.ok(),"reload bookmark fixture encodes");
    check([f.document readFromData:[NSData dataWithBytes:encoded.bytes.data() length:encoded.bytes.size()]
        ofType:@"public.plain-text" error:nil],"bookmark reload succeeds");
    f.sync();check(!f.document.isDocumentEdited,"reload plus bookmark mapping preserves clean state");
  }
  const unsigned char invalid[]{0xef,0xbb,0xbf,0xff};
  const auto before=f.document.documentSession.buffer();
  check(![f.document readFromData:[NSData dataWithBytes:invalid length:sizeof(invalid)] ofType:@"public.plain-text" error:nil],"failed explicit-BOM reload is rejected");
  f.sync();check(f.document.documentSession.buffer().sharesStorageWith(before),"failed reload preserves bookmark source identity");
  [f.document clearBookmarks];f.anchors.clear();f.verify();
}

void bookmarkRandomReferenceAndBoundedReads() {
  std::mt19937 random(0x424f4f4b);
  const SakuraString pieces[]{u"a",u"x",u" ",u"\r",u"\n",u"\r\n",u"😀",u"桜",
      SakuraString(1,0xd800),SakuraString(1,0xdc00),u""};
  for (unsigned trial=0;trial<120;++trial) {
    SakuraString source;for (unsigned at=0;at<22;++at) source+=pieces[random()%std::size(pieces)];
    BookmarkFixture f(source);
    f.toggle(0);f.toggle(referenceLineStarts(source).size()-1);
    for (unsigned edit=0;edit<12;++edit) {
      const auto text=f.document.documentSession.buffer().text();
      std::vector<TextOffset> boundaries;
      for (TextOffset at=0;at<=text.size();++at) if (referenceBoundary(text,at)) boundaries.push_back(at);
      auto first=boundaries[random()%boundaries.size()],last=boundaries[random()%boundaries.size()];
      if (first>last) std::swap(first,last);
      f.document.documentSession.replace({first,last-first},pieces[random()%std::size(pieces)]);
      if (edit%2) f.sync(edit%3);
      if (edit%5==4 && f.document.documentSession.undo()) f.sync();
    }
    f.sync();
  }
  SakuraString large;
  for (unsigned line=0;line<20000;++line) { large.append(100,u'x');large+=u'\n'; }
  BookmarkFixture f(large);f.toggle(0);f.toggle(10000);f.toggle(19999);f.toggle(20000);
  const auto middle=10000ULL*101+50;
  f.document.documentSession.insert(middle,u"Q");f.sync();
  NSDictionary* statistics=f.document.bookmarkSynchronizationStatistics;
  check([statistics[@"comparedTextNodes"] unsignedIntegerValue]<512 &&
        [statistics[@"copiedCodeUnits"] unsignedLongLongValue]<16384 &&
        [statistics[@"peakWindowCodeUnits"] unsignedIntegerValue]<=4096,
      "local bookmark correction skips shared subtrees and uses bounded windows rather than materializing a changed region");
  [f.document clearBookmarks];f.anchors.clear();f.verify();
  f.toggle(0);
  f.document.documentSession.insert(f.document.documentSession.buffer().length()-3,u"Z");f.sync();
  statistics=f.document.bookmarkSynchronizationStatistics;
  check([statistics[@"copiedCodeUnits"] unsignedLongLongValue]==0 &&
        [statistics[@"comparedTextNodes"] unsignedIntegerValue]<512,
      "bookmarks entirely in the unchanged shared prefix require no character copy");
}
}
int main() {
  @autoreleasepool {
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    sharedBookmarkSemantics();
    bookmarkUnicodeReloadAndFailures();
    bookmarkRandomReferenceAndBoundedReads();
    checkOutline(@"py", @"# def hidden():\ns = '''\ndef hidden():\n'''\nasync def real():\n pass\nclass Public:\n pass", 2);
    checkOutline(@"js", @"// function hidden() {}\nconst f = x => x;\nexport function real() {}\nconst s = `\nfunction hidden() {}\n`;", 2);
    checkOutline(@"ts", @"export interface Real {}\nexport type Name = string;\nconst f = (x) => x;", 3);
    checkOutline(@"rs", @"/* fn hidden() {} */\npub struct Real {}\npub async fn run() {}", 2);
    checkOutline(@"go", @"package main\n// func hidden() {}\nfunc (r Real) Run() {}\ntype Real struct {}", 2);
    checkOutline(@"rb", @"# def hidden\nclass Real\ndef run\nend\nend", 2);
    checkOutline(@"sql", @"-- CREATE TABLE hidden;\nCREATE TABLE real (id INT);\ncreate view v as select * from real;", 2);
    checkOutline(@"md", @"# Real\n```python\n# hidden\n```\n## Second\n", 2);
    checkOutline(@"cpp", @"/*\nclass hidden {};\n*/\nclass Real {};\nvoid run() {}", 2);
    {
      CoreFeatureDocument* doc = [[CoreFeatureDocument alloc] init];
      doc.fileURL = [NSURL fileURLWithPath:@"/Demo/marked.py"];
      SakuraEditorView* editor = [[SakuraEditorView alloc] initWithFrame:NSMakeRect(0, 0, 700, 200) document:doc];
      [editor setMarkedText:@"def live():\n pass" selectedRange:NSMakeRange(0, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
      check(SakuraWaitForSyntax(editor), "first IME syntax worker completes");
      auto first = [editor activeSyntaxTokens];
      check(!first.empty() && first.front().kind == sakura::core::SyntaxTokenKind::keyword, "marked text receives language colors");
      [editor setMarkedText:@"# comment" selectedRange:NSMakeRange(0, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
      check(SakuraWaitForSyntax(editor), "second IME syntax worker completes");
      auto second = [editor activeSyntaxTokens];
      check(second.size() == 1 && second.front().kind == sakura::core::SyntaxTokenKind::comment,
            "syntax cache updates while composition remains active");
      check(doc.documentSession.buffer().length() == 0 && !doc.isDocumentEdited,
            "IME syntax never commits or changes document text");
    }
    // Panel construction is offscreen; inspect new controls without choosing
    // folders, opening files, changing preferences or showing native panels.
    CoreFeatureDocument* doc = [[CoreFeatureDocument alloc] init];
    SakuraWindowController* controller = [[SakuraWindowController alloc] initWithDocument:doc];
    [doc addWindowController:controller]; [controller prepareGrepPanel];
    NSPopUpButton* encoding = [controller valueForKey:@"grepEncodingPopup"];
    NSButton* word = [controller valueForKey:@"grepWholeWordButton"];
    NSPanel* panel = [controller valueForKey:@"grepPanel"];
    check(encoding.numberOfItems == 7 && word != nil, "Grep encoding and whole-word controls exist");
    check(NSContainsRect(panel.contentView.bounds, encoding.frame) && NSContainsRect(panel.contentView.bounds, word.frame), "Grep new controls inside panel");
    NSScrollView* results = ((NSTableView*)[controller valueForKey:@"grepTableView"]).enclosingScrollView;
    check(!NSIntersectsRect(results.frame, encoding.frame), "encoding control does not overlap results");
    [controller.window close]; [doc removeWindowController:controller];
  }
  return failures ? 1 : 0;
}
