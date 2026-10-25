// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import "SakuraDocument.h"
#import "SakuraEditorView.h"
#import "SakuraSyntaxSettings.h"
#import "SyntaxTestSupport.h"
#include "sakura/platform/mac/StringBridge.h"
#include <functional>
#include <iostream>
#include <memory>
#include <chrono>
#include <string_view>

@interface SakuraEditorView (AsyncSyntaxTests)
- (NSDictionary*)renderingStatistics;
- (NSString*)displayString;
- (void)clearMarkedState;
- (void)prepareSyntax;
- (std::vector<sakura::core::SyntaxToken>)syntaxTokensInRange:(NSRange)range;
@end
@interface AsyncSyntaxDocument : SakuraDocument
@end
@implementation AsyncSyntaxDocument
- (void)noteEditorChange:(NSDocumentChangeType)change { (void)change; }
@end
@interface AsyncSyntaxEditor : SakuraEditorView
@property(nonatomic, copy) NSDictionary* testPreferences;
@end
@implementation AsyncSyntaxEditor
- (NSDictionary*)syntaxPreferences { return self.testPreferences ?: @{}; }
@end

namespace {
using namespace sakura::core;
int failures = 0;
void check(bool okay, const char* message) { if (!okay) { std::cerr << message << '\n'; ++failures; } }
bool pump(const std::function<bool()>& predicate) {
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:8];
  while (!predicate() && deadline.timeIntervalSinceNow > 0)
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
  return predicate();
}
bool same(const std::vector<SyntaxToken>& a, const std::vector<SyntaxToken>& b) {
  if (a.size() != b.size()) return false;
  for (std::size_t i = 0; i < a.size(); ++i)
    if (a[i].range.location != b[i].range.location || a[i].range.length != b[i].range.length ||
        a[i].kind != b[i].kind || a[i].keywordGroup != b[i].keywordGroup) return false;
  return true;
}
NSDictionary* rules(NSString* words, NSString* patterns = @"") {
  return @{ @"keywords":words, @"patterns":patterns, @"caseSensitive":@YES };
}
struct Fixture {
  AsyncSyntaxDocument* doc;
  AsyncSyntaxEditor* view;
  Fixture(NSString* text, NSString* extension = @"cpp") {
    doc = [[AsyncSyntaxDocument alloc] init];
    doc.fileURL = [NSURL fileURLWithPath:[@"/async-syntax/test." stringByAppendingString:extension]];
    doc.documentSession.insert(0, sakura::platform::mac::sakuraStringFromString(text));
    view = [[AsyncSyntaxEditor alloc] initWithFrame:NSMakeRect(0,0,700,200) document:doc];
  }
  NSUInteger stat(NSString* key) { return [[view renderingStatistics][key] unsignedIntegerValue]; }
  void reference() {
    check(SakuraWaitForSyntax(view), "syntax pipeline completes");
    auto text = sakura::platform::mac::sakuraStringFromString([view displayString]);
    auto language = SyntaxHighlighter::languageForExtension(doc.fileURL.pathExtension.UTF8String);
    auto expected = SyntaxHighlighter{}.highlight(TextBuffer(text), language);
    if (!same([view activeSyntaxTokens], expected)) {
      std::cerr << "async reference type=" << doc.fileURL.pathExtension.UTF8String << " display=" << text.size()
                << " actual=" << [view activeSyntaxTokens].size() << " expected=" << expected.size() << '\n';
    }
    check(same([view activeSyntaxTokens], expected),
          "async base tokens equal full synchronous reference for exact displayed UTF-16");
  }
};

void ordinaryAndLanguageModes() {
  Fixture f(@"int value = 7; /* 桜😀 */\r\n");
  auto textBuilds = f.stat(@"textBuilds");
  check([f.view activeSyntaxTokens].empty() && f.view.hasPendingSyntax, "initial request is asynchronous, never scans in draw");
  check(f.view.syntaxStatus.length > 0, "ordinary syntax pending status visible without a window");
  f.reference();
  check(!f.stat(@"syntaxWorkerOnMain") && f.stat(@"syntaxCompletions") == 1, "ordinary analysis runs off the main thread");
  check(f.stat(@"textBuilds") == textBuilds, "syntax scheduling/commit does not serialize a new display NSString");
  auto builds = f.stat(@"syntaxBuilds");
  for (int i = 0; i < 100; ++i) (void)[f.view activeSyntaxTokens];
  check(f.stat(@"syntaxBuilds") == builds && !f.view.hasPendingSyntax, "warm color lookup reuses the accepted immutable result");
  for (NSString* ext in @[@"c",@"cpp",@"m",@"swift",@"java",@"cs",@"js",@"ts",@"py",@"json",@"sh",@"rb",@"sql",
                           @"html",@"xml",@"css",@"md",@"yaml",@"toml",@"ini",@"go",@"rs"]) {
    Fixture language(@"# name\r\n/* comment */\nconst x = \"桜😀\"; true 1.5\n<tag key='v'>text</tag>\n```\ncode\n```", ext);
    language.reference();
  }
  Fixture plain(@"ordinary text", @"txt");
  check([plain.view activeSyntaxTokens].empty() && !plain.view.hasPendingSyntax, "plain documents without extra rules do not start a worker");
}

void staleSourcesAndConditions() {
  Fixture f(@"int old = 1;");
  (void)[f.view activeSyntaxTokens];
  f.doc.documentSession.replace({0, f.doc.documentSession.buffer().length()}, u"// newest");
  [f.view documentContentsDidChange];
  check(!f.view.hasPendingSyntax, "edit notification cancels analysis before another draw");
  check([f.view activeSyntaxTokens].empty(), "edit immediately hides old offsets");
  f.reference();
  check(pump([&] { return f.stat(@"syntaxDiscards") >= 1; }), "cancelled snapshot is discarded");

  // No refresh, redraw or property-change notification: completion must inspect
  // actual current conditions, not rely solely on an observer or cached key.
  Fixture reload(@"int old;");
  (void)[reload.view activeSyntaxTokens];
  const auto revision = reload.doc.documentSession.buffer().revision();
  auto& direct = const_cast<TextBuffer&>(reload.doc.documentSession.buffer());
  TextBuffer different(u"// replacement root");
  while (different.revision() < revision) different.assign(u"// replacement root");
  direct = different;
  check(direct.revision() == revision, "fixture changes text root while keeping the revision number");
  check(pump([&] { return reload.stat(@"syntaxDiscards") == 1; }), "same revision with a different root cannot accept stale analysis");
  reload.reference();

  Fixture ext(@"int old;");
  (void)[ext.view activeSyntaxTokens];
  ext.doc.fileURL = [NSURL fileURLWithPath:@"/async-syntax/test.txt"];
  check(pump([&] { return ext.stat(@"syntaxDiscards") == 1; }), "file-type change without drawing rejects old language result");
  ext.reference();

  Fixture prefs(@"old new", @"txt"); prefs.view.testPreferences = rules(@"old");
  (void)[prefs.view activeSyntaxTokens];
  prefs.view.testPreferences = rules(@"new");
  check(pump([&] { return prefs.stat(@"syntaxDiscards") == 1; }), "unnotified rule change rejects the old pipeline");
  check(SakuraWaitForSyntax(prefs.view), "new rules complete after discarded request");
  const auto& tokens = [prefs.view activeSyntaxTokens];
  check(tokens.size() == 1 && tokens.front().range.location == 4, "only latest extra rules apply");

  Fixture undo(@"int original;"); (void)[undo.view activeSyntaxTokens];
  undo.doc.documentSession.insert(0,u"x"); undo.doc.documentSession.undo();
  check(pump([&] { return undo.stat(@"syntaxDiscards") == 1; }), "edit/undo to identical text still rejects old generation");
  undo.reference();

  Fixture stopped(@"int pending;"); (void)[stopped.view activeSyntaxTokens];
  [stopped.view cancelOperation:nil];
  check(!stopped.view.hasPendingSyntax && [stopped.view activeSyntaxTokens].empty() &&
        [stopped.view.syntaxStatus containsString:@"中止"], "Escape cancels analysis and does not immediately restart in the next draw");
  check(pump([&] { return stopped.stat(@"syntaxDiscards") == 1; }), "explicitly stopped worker discards its result");
  stopped.doc.documentSession.insert(0,u"// "); [stopped.view documentContentsDidChange];
  stopped.reference();
}

void compositionAndLifetime() {
  Fixture f(@"int value;", @"py"); (void)[f.view activeSyntaxTokens];
  [f.view setMarkedText:@"'''# protected\n桜😀'''" selectedRange:NSMakeRange(0,0) replacementRange:NSMakeRange(0,0)];
  check(!f.view.hasPendingSyntax, "IME starts cancels committed-text request before draw");
  f.reference();
  const auto revision = f.doc.documentSession.buffer().revision();
  const auto text = f.doc.documentSession.buffer().text();
  const auto builds = f.stat(@"syntaxBuilds");
  [f.view setMarkedText:[@"'''# protected\n桜😀'''" mutableCopy] selectedRange:NSMakeRange(2,0) replacementRange:NSMakeRange(NSNotFound,0)];
  (void)[f.view activeSyntaxTokens];
  check(f.stat(@"syntaxBuilds") == builds && !f.view.hasPendingSyntax, "equal IME text with a different caret reuses syntax");
  [f.view setMarkedText:@"def pending():" selectedRange:NSMakeRange(0,0) replacementRange:NSMakeRange(NSNotFound,0)];
  (void)[f.view activeSyntaxTokens];
  [f.view setMarkedText:@"# newest" selectedRange:NSMakeRange(0,0) replacementRange:NSMakeRange(NSNotFound,0)];
  f.reference();
  check(f.doc.documentSession.buffer().text() == text && f.doc.documentSession.buffer().revision() == revision,
        "coloring IME previews never commits text or dirties the document");
  (void)[f.view activeSyntaxTokens]; [f.view clearMarkedState];
  f.reference();
  __weak SakuraEditorView* released;
  @autoreleasepool {
    Fixture closing(@"int pending;"); released = closing.view;
    (void)[closing.view activeSyntaxTokens];
  }
  check(released == nil, "queued syntax does not retain the editor or document");
  check(pump([&] { return f.stat(@"syntaxDiscards") >= 2; }), "superseded IME results settle without lifetime errors");
}

void customMaskAndFailures() {
  Fixture f(@"special /* special */ \"special\" special"); f.view.testPreferences = rules(@"special");
  check(SakuraWaitForSyntax(f.view), "base and additional syntax complete");
  const auto& tokens = [f.view activeSyntaxTokens];
  check(tokens.size() == 4 && tokens[0].kind == SyntaxTokenKind::keyword && tokens[1].kind == SyntaxTokenKind::comment &&
        tokens[2].kind == SyntaxTokenKind::string && tokens[3].kind == SyntaxTokenKind::keyword,
        "custom words never recolor comments/strings: base mask precedes custom processing");
  f.view.testPreferences = rules(@"", @"(");
  check(SakuraWaitForSyntax(f.view), "invalid extra rule leaves base pipeline complete");
  check([f.view.customSyntaxStatus containsString:@"設定エラー"] && [f.view activeSyntaxTokens].size() == 2,
        "invalid custom regex retains complete ordinary comments/strings");

  NSString* adversarial = [@"int value;\n" stringByAppendingString:[@"" stringByPaddingToLength:30001 withString:@"a" startingAtIndex:0]];
  Fixture slow([adversarial stringByAppendingString:@"X"]); slow.view.testPreferences = rules(@"", @"(a+)+$");
  check(SakuraWaitForSyntax(slow.view), "slow custom regex is bounded off main thread");
  check([slow.view.customSyntaxStatus containsString:@"時間上限"] && ![slow.view activeSyntaxTokens].empty(), "custom timeout preserves ordinary keyword color");
}

void incrementalRendering() {
  NSString* text=[@"" stringByPaddingToLength:100000 withString:@"int value = 7; // x\n" startingAtIndex:0];
  Fixture f(text);
  auto draw = [&] {
    NSBitmapImageRep* bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr pixelsWide:700 pixelsHigh:200
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext=[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [f.view drawRect:NSMakeRect(0,0,700,160)];
    [NSGraphicsContext restoreGraphicsState];
  };
  [f.view prepareSyntax]; check(pump([&]{return !f.view.hasPendingSyntax;}),"cold indexed syntax completes");
  draw(); check(f.stat(@"syntaxFlattenBuilds")==0,"actual drawing queries only visible token ranges, never flattens the document");
  f.doc.documentSession.insert(10,u"x"); [f.view documentContentsDidChange];
  [f.view prepareSyntax]; check(pump([&]{return !f.view.hasPendingSyntax;}),"local indexed syntax update completes");
  draw();
  check(!f.stat(@"syntaxFullRebuild") && f.stat(@"syntaxParsedUnits")<16384 &&
        f.stat(@"syntaxReusedUnits")>f.doc.documentSession.buffer().length()-16384 && f.stat(@"syntaxSerializedUnits")<=65536,
        "local edit uses bounded serialization/parsing and reuses the suffix in the real view pipeline");
  check(f.stat(@"syntaxFlattenBuilds")==0,"local redraw does not create a whole-document token array");
  f.reference();
  f.view.testPreferences=rules(@"special");
  check(SakuraWaitForSyntax(f.view) && f.stat(@"syntaxParsedUnits")==0,"rule-only changes reuse all base parsing");
  f.doc.documentSession.insert(0,u"/*");[f.view documentContentsDidChange];
  check(SakuraWaitForSyntax(f.view),"unclosed multiline comment propagates through the suffix");
  const auto& colored=[f.view activeSyntaxTokens];
  check(colored.size()==1 && colored.front().kind==SyntaxTokenKind::comment &&
        colored.front().range.length==f.doc.documentSession.buffer().length(),"lexical-state change never keeps stale suffix keywords");
}

void benchmarkLargeSyntax() {
  using Clock = std::chrono::steady_clock;
  constexpr std::size_t units = 100 * 1024 * 1024, lines = 1000000;
  auto saved = [NSUserDefaults.standardUserDefaults volatileDomainForName:NSArgumentDomain] ?: @{};
  NSMutableDictionary* values = [saved mutableCopy]; values[@"SakuraTypeEditor.cpp.wrapMode"] = @0;
  [NSUserDefaults.standardUserDefaults setVolatileDomain:values forName:NSArgumentDomain];
  AsyncSyntaxDocument* document = [[AsyncSyntaxDocument alloc] init];
  document.fileURL = [NSURL fileURLWithPath:@"/async-syntax/benchmark.cpp"];
  {
    SakuraString text; text.reserve(units);
    for (std::size_t line = 0; line < lines; ++line) {
      auto width = units / lines + (line < units % lines ? 1 : 0);
      text.append(u"int value = 7; //"); text.append(width - 18, u'x'); text.push_back(u'\n');
    }
    check(text.size() == units, "large syntax fixture is exactly 100MiB ASCII equivalent");
    document.documentSession.insert(0, text);
  }
  SakuraEditorView* view = [[SakuraEditorView alloc] initWithFrame:NSMakeRect(0,0,700,200) document:document];
  __block Clock::time_point last = Clock::now();
  __block double maximumGap = 0;
  __block NSUInteger ticks = 0;
  NSTimer* timer = [NSTimer scheduledTimerWithTimeInterval:0.01 repeats:YES block:^(NSTimer*) {
    const auto now = Clock::now();
    maximumGap = std::max(maximumGap, std::chrono::duration<double,std::milli>(now-last).count());
    last = now; ++ticks;
  }];
  const auto start = Clock::now();
  check([view activeSyntaxTokens].empty() && view.hasPendingSyntax, "large syntax request starts without inline parsing");
  const auto requested = Clock::now();
  check(pump([&] { return !view.hasPendingSyntax; }), "large syntax completes before bounded pipeline deadline");
  const auto done = Clock::now(); [timer invalidate];
  const auto& tokens = [view activeSyntaxTokens];
  check(view.syntaxStatus.length == 0 && tokens.size() == lines * 3, "large syntax has complete, untruncated ordinary tokens");
  if (tokens.size() == lines * 3) {
    TextOffset offset = 0;
    for (std::size_t line = 0; line < lines; ++line) {
      const auto width = units / lines + (line < units % lines ? 1 : 0);
      const auto& keyword = tokens[line*3]; const auto& number = tokens[line*3+1]; const auto& comment = tokens[line*3+2];
      if (keyword.range.location != offset || keyword.range.length != 3 || keyword.kind != SyntaxTokenKind::keyword ||
          number.range.location != offset+12 || number.range.length != 1 || number.kind != SyntaxTokenKind::number ||
          comment.range.location != offset+15 || comment.range.length != width-16 || comment.kind != SyntaxTokenKind::comment) {
        check(false, "every large syntax token has its exact expected range and kind"); break;
      }
      offset += width;
    }
  }
  check(ticks > 0 && ![[view renderingStatistics][@"syntaxWorkerOnMain"] boolValue], "main run loop advances while parsing large source");
  std::cout << "Large ordinary syntax: units=" << units << " logicalLines=" << document.documentSession.buffer().lineCount()
            << " tokens=" << tokens.size()
            << " requestMs=" << std::chrono::duration<double,std::milli>(requested-start).count()
            << " completionMs=" << std::chrono::duration<double,std::milli>(done-start).count()
            << " maximum10msTimerGapMs=" << maximumGap << " ticks=" << ticks << '\n';
  last=Clock::now(); maximumGap=0; ticks=0;
  timer=[NSTimer scheduledTimerWithTimeInterval:0.01 repeats:YES block:^(NSTimer*) {
    const auto now=Clock::now(); maximumGap=std::max(maximumGap,std::chrono::duration<double,std::milli>(now-last).count());
    last=now; ++ticks;
  }];
  const auto editStart=Clock::now();
  document.documentSession.insert(10,u"x"); [view documentContentsDidChange]; [view prepareSyntax];
  const auto editRequested=Clock::now();
  check(pump([&]{return !view.hasPendingSyntax;}),"large local-edit syntax completes");
  const auto editDone=Clock::now(); [timer invalidate];
  NSDictionary* statistics=[view renderingStatistics];
  check(![statistics[@"syntaxFullRebuild"] boolValue] && [statistics[@"syntaxParsedUnits"] unsignedLongLongValue]<16384 &&
        [statistics[@"syntaxSerializedUnits"] unsignedLongLongValue]<=65536 &&
        [statistics[@"syntaxReusedUnits"] unsignedLongLongValue]>units-16384,"100MiB local edit reuses suffix without full token-array rewrite");
  const auto& updated=[view activeSyntaxTokens];
  check(updated.size()==lines*3,"large incremental result retains all tokens");
  if(updated.size()==lines*3) {
    TextOffset offset=0;
    for(std::size_t line=0;line<lines;++line) {
      const auto width=units/lines+(line<units%lines?1:0);
      const auto& keyword=updated[line*3];const auto& number=updated[line*3+1];const auto& comment=updated[line*3+2];
      if(keyword.range.location!=offset+(line?1:0) || keyword.range.length!=3 || keyword.kind!=SyntaxTokenKind::keyword ||
          number.range.location!=offset+13 || number.range.length!=1 || number.kind!=SyntaxTokenKind::number ||
          comment.range.location!=offset+16 || comment.range.length!=width-16 || comment.kind!=SyntaxTokenKind::comment) {
        check(false,"every shifted incremental token has the exact expected location, length and kind");break;
      }
      offset+=width;
    }
  }
  std::cout<<"Large incremental syntax: editAndRequestMs="<<std::chrono::duration<double,std::milli>(editRequested-editStart).count()
           <<" completionMs="<<std::chrono::duration<double,std::milli>(editDone-editStart).count()
           <<" parsedUnits="<<[statistics[@"syntaxParsedUnits"] unsignedLongLongValue]
           <<" serializedUnits="<<[statistics[@"syntaxSerializedUnits"] unsignedLongLongValue]
           <<" reusedUnits="<<[statistics[@"syntaxReusedUnits"] unsignedLongLongValue]
           <<" rebuiltBlocks="<<[statistics[@"syntaxRebuiltBlocks"] unsignedIntegerValue]
           <<" maximum10msTimerGapMs="<<maximumGap<<" ticks="<<ticks<<'\n';
  [NSUserDefaults.standardUserDefaults setVolatileDomain:saved forName:NSArgumentDomain];
}
}  // namespace

int main(int argc, char** argv) {
  @autoreleasepool {
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    if (argc == 2 && std::string_view(argv[1]) == "--benchmark") benchmarkLargeSyntax();
    else { ordinaryAndLanguageModes(); staleSourcesAndConditions(); compositionAndLifetime(); customMaskAndFailures(); incrementalRendering(); }
  }
  return failures ? 1 : 0;
}
