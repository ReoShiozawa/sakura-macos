// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import "SakuraDocument.h"
#import "SakuraSearchState.h"
#import "SakuraWindowController.h"
#import "SakuraLayoutRows.h"
#import "SearchTestSupport.h"
#include "sakura/platform/mac/StringBridge.h"
#include <chrono>
#include <algorithm>
#include <functional>
#include <iostream>
#include <string_view>

@interface SakuraEditorView (AsyncReplacementTests)
- (void)prepareFindPanel;
- (void)replaceAll:(id)sender;
- (void)replaceSearchSelection:(id)sender;
- (void)findNext:(id)sender;
- (void)captureSearchScope:(id)sender;
- (void)cancelOperation:(id)sender;
- (void)undo:(id)sender;
- (void)redo:(id)sender;
- (NSDictionary*)renderingStatistics;
- (const SakuraLayoutRows&)displayLineRanges;
- (NSArray*)layoutConfigurationKey;
- (void)updateDocumentViewSize;
- (void)setFindStatus:(NSString*)status;
@end
@interface ReplacementDocument : SakuraDocument
@property(nonatomic) NSUInteger editNotifications;
@end
@implementation ReplacementDocument
- (void)noteEditorChange:(NSDocumentChangeType)change { (void)change; ++self.editNotifications; }
- (void)scheduleRecoveryBackup {}
- (void)removeRecoveryBackup {}
@end
@interface ReplacementEditor : SakuraEditorView
@property(nonatomic,strong) SakuraSearchState* isolatedState;
@end
@implementation ReplacementEditor
- (SakuraSearchState*)searchState {
  if (!self.isolatedState) self.isolatedState=[[SakuraSearchState alloc]init];
  return self.isolatedState;
}
@end
namespace {
int failures{};
void check(bool value,const char* message){if(!value){++failures;std::cerr<<message<<'\n';}}
bool pump(const std::function<bool()>& predicate) {
  NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:10];
  while(!predicate()&&deadline.timeIntervalSinceNow>0)
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
  return predicate();
}
struct Fixture {
  ReplacementDocument* doc;
  ReplacementEditor* view;
  Fixture(NSString* text,SakuraSearchState* state=nil) {
    doc=[[ReplacementDocument alloc]init];
    doc.documentSession.insert(0,sakura::platform::mac::sakuraStringFromString(text));
    doc.documentSession.markSaved(doc.documentSession.makeSaveSnapshot().token);
    view=[[ReplacementEditor alloc]initWithFrame:NSMakeRect(0,0,700,250) document:doc];
    if(state)view.isolatedState=state;
    [view prepareFindPanel];
  }
  NSTextField* field(NSString* key){return [view valueForKey:key];}
  NSButton* button(NSString* key){return [view valueForKey:key];}
  void query(NSString* needle,NSString* replacement,BOOL regex=NO) {
    field(@"findField").stringValue=needle;field(@"replaceField").stringValue=replacement;
    button(@"regularExpressionButton").state=regex?NSControlStateValueOn:NSControlStateValueOff;
  }
  NSString* text(){return sakura::platform::mac::stringFromSakuraString(doc.documentSession.buffer().text());}
  NSString* status(){return field(@"findStatusLabel").stringValue;}
  NSUInteger stat(NSString* key){return [[view renderingStatistics][key] unsignedIntegerValue];}
  void settle(){check(SakuraWaitForReplacement(view),"replacement reaches terminal state");}
  void settleSingle(){settle();check(SakuraWaitForSearchNavigation(view),"post-single-replacement navigation reaches terminal state");}
  void select(NSUInteger start,NSUInteger length){[view setValue:[NSValue valueWithRange:NSMakeRange(start,length)] forKey:@"committedSelection"];}
  void discarded(NSUInteger before){check(pump([&]{return stat(@"replacementDiscards")>before;}),"stale/cancelled worker completion is discarded");}
  void scope(NSUInteger start,NSUInteger length) {
    [view setValue:[NSValue valueWithRange:NSMakeRange(start,length)] forKey:@"committedSelection"];
    [view captureSearchScope:nil];
  }
};
void atomicCompletionUndoAndNoOp() {
  Fixture f(@"cat cat");f.query(@"cat",@"dog");
  const auto revision=f.doc.documentSession.buffer().revision();
  [f.view replaceAll:nil];
  check(f.view.hasPendingReplacement && [f.text() isEqual:@"cat cat"] &&
        f.doc.documentSession.buffer().revision()==revision,"request does not synchronously edit source");
  f.settle();
  check([f.text() isEqual:@"dog dog"] && f.doc.editNotifications==1 && f.doc.isDocumentEdited,"one successful callback commits and notifies once");
  check(f.stat(@"replacementWorkerOnMain")==0 && f.stat(@"replacementCompletions")==1,"worker computes replacement off main");
  check(f.stat(@"replacementLayoutsAdopted")==1 && [f.view displayLineRanges].index.matchesText(f.doc.documentSession.buffer()),
        "prepared layout is adopted with the matching live text version");
  check(f.doc.documentSession.undo() && [f.text() isEqual:@"cat cat"] && !f.doc.isDocumentEdited,"one undo restores saved text and dirty state");
  check(f.doc.documentSession.redo() && [f.text() isEqual:@"dog dog"],"one redo restores entire prepared replacement");
  f.doc.documentSession.markSaved(f.doc.documentSession.makeSaveSnapshot().token);
  [f.view documentContentsDidChange];
  f.query(@"dog",@"dog");[f.view replaceAll:nil];f.settle();
  check(!f.doc.isDocumentEdited && f.doc.editNotifications==1 && [f.status() containsString:@"変更なし"],"no-op replacement preserves dirty state and notification count");
}
void conditionsAndSelectionsRejectOldPlans() {
  for(NSUInteger mode=0;mode<7;++mode) {
    Fixture f(@"a a a");f.query(@"a",@"b");const auto discarded=f.stat(@"replacementDiscards");
    [f.view replaceAll:nil];
    if(mode==0) f.field(@"replaceField").stringValue=@"different"; // no notification
    if(mode==1) { [f.view jumpToDocumentOffset:2];[f.view jumpToDocumentOffset:0]; }
    if(mode==2) { f.doc.documentSession.insert(0,u"!");f.doc.documentSession.undo(); }
    if(mode==3) [f.view setMarkedText:@"未確定" selectedRange:NSMakeRange(3,0) replacementRange:NSMakeRange(NSNotFound,0)];
    if(mode==4) f.button(@"caseSensitiveButton").state=f.button(@"caseSensitiveButton").state==NSControlStateValueOn?NSControlStateValueOff:NSControlStateValueOn;
    if(mode==5) {
      const auto save=f.doc.documentSession.makeSaveSnapshot();
      check(f.doc.documentSession.load(save.encoded.bytes).ok(),"same-content reload fixture");
    }
    if(mode==6) [f.view setFrameSize:NSMakeSize(500,250)];
    f.discarded(discarded);
    check([f.text() isEqual:@"a a a"] && f.doc.editNotifications==0,"conditions, manual selection, edit/undo, IME or reload cannot apply stale plan");
  }
}
void allPanesReceivePreparedLayoutsAndProtectComposition() {
  ReplacementDocument* doc=[[ReplacementDocument alloc]init];doc.documentSession.insert(0,u"cat cat\ncat long long\n");
  SakuraWindowController* controller=[[SakuraWindowController alloc]initWithDocument:doc];[doc addWindowController:controller];
  [controller toggleSplitEditor:nil];check(controller.editorViews.count==2,"split-pane replacement fixture");
  SakuraEditorView* first=controller.editorViews.firstObject;SakuraEditorView* second=controller.editorViews.lastObject;
  [first prepareFindPanel];
  ((NSTextField*)[first valueForKey:@"findField"]).stringValue=@"cat";
  ((NSTextField*)[first valueForKey:@"replaceField"]).stringValue=@"さくら";
  [first replaceAll:nil];check(SakuraWaitForReplacement(first),"two-pane prepared replacement completes");
  for(SakuraEditorView* view in controller.editorViews) {
    check([[view renderingStatistics][@"replacementLayoutsAdopted"] unsignedIntegerValue]==1,
          "every pane adopts its own worker layout");
    const auto prepared=[view displayLineRanges];
    [view setValue:nil forKey:@"layoutKey"]; // Force an independent main-thread remeasurement for comparison.
    const auto& measured=[view displayLineRanges];
    check(prepared.size()==measured.size(),"prepared/main layout row counts agree");
    for(std::size_t row=0;row<std::min(prepared.size(),measured.size());++row)
      check(NSEqualRanges(prepared[row],measured[row]) && prepared.index.row(row).visual.width==measured.index.row(row).visual.width,
            "worker layout matches main-thread Core Text in each viewport");
  }
  check(doc.documentSession.undo(),"restore two-pane fixture");[doc refreshEditorViews];
  [second setMarkedText:@"入力中" selectedRange:NSMakeRange(3,0) replacementRange:NSMakeRange(NSNotFound,0)];
  [first replaceAll:nil];check(!first.hasPendingReplacement && [first.searchOperationStatus containsString:@"別のペイン"],
                             "pre-existing composition in another pane prevents replacement");
  [second cancelOperation:nil];
  const auto discarded=[[first renderingStatistics][@"replacementDiscards"] unsignedIntegerValue];
  [first replaceAll:nil];
  [second setMarkedText:@"未確定" selectedRange:NSMakeRange(3,0) replacementRange:NSMakeRange(NSNotFound,0)];
  check(pump([&]{return [[first renderingStatistics][@"replacementDiscards"] unsignedIntegerValue]>discarded;}),
        "new composition in another pane discards old prepared layouts/text");
  check(doc.documentSession.buffer().text()==u"cat cat\ncat long long\n" && second.hasMarkedText,
        "other-pane IME state and source remain untouched");
  [first setValue:[NSValue valueWithRange:NSMakeRange(0,0)] forKey:@"committedSelection"];
  [first replaceSearchSelection:nil];check(SakuraWaitForReplacement(first),"single fallback while another pane composes completes");
  check(second.hasMarkedText && doc.documentSession.buffer().text()==u"cat cat\ncat long long\n" &&
        NSEqualRanges(first.selectedRange,NSMakeRange(0,3)),"navigation-only single replacement leaves other-pane IME untouched");
  [first replaceSearchSelection:nil];check(SakuraWaitForReplacement(first),"single write protection for other-pane IME completes");
  check([first.searchOperationStatus containsString:@"別のペイン"] && doc.documentSession.buffer().text()==u"cat cat\ncat long long\n",
        "single replacement never edits a document with pre-existing other-pane composition");
  [second cancelOperation:nil];
  [first replaceSearchSelection:nil];check(SakuraWaitForReplacement(first) && SakuraWaitForSearchNavigation(first),"two-pane single replacement and follow-up complete");
  check(doc.documentSession.buffer().text()==u"さくら cat\ncat long long\n" && NSEqualRanges(first.selectedRange,NSMakeRange(4,3)),"single edits once and selects the next match");
  for(SakuraEditorView* view in controller.editorViews)
    check([[view renderingStatistics][@"replacementLayoutsAdopted"] unsignedIntegerValue]==2 &&
          [view displayLineRanges].index.matchesText(doc.documentSession.buffer()),"single replacement adopts matching worker layouts in every pane");
  check(doc.documentSession.undo(),"restore two-pane single fixture");[doc refreshEditorViews];
  [first setValue:[NSValue valueWithRange:NSMakeRange(0,3)] forKey:@"committedSelection"];
  const auto singleDiscarded=[[first renderingStatistics][@"replacementDiscards"] unsignedIntegerValue];
  [first replaceSearchSelection:nil];
  [second setMarkedText:@"入力中" selectedRange:NSMakeRange(3,0) replacementRange:NSMakeRange(NSNotFound,0)];
  check(pump([&]{return [[first renderingStatistics][@"replacementDiscards"] unsignedIntegerValue]>singleDiscarded;}),
        "new composition in another pane discards pending single replacement");
  check(doc.documentSession.buffer().text()==u"cat cat\ncat long long\n" && second.hasMarkedText,"pending single replacement preserves other-pane IME and source");
  [second cancelOperation:nil];
  ReplacementDocument* other=[[ReplacementDocument alloc]init];
  other.documentSession.insert(0,u"other document");
  const auto originalRoot=doc.documentSession.buffer(), otherRoot=other.documentSession.buffer();
  const auto notifications=doc.editNotifications;
  for (BOOL single : {NO,YES}) {
    [first setValue:[NSValue valueWithRange:NSMakeRange(0,3)] forKey:@"committedSelection"];
    const auto beforeDiscarded=[[first renderingStatistics][@"replacementDiscards"] unsignedIntegerValue];
    const auto firstAdoptions=[[first renderingStatistics][@"replacementLayoutsAdopted"] unsignedIntegerValue];
    const auto secondAdoptions=[[second renderingStatistics][@"replacementLayoutsAdopted"] unsignedIntegerValue];
    if (single) [first replaceSearchSelection:nil]; else [first replaceAll:nil];
    check(first.hasPendingReplacement,"peer owner change fixture begins a pending replacement");
    // A worker cannot publish until this main-thread test yields. Switch only
    // the peer owner without changing the controller's pane membership.
    [second setValue:other forKey:@"sakuraDocument"];
    check(pump([&]{return [[first renderingStatistics][@"replacementDiscards"] unsignedIntegerValue]>beforeDiscarded;}),
        "a peer switched to another document rejects its old prepared replacement");
    check(doc.documentSession.buffer().sharesStorageWith(originalRoot) &&
          other.documentSession.buffer().sharesStorageWith(otherRoot) &&
          doc.editNotifications==notifications && other.editNotifications==0 &&
          [[first renderingStatistics][@"replacementLayoutsAdopted"] unsignedIntegerValue]==firstAdoptions &&
          [[second renderingStatistics][@"replacementLayoutsAdopted"] unsignedIntegerValue]==secondAdoptions,
        "peer owner mismatch preserves both source roots, histories, notifications and pane layouts");
    if (single) [first replaceSearchSelection:nil]; else [first replaceAll:nil];
    check(!first.hasPendingReplacement && [first.searchOperationStatus containsString:@"ペインの文書"],
        "a mismatched peer owner also refuses new replacement preparation");
    [second setValue:doc forKey:@"sakuraDocument"];
  }
  [controller.window close];[doc removeWindowController:controller];
}
void explicitStopsAndSupersedingRequests() {
  for(NSUInteger mode=0;mode<3;++mode) {
    Fixture f(@"a a");f.query(@"a",@"b");const auto discarded=f.stat(@"replacementDiscards");[f.view replaceAll:nil];
    if(mode==0)[f.view cancelSearchOperations:nil];
    if(mode==1)[f.view cancelOperation:nil];
    if(mode==2)[NSNotificationCenter.defaultCenter postNotificationName:NSWindowWillCloseNotification object:[f.view valueForKey:@"findPanel"]];
    check(!f.view.hasPendingReplacement,"stop/Escape/panel close cancels immediately");
    f.discarded(discarded);
    check([f.text() isEqual:@"a a"] && !f.doc.isDocumentEdited,"explicit cancellation cannot commit later");
  }
  Fixture f(@"a a");f.query(@"a",@"first");const auto discarded=f.stat(@"replacementDiscards");[f.view replaceAll:nil];
  f.query(@"a",@"second");[f.view replaceAll:nil];f.settle();f.discarded(discarded);
  check([f.text() isEqual:@"second second"] && f.doc.editNotifications==1,"new replace-all supersedes old request without applying twice");
  Fixture next(@"a a");next.query(@"a",@"b");[next.view replaceAll:nil];[next.view findNext:nil];
  check(SakuraWaitForSearchNavigation(next.view),"search superseding replacement completes");
  check([next.text() isEqual:@"a a"] && NSEqualRanges(next.view.selectedRange,NSMakeRange(0,1)),"navigation cancels pending replacement and preserves source");
}
void regionsCapturesZeroWidthAndBoundaryJoins() {
  Fixture f(@"pre aa aa post");f.scope(4,5);f.query(@"(?<=pre )aa|aa(?= post)",@"$&X",YES);
  [f.view replaceAll:nil];f.settle();
  check([f.text() isEqual:@"pre aaX aaX post"] && NSEqualRanges(f.view.selectedRange,NSMakeRange(4,7)),"scoped captures retain surrounding source and expand scope");
  check(f.doc.documentSession.undo() && [f.text() isEqual:@"pre aa aa post"],"scoped operation undoes as one snapshot");
  Fixture zero(@"aa");zero.query(@"(?=a)|$",@"X",YES);[zero.view replaceAll:nil];zero.settle();
  check([zero.text() isEqual:@"XaXaX"],"zero-width replacements use original match coordinates");
  Fixture join(@"\rX\n");join.scope(1,1);join.query(@"X",@"");[join.view replaceAll:nil];join.settle();
  check([join.text() isEqual:@"\r\n"] && [join.status() containsString:@"再指定"] &&
        ![[join.view valueForKey:@"searchScopeCaptured"] boolValue],"new CRLF across scope boundary invalidates scope instead of retaining split boundary");
}
void errorsAndSharedHistory() {
  Fixture invalid(@"a a");invalid.query(@"(",@"b",YES);[invalid.view replaceAll:nil];invalid.settle();
  check([invalid.text() isEqual:@"a a"] && !invalid.doc.isDocumentEdited && [invalid.status() containsString:@"正規表現"],"invalid pattern fails asynchronously without edits");
  NSString* pathological=[[@"" stringByPaddingToLength:60000 withString:@"a" startingAtIndex:0] stringByAppendingString:@"b"];
  Fixture slow(pathological);slow.query(@"(a+)+$",@"x",YES);[slow.view replaceAll:nil];slow.settle();
  check([slow.text() isEqual:pathological] && !slow.doc.isDocumentEdited && [slow.status() containsString:@"中止"],"regex resource failure cannot partially replace");
  SakuraSearchState* state=[[SakuraSearchState alloc]init];
  Fixture a(@"a a",state),b(@"a a",state);a.query(@"a",@"b");[a.view replaceAll:nil];
  b.query(@"a",@"b");[b.view replaceAll:nil];a.settle();b.settle();
  check([a.text() isEqual:@"b b"] && [b.text() isEqual:@"b b"],"equal shared-history notifications do not cancel independent replacements");
}
void hiddenStatusReportsPreparation() {
  ReplacementDocument* doc=[[ReplacementDocument alloc]init];doc.documentSession.insert(0,u"a a");
  SakuraWindowController* controller=[[SakuraWindowController alloc]initWithDocument:doc];[doc addWindowController:controller];
  SakuraEditorView* view=controller.editorView;[view prepareFindPanel];
  ((NSTextField*)[view valueForKey:@"findField"]).stringValue=@"a";
  ((NSTextField*)[view valueForKey:@"replaceField"]).stringValue=@"b";
  [view replaceAll:nil];
  check([((NSTextField*)[controller valueForKey:@"statusMessage"]).stringValue containsString:@"全置換を準備"],"hidden find panel still reports operation in document status bar");
  [view cancelSearchOperations:nil];[controller.window close];[doc removeWindowController:controller];
}
void singleAtomicFallbackAndNoOp() {
  Fixture f(@"cat cat");f.query(@"cat",@"dog");f.select(0,3);
  [f.view replaceSearchSelection:nil];
  check(f.view.hasPendingReplacement && [f.text() isEqual:@"cat cat"] && !f.doc.isDocumentEdited,"single request prepares asynchronously without editing inline");
  f.settleSingle();
  check([f.text() isEqual:@"dog cat"] && NSEqualRanges(f.view.selectedRange,NSMakeRange(4,3)) && f.doc.editNotifications==1,
        "single publication changes one match, notifies once and selects next match");
  check(f.stat(@"replacementWorkerOnMain")==0 && f.stat(@"replacementLayoutsAdopted")==1,"single validation/expansion/layout run off main");
  check(f.doc.documentSession.undo() && [f.text() isEqual:@"cat cat"] && !f.doc.isDocumentEdited,"single publication is one undo");
  check(f.doc.documentSession.redo() && [f.text() isEqual:@"dog cat"],"single publication is one redo");

  Fixture fallback(@"cat cat");fallback.query(@"cat",@"dog");fallback.select(0,0);
  [fallback.view replaceSearchSelection:nil];fallback.settleSingle();
  check([fallback.text() isEqual:@"cat cat"] && !fallback.doc.isDocumentEdited && fallback.doc.editNotifications==0 &&
        NSEqualRanges(fallback.view.selectedRange,NSMakeRange(0,3)),"nonmatching selection only selects the actual match without editing");
  fallback.select(7,0);fallback.button(@"searchWrapButton").state=NSControlStateValueOn;
  [fallback.view replaceSearchSelection:nil];fallback.settleSingle();
  check(NSEqualRanges(fallback.view.selectedRange,NSMakeRange(0,3)) && fallback.doc.editNotifications==0,"single fallback honors wrap without a second search worker");

  Fixture noop(@"cat cat");noop.doc.documentSession.insert(0,u"!");noop.doc.documentSession.undo();
  noop.query(@"cat",@"cat");noop.select(0,3);const auto revision=noop.doc.documentSession.buffer().revision();
  [noop.view replaceSearchSelection:nil];noop.settleSingle();
  check(!noop.doc.isDocumentEdited && noop.doc.editNotifications==0 && noop.doc.documentSession.canRedo() &&
        noop.doc.documentSession.buffer().revision()==revision && NSEqualRanges(noop.view.selectedRange,NSMakeRange(4,3)),
        "single no-op preserves saved state, redo and revision while advancing search");
}
void singleRejectsStalePlansAndStops() {
  for(NSUInteger mode=0;mode<14;++mode) {
    Fixture f(@"a a a");f.query(@"a",@"b");f.select(0,1);auto discarded=f.stat(@"replacementDiscards");
    if(mode>=11){const auto saved=f.doc.documentSession.makeSaveSnapshot();check(f.doc.documentSession.load(saved.encoded.bytes).ok(),"empty-history undo fixture");[f.view documentContentsDidChange];f.select(0,1);}
    [f.view replaceSearchSelection:nil];
    if(mode==0)f.field(@"replaceField").stringValue=@"different";
    if(mode==1){[f.view jumpToDocumentOffset:2];[f.view jumpToDocumentOffset:0];}
    if(mode==2){f.doc.documentSession.insert(0,u"!");f.doc.documentSession.undo();}
    if(mode==3)[f.view setMarkedText:@"未確定" selectedRange:NSMakeRange(3,0) replacementRange:NSMakeRange(NSNotFound,0)];
    if(mode==4)f.button(@"wholeWordButton").state=NSControlStateValueOn;
    if(mode==5){const auto saved=f.doc.documentSession.makeSaveSnapshot();check(f.doc.documentSession.load(saved.encoded.bytes).ok(),"single reload fixture");}
    if(mode==6)[f.view setFrameSize:NSMakeSize(500,250)];
    if(mode==7)[f.view cancelSearchOperations:nil];
    if(mode==8)[f.view cancelOperation:nil];
    if(mode==9)[f.view windowWillClose:[NSNotification notificationWithName:NSWindowWillCloseNotification object:[f.view valueForKey:@"findPanel"]]];
    if(mode==10)[f.view findNext:nil];
    if(mode==11)[f.view undo:nil];
    if(mode==12)[f.view redo:nil];
    if(mode==13)[f.doc close];
    f.discarded(discarded);
    check([f.text() isEqual:@"a a a"] && f.doc.editNotifications==0,"stale or cancelled single replacement cannot alter source/history");
    if(mode==10)check(SakuraWaitForSearchNavigation(f.view),"navigation superseding a single replacement settles");
  }
  Fixture all(@"a a");all.query(@"a",@"first");all.select(0,1);const auto discarded=all.stat(@"replacementDiscards");
  [all.view replaceSearchSelection:nil];all.query(@"a",@"second");[all.view replaceAll:nil];all.settle();all.discarded(discarded);
  check([all.text() isEqual:@"second second"] && all.doc.editNotifications==1,"new all replacement supersedes pending single replacement atomically");
  Fixture single(@"a a");single.query(@"a",@"first");single.select(0,1);auto old=single.stat(@"replacementDiscards");
  [single.view replaceSearchSelection:nil];single.query(@"a",@"second");[single.view replaceSearchSelection:nil];single.settleSingle();single.discarded(old);
  check([single.text() isEqual:@"second a"] && single.doc.editNotifications==1,"new single replacement supersedes old preparation");
}
void singleScopeCapturesZeroWidthAndErrors() {
  Fixture scope(@"OUT cat cat OUT");scope.scope(4,7);scope.query(@"cat",@"doggy");scope.select(4,3);
  [scope.view replaceSearchSelection:nil];scope.settleSingle();
  check([scope.text() isEqual:@"OUT doggy cat OUT"] && NSEqualRanges(scope.view.selectedRange,NSMakeRange(10,3)),"single updates fixed scope and selects next match inside it");
  Fixture captures(@"OUT aa AFTER");captures.scope(4,2);captures.query(@"(?<=(OUT ))aa(?= AFTER)",@"<$1>",YES);captures.select(4,2);
  [captures.view replaceSearchSelection:nil];captures.settleSingle();
  check([captures.text() isEqual:@"OUT <OUT > AFTER"],"single keeps lookaround captures outside fixed matching scope");
  Fixture join(@"\rX\n");join.scope(1,1);join.query(@"X",@"");join.select(1,1);
  [join.view replaceSearchSelection:nil];join.settleSingle();
  check([join.text() isEqual:@"\r\n"] && ![[join.view valueForKey:@"searchScopeCaptured"] boolValue] &&
        NSEqualRanges(join.view.selectedRange,NSMakeRange(2,0)) && [join.status() containsString:@"再指定"],
        "single CRLF join invalidates only the fixed scope and never follows up outside it");
  Fixture zero(@"aa");zero.query(@"(?=a)|$",@"X",YES);zero.button(@"searchWrapButton").state=NSControlStateValueOff;zero.select(0,0);
  [zero.view replaceSearchSelection:nil];zero.settleSingle();
  check([zero.text() isEqual:@"Xaa"] && NSEqualRanges(zero.view.selectedRange,NSMakeRange(2,0)),"first zero-width single progresses past original a");
  [zero.view replaceSearchSelection:nil];zero.settleSingle();
  check([zero.text() isEqual:@"XaXa"] && NSEqualRanges(zero.view.selectedRange,NSMakeRange(4,0)),"second zero-width single progresses to EOF");
  [zero.view replaceSearchSelection:nil];zero.settleSingle();
  check([zero.text() isEqual:@"XaXaX"] && !zero.view.hasPendingSearchNavigation,"zero-width no-wrap replacement at EOF stops follow-up");
  Fixture invalid(@"cat");invalid.query(@"(",@"x",YES);invalid.select(0,3);[invalid.view replaceSearchSelection:nil];invalid.settleSingle();
  check([invalid.text() isEqual:@"cat"] && [invalid.status() containsString:@"正規表現"],"invalid single regex is a nonmutating async error");
  NSString* pathological=[[@"" stringByPaddingToLength:30001 withString:@"a" startingAtIndex:0] stringByAppendingString:@"X"];
  Fixture slow(pathological);slow.query(@"(a+)+$",@"x",YES);slow.select(0,1);[slow.view replaceSearchSelection:nil];slow.settleSingle();
  check([slow.text() isEqual:pathological] && slow.doc.editNotifications==0 && [slow.status() containsString:@"中止"],"single matching timeout does not edit or navigate");
}
void statusMessagesPreserveViewport() {
  ReplacementDocument* doc=[[ReplacementDocument alloc]init];doc.documentSession.insert(0,u"cat cat");
  SakuraWindowController* controller=[[SakuraWindowController alloc]initWithDocument:doc];[doc addWindowController:controller];
  SakuraEditorView* view=controller.editorView;[view prepareFindPanel];
  [controller.window.contentView layoutSubtreeIfNeeded];[view.enclosingScrollView tile];[view updateDocumentViewSize];
  const NSSize initial=controller.window.contentView.bounds.size;
  const auto initialLayout=[view layoutConfigurationKey];
  NSString* longStatus=[@"" stringByPaddingToLength:1800 withString:@"検索・置換の処理状況を表示しています。" startingAtIndex:0];
  [view setFindStatus:longStatus];
  for(int pass=0;pass<4;++pass){[controller.window.contentView layoutSubtreeIfNeeded];
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];}
  check(NSEqualSizes(initial,controller.window.contentView.bounds.size) && [initialLayout isEqual:[view layoutConfigurationKey]],
        "long status text must not resize the window or invalidate viewport-dependent preparation");
  NSTextField* message=[controller valueForKey:@"statusMessage"];
  check([message.toolTip containsString:longStatus],"truncated status keeps its full message in tooltip");
  NSView* bar=[controller valueForKey:@"statusBarView"];
  for(NSView* child in bar.subviews)if([child isKindOfClass:NSStackView.class])
    check(NSEqualRects(child.frame,NSInsetRect(bar.bounds,4.0,2.0)),"status layout keeps the original inset geometry inside chrome");
  [controller.window close];[doc removeWindowController:controller];
}
void benchmarkLargeReplacement(BOOL single) {
  using Clock=std::chrono::steady_clock;
  constexpr std::size_t count=100*1024*1024,rows=1000000;
  std::vector<std::byte> input(count,std::byte{'a'});
  const auto content=count-(rows-1),perLine=content/rows,extra=content%rows;
  std::size_t offset=0;
  constexpr std::string_view needle="needle";
  for(std::size_t line=0;line<rows;++line){
    for(std::size_t i=0;i<needle.size();++i)input[offset+i]=static_cast<std::byte>(needle[i]);
    offset+=perLine+(line<extra?1:0);if(line+1<rows)input[offset++]=std::byte{'\n'};
  }
  ReplacementDocument* doc=[[ReplacementDocument alloc]init];
  {auto loaded=doc.documentSession.load(input, sakura::core::TextEncoding::utf8);check(loaded.ok(),"large source decodes");}
  input.clear();input.shrink_to_fit();
  SakuraWindowController* controller=[[SakuraWindowController alloc]initWithDocument:doc];[doc addWindowController:controller];
  SakuraEditorView* view=controller.editorView;[view prepareFindPanel];
  ((NSTextField*)[view valueForKey:@"findField"]).stringValue=@"needle";
  ((NSTextField*)[view valueForKey:@"replaceField"]).stringValue=@"done";
  ((NSButton*)[view valueForKey:@"caseSensitiveButton"]).state=NSControlStateValueOn;
  ((NSButton*)[view valueForKey:@"regularExpressionButton"]).state=NSControlStateValueOff;
  ((NSButton*)[view valueForKey:@"wholeWordButton"]).state=NSControlStateValueOff;
  ((NSButton*)[view valueForKey:@"searchScopeButton"]).state=NSControlStateValueOff;
  // Deliberately do not pump initial layout. Progress text must not resize the
  // window and invalidate its first replacement on a large document.
  const NSUInteger layoutPasses=0;
  if(single)[view setValue:[NSValue valueWithRange:NSMakeRange(0,6)] forKey:@"committedSelection"];
  const NSRange initialSelection=view.selectedRange;
  NSNumber* initialGeneration=[view valueForKey:@"selectionGeneration"];
  NSArray* initialLayout=[view layoutConfigurationKey];
  NSScrollView* initialScroll=view.enclosingScrollView;
  auto last=std::make_shared<Clock::time_point>(Clock::now());
  auto maxGap=std::make_shared<double>(0);auto ticks=std::make_shared<unsigned int>(0);
  NSTimer* timer=[NSTimer scheduledTimerWithTimeInterval:0.01 repeats:YES block:^(NSTimer*){
    const auto now=Clock::now();*maxGap=std::max(*maxGap,std::chrono::duration<double,std::milli>(now-*last).count());*last=now;++*ticks;
  }];
  const auto start=Clock::now();
  if(single)[view replaceSearchSelection:nil];else[view replaceAll:nil];
  const auto requested=Clock::now();
  check(SakuraWaitForReplacement(view),"large UI replacement reaches terminal state");const auto completed=Clock::now();
  if(single)check(SakuraWaitForSearchNavigation(view),"large single follow-up search reaches terminal state");
  const auto navigated=Clock::now();
  const auto prior=*ticks;check(pump([&]{return *ticks>prior;}),"main timer observes end of commit/refresh");[timer invalidate];
  std::cout<<"terminal_status="<<view.searchOperationStatus.UTF8String
    <<"\ninitial_layout_passes="<<layoutPasses
    <<"\nterminal_units="<<doc.documentSession.buffer().length()<<"\nedit_notifications="<<doc.editNotifications
    <<"\ninitial_selection="<<initialSelection.location<<":"<<initialSelection.length
    <<"\nterminal_selection="<<view.selectedRange.location<<":"<<view.selectedRange.length
    <<"\ninitial_generation="<<initialGeneration.unsignedLongLongValue
    <<"\nterminal_generation="<<[[view valueForKey:@"selectionGeneration"] unsignedLongLongValue]
    <<"\nlayout_configuration_changed="<<(![initialLayout isEqual:[view layoutConfigurationKey]])
    <<"\ninitial_viewport_width="<<[initialLayout.lastObject doubleValue]
    <<"\nterminal_viewport_width="<<[[view layoutConfigurationKey].lastObject doubleValue]
    <<"\ninitial_scroll_attached="<<(initialScroll!=nil)
    <<"\nterminal_scroll_attached="<<(view.enclosingScrollView!=nil)
    <<"\nscroll_frame_width="<<initialScroll.frame.size.width
    <<"\nscroll_content_width="<<initialScroll.contentSize.width
    <<"\nview_frame_width="<<view.frame.size.width
    <<"\nview_superview="<<(view.superview?NSStringFromClass(view.superview.class).UTF8String:"nil")
    <<"\nreplacement_discards="<<[[view renderingStatistics][@"replacementDiscards"] unsignedIntegerValue]
    <<"\nreplacement_completions="<<[[view renderingStatistics][@"replacementCompletions"] unsignedIntegerValue]<<'\n';
  check(doc.documentSession.buffer().length()==count-2*(single?1:rows) && doc.documentSession.buffer().lineCount()==rows && doc.editNotifications==1,
        "UI prepared replacement has exact output shape and one notification");
  if(single)check(NSEqualRanges(view.selectedRange,NSMakeRange(perLine+(extra?1:0)-1,6)),"large single follow-up selects the next original needle");
  {
    auto cursor=doc.documentSession.buffer().lineCursor();bool exact=true;
    for(std::size_t line=0;line<rows;++line,cursor.advance()) {
      if(!cursor){exact=false;break;}
      const BOOL replaced=!single || line==0;
      const auto& value=cursor.line();
      const sakura::core::SakuraStringView prefix=replaced?u"done":u"needle";
      if(value.content.size()!=perLine+(line<extra?1:0)-(replaced?2:0) ||
          value.ending!=(line+1<rows?sakura::core::LineEnding::lineFeed:sakura::core::LineEnding::none)){exact=false;break;}
      for(std::size_t at=0;at<value.content.size();++at)
        if(value.content[at]!=(at<prefix.size()?prefix[at]:u'a')){exact=false;break;}
      if(!exact)break;
    }
    check(exact,"all large replacement output characters and line endings match expected data");
  }
  check([[view renderingStatistics][@"replacementLayoutsAdopted"] unsignedIntegerValue]==1,
        "large benchmark includes prepared layout adoption");
  check(doc.documentSession.undo() && doc.documentSession.buffer().length()==count && !doc.isDocumentEdited,"large UI undo restores saved source");
  const auto ms=[](auto value){return std::chrono::duration<double,std::milli>(value).count();};
  std::cout<<"scope=hidden_AppKit_window_with_commit_and_layout_without_drawing_syntax_or_recovery_IO\nsource_bytes="<<count
    <<"\noperation="<<(single?"single":"all")
    <<"\nlogical_lines="<<rows<<"\nrequest_ms="<<ms(requested-start)<<"\ncompletion_ms="<<ms(completed-start)
    <<"\nwith_next_search_ms="<<ms(navigated-start)
    <<"\nmain_timer_max_gap_ms="<<*maxGap<<"\nmain_timer_ticks="<<*ticks
    <<"\nmain_callback_ms="<<[[view renderingStatistics][@"replacementMainMilliseconds"] doubleValue]
    <<"\nlayout_adopt_ms="<<[[view renderingStatistics][@"replacementAdoptMilliseconds"] doubleValue]
    <<"\nview_refresh_ms="<<[[view renderingStatistics][@"replacementRefreshMilliseconds"] doubleValue]<<'\n';
  [controller.window close];[doc removeWindowController:controller];
}
}  // namespace
int main(int argc,char** argv){@autoreleasepool{
  [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
  if(argc>1){benchmarkLargeReplacement(std::string_view(argv[1])=="--benchmark-large-single");return failures?1:0;}
  atomicCompletionUndoAndNoOp();conditionsAndSelectionsRejectOldPlans();explicitStopsAndSupersedingRequests();
  regionsCapturesZeroWidthAndBoundaryJoins();errorsAndSharedHistory();hiddenStatusReportsPreparation();
  allPanesReceivePreparedLayoutsAndProtectComposition();
  singleAtomicFallbackAndNoOp();singleRejectsStalePlansAndStops();singleScopeCapturesZeroWidthAndErrors();
  statusMessagesPreserveViewport();
}return failures?1:0;}
