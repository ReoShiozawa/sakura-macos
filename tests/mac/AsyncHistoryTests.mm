// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import "SakuraDocument.h"
#import "SakuraEditorView.h"
#import "SakuraEditorSettings.h"
#import "SakuraLayoutRows.h"
#import "SakuraSearchState.h"
#import "SakuraWindowController.h"
#include "sakura/platform/mac/CoreTextMetrics.h"
#include "sakura/platform/mac/StringBridge.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <functional>
#include <iostream>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <sys/resource.h>
#include <vector>

namespace {
struct HistoryGate {
  dispatch_semaphore_t release=dispatch_semaphore_create(0);
  std::atomic<bool> entered{};
};
}
@interface SakuraEditorView (HistoryTesting)
- (std::function<void()>)historyWorkGate;
- (NSTimeInterval)historyPreparationTimeLimit;
- (SakuraEditorSettings*)editorSettings;
- (NSDictionary*)renderingStatistics;
- (const SakuraLayoutRows&)displayLineRanges;
- (void)prepareFindPanel;
- (void)findNext:(id)sender;
- (void)cancelOperation:(id)sender;
- (void)clearMarkedState;
- (void)setFindStatus:(NSString*)message;
@end
@interface HistoryDocument : SakuraDocument
@property(nonatomic) NSUInteger notifications;
@property(nonatomic) NSUInteger undone;
@property(nonatomic) NSUInteger redone;
@property(nonatomic) NSUInteger refreshes;
@property(nonatomic) BOOL throwNextRefresh;
@property(nonatomic,copy) void (^noteChangeCallback)(HistoryDocument*,NSDocumentChangeType);
@property(nonatomic,copy) void (^refreshCallback)(HistoryDocument*);
@property(nonatomic,copy) void (^refreshCompletedCallback)(HistoryDocument*);
@end
@implementation HistoryDocument
- (void)noteEditorChange:(NSDocumentChangeType)change {
  ++self.notifications;
  if (change==NSChangeUndone) ++self.undone;
  if (change==NSChangeRedone) ++self.redone;
  const auto callback=self.noteChangeCallback;
  if (callback) callback(self,change);
}
- (void)scheduleRecoveryBackup {}
- (void)removeRecoveryBackup {}
- (void)refreshEditorViews {
  ++self.refreshes;
  const auto callback=self.refreshCallback;
  if (callback) callback(self);
  if (self.throwNextRefresh) {
    self.throwNextRefresh=NO;
    [NSException raise:NSInternalInconsistencyException format:@"isolated post-commit refresh failure"];
  }
  [super refreshEditorViews];
  const auto completed=self.refreshCompletedCallback;
  if (completed) completed(self);
}
@end
@interface HistoryEditor : SakuraEditorView {
 @public
  std::shared_ptr<HistoryGate> workGate;
}
@property(nonatomic,strong) SakuraEditorSettings* isolatedSettings;
@property(nonatomic,strong) SakuraSearchState* isolatedSearch;
@property(nonatomic) NSTimeInterval timeLimit;
@property(nonatomic) NSUInteger historyCaptures;
@property(nonatomic) BOOL throwNextHistoryGateCapture;
@property(nonatomic) BOOL throwNextPendingHistoryStatus;
@property(nonatomic) BOOL historyExceptionSawProgress;
@property(nonatomic) NSUInteger historyExceptionThrows;
@property(nonatomic,copy) void (^historyExceptionCallback)(HistoryEditor*);
@end
@implementation HistoryEditor
- (SakuraEditorSettings*)editorSettings {
  if (!self.isolatedSettings) {
    self.isolatedSettings=[[SakuraEditorSettings alloc]init];
    self.isolatedSettings.fontName=@"Menlo-Regular";
    self.isolatedSettings.fontSize=13;
    self.isolatedSettings.wrapMode=SakuraEditorWrapModeWindow;
  }
  return self.isolatedSettings;
}
- (SakuraSearchState*)searchState {
  if (!self.isolatedSearch) self.isolatedSearch=[[SakuraSearchState alloc]init];
  return self.isolatedSearch;
}
- (NSTimeInterval)historyPreparationTimeLimit { return self.timeLimit; }
- (void)setFindStatus:(NSString*)message {
  if (self.throwNextPendingHistoryStatus && [self valueForKey:@"historyProgress"]!=nil) {
    self.throwNextPendingHistoryStatus=NO;
    self.historyExceptionSawProgress=YES;
    ++self.historyExceptionThrows;
    const auto callback=self.historyExceptionCallback;
    if (callback) callback(self);
    [NSException raise:NSInternalInconsistencyException format:@"isolated history status failure after progress allocation"];
  }
  [super setFindStatus:message];
}
- (std::function<void()>)historyWorkGate {
  ++self.historyCaptures;
  if (self.throwNextHistoryGateCapture) {
    self.throwNextHistoryGateCapture=NO;
    self.historyExceptionSawProgress=[self valueForKey:@"historyProgress"]!=nil;
    ++self.historyExceptionThrows;
    const auto callback=self.historyExceptionCallback;
    if (callback) callback(self);
    [NSException raise:NSInternalInconsistencyException format:@"isolated history hook failure before progress allocation"];
  }
  const auto gate=workGate;
  if (!gate) return {};
  return [gate] {
    gate->entered=true;
    if (dispatch_semaphore_wait(gate->release,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC)))
      throw std::runtime_error("isolated history worker gate timed out");
  };
}
@end
@interface HistoryPaneController : SakuraWindowController
@property(nonatomic,copy) NSArray<SakuraEditorView*>* testViews;
@end
@implementation HistoryPaneController
- (NSArray<SakuraEditorView*>*)editorViews { return self.testViews?self.testViews:super.editorViews; }
- (SakuraEditorView*)editorView { return self.testViews?self.testViews.firstObject:super.editorView; }
@end

namespace {
using namespace sakura::core;
int failures{};
std::string currentCase;
void check(bool value,const char* message) {
  if (!value) {
    ++failures;
    if (failures<=40) std::cerr<<currentCase<<": "<<message<<'\n';
  }
}
bool pump(const std::function<bool()>& predicate,NSTimeInterval seconds=10) {
  NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:seconds];
  while (!predicate() && deadline.timeIntervalSinceNow>0)
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
        beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.003]];
  return predicate();
}
bool settle(SakuraEditorView* view) { return pump([&]{return !view.hasPendingHistoryNavigation;}); }
NSUInteger statistic(SakuraEditorView* view,NSString* key) {
  return [[view renderingStatistics][key] unsignedIntegerValue];
}
void checkPreparedLayoutBuilds(SakuraEditorView* view,NSUInteger baseline,NSUInteger transitions) {
  check(statistic(view,@"layoutBuilds")==baseline+transitions,
      "history changes layoutBuilds exactly once per adoption with no synchronous fallback reflow during refresh");
  (void)[view displayLineRanges];
  check(statistic(view,@"layoutBuilds")==baseline+transitions,
      "reading the adopted layout does not trigger a hidden main-thread reflow");
}
void select(SakuraEditorView* view,NSUInteger start,NSUInteger length=0) {
  [view setValue:[NSValue valueWithRange:NSMakeRange(start,length)] forKey:@"committedSelection"];
}
void load(HistoryDocument* document,NSString* text) {
  check([document readFromData:[text dataUsingEncoding:NSUTF8StringEncoding]
      ofType:@"public.plain-text" error:nil],"load isolated history fixture and clear initial Undo history");
}
struct Fixture {
  HistoryDocument* document;
  HistoryEditor* view;
  std::shared_ptr<HistoryGate> gate;
  explicit Fixture(NSString* source=@"base") {
    document=[[HistoryDocument alloc]init]; load(document,source);
    view=[[HistoryEditor alloc]initWithFrame:NSMakeRect(0,0,700,220) document:document];
    view.timeLimit=5;
  }
  ~Fixture() {
    if (gate) dispatch_semaphore_signal(gate->release);
    [view cancelHistoryNavigation:nil]; [view cancelSearchOperations:nil];
    [view cancelSyntaxHighlighting:nil]; [view clearMarkedState];
  }
  SakuraString text() { return document.documentSession.buffer().text(); }
  void edit(SakuraStringView value=u"!") {
    document.documentSession.insert(document.documentSession.buffer().length(),value);
    [view documentContentsDidChange];
  }
  void block() {
    gate=std::make_shared<HistoryGate>(); view->workGate=gate;
    [view undo:nil];
    check(view.hasPendingHistoryNavigation,"history request returns before its worker commits");
    check(pump([&]{return gate->entered.load();}),"history worker enters deterministic preparation gate");
  }
  void release() { view->workGate.reset(); dispatch_semaphore_signal(gate->release); }
  void finish() { check(settle(view),"history requests reach terminal state"); }
  void discarded(NSUInteger before) {
    check(pump([&]{return statistic(view,@"historyDiscards")>before;}),"stale history completion is rejected");
  }
};
void queueBarrier() {
  Fixture barrier; barrier.edit(); [barrier.view undo:nil]; barrier.finish();
}
void normalTransitionsAndQueue() {
  Fixture f; f.edit(u" one"); f.edit(u" two");
  const auto before=f.document.documentSession.buffer();
  auto layoutBaseline=statistic(f.view,@"layoutBuilds");
  [f.view undo:nil];
  check(f.view.hasPendingHistoryNavigation && f.document.documentSession.buffer().sharesStorageWith(before),
      "Undo dispatch leaves the live root unchanged synchronously");
  f.finish();
  check(f.text()==u"base one" && f.document.notifications==1 && f.document.undone==1 && f.document.isDocumentEdited,
      "one Undo commits exactly one previous state and one NSChangeUndone notification");
  check(statistic(f.view,@"historyCompletions")==1 && statistic(f.view,@"historyWorkerOnMain")==0 &&
        statistic(f.view,@"historyLayoutsAdopted")==1,"Undo prepares off main and adopts its prepared layout");
  checkPreparedLayoutBuilds(f.view,layoutBaseline,1);
  layoutBaseline=statistic(f.view,@"layoutBuilds");
  [f.view redo:nil]; f.finish();
  check(f.text()==u"base one two" && f.document.notifications==2 && f.document.redone==1,"Redo restores the full action and notifies once");
  checkPreparedLayoutBuilds(f.view,layoutBaseline,1);
  layoutBaseline=statistic(f.view,@"layoutBuilds");
  [f.view undo:nil]; [f.view undo:nil]; [f.view redo:nil]; f.finish();
  check(f.text()==u"base one" && f.document.notifications==5 && f.document.undone==3 && f.document.redone==2 &&
        statistic(f.view,@"historyCompletions")==5,"queued Undo Undo Redo preserves exact requested order");
  checkPreparedLayoutBuilds(f.view,layoutBaseline,3);
  Fixture clean; clean.edit();
  layoutBaseline=statistic(clean.view,@"layoutBuilds");
  [clean.view undo:nil]; clean.finish();
  check(clean.text()==u"base" && !clean.document.isDocumentEdited,"Undo reaches the saved state without inventing dirty metadata");
  checkPreparedLayoutBuilds(clean.view,layoutBaseline,1);
  layoutBaseline=statistic(clean.view,@"layoutBuilds");
  [clean.view redo:nil]; clean.finish();
  check(clean.document.isDocumentEdited,"Redo away from the saved state is dirty");
  checkPreparedLayoutBuilds(clean.view,layoutBaseline,1);
  clean.document.documentSession.markSaved(clean.document.documentSession.makeSaveSnapshot().token);
  layoutBaseline=statistic(clean.view,@"layoutBuilds");
  [clean.view undo:nil]; clean.finish();
  check(clean.document.isDocumentEdited,"Undo away from a newly saved edited state is dirty");
  checkPreparedLayoutBuilds(clean.view,layoutBaseline,1);
  layoutBaseline=statistic(clean.view,@"layoutBuilds");
  [clean.view redo:nil]; clean.finish();
  check(!clean.document.isDocumentEdited,"Redo back to the exact saved text state clears text dirty state");
  checkPreparedLayoutBuilds(clean.view,layoutBaseline,1);
  Fixture empty;
  const auto original=empty.document.documentSession.buffer();
  (void)[empty.view displayLineRanges];
  layoutBaseline=statistic(empty.view,@"layoutBuilds");
  [empty.view undo:nil]; [empty.view redo:nil];
  check(!empty.view.hasPendingHistoryNavigation && empty.text()==u"base" && empty.document.notifications==0 &&
        statistic(empty.view,@"historyCompletions")==0 && empty.document.documentSession.buffer().revision()==original.revision(),
      "missing Undo/Redo history is a no-op with no notification or revision change");
  checkPreparedLayoutBuilds(empty.view,layoutBaseline,0);
  Fixture alternating; alternating.edit();
  layoutBaseline=statistic(alternating.view,@"layoutBuilds"); alternating.block();
  [alternating.view undo:nil]; [alternating.view redo:nil]; alternating.release(); alternating.finish();
  check(alternating.text()==u"base!" && alternating.document.notifications==2 && alternating.document.undone==1 &&
        alternating.document.redone==1,"queue skips missing Undo while retaining a later Redo request");
  checkPreparedLayoutBuilds(alternating.view,layoutBaseline,2);
  Fixture metadata; metadata.edit();
  layoutBaseline=statistic(metadata.view,@"layoutBuilds"); metadata.block();
  metadata.document.documentSession.setEncodingState({sakura::core::TextEncoding::utf16BigEndian,true});
  metadata.release(); metadata.finish();
  check(metadata.text()==u"base" && metadata.document.isDocumentEdited &&
        metadata.document.documentSession.encodingState()==EncodingState{sakura::core::TextEncoding::utf16BigEndian,true},
      "prepared history preserves newer output encoding/BOM metadata and dirty state");
  checkPreparedLayoutBuilds(metadata.view,layoutBaseline,1);
}
void staleAndExplicitCancellation() {
  for (unsigned mode=0;mode<13;++mode) {
    currentCase="stale/cancel mode "+std::to_string(mode);
    Fixture f(@"(a)"); f.edit();
    const auto discarded=statistic(f.view,@"historyDiscards"); f.block();
    if (mode==0) f.document.documentSession.insert(0,u"external ");
    if (mode==1) { f.document.documentSession.insert(0,u"x"); check(f.document.documentSession.undo(),"edit/Undo stale fixture restores original root"); }
    if (mode==2) load(f.document,@"(a)!");
    if (mode==3) select(f.view,1);
    if (mode==4) [f.view setMarkedText:@"未確定" selectedRange:NSMakeRange(3,0) replacementRange:NSMakeRange(NSNotFound,0)];
    if (mode==5) [f.view setFrameSize:NSMakeSize(510,220)];
    if (mode==6) { [f.view editorSettings].fontSize=17; [f.view displaySettingsDidChange]; }
    if (mode==7) [f.view cancelHistoryNavigation:nil];
    if (mode==8) [f.view cancelOperation:nil]; // Escape's common command handler.
    if (mode==9) [f.view cancelSearchOperations:nil]; // Command-period's menu action.
    if (mode==10) [f.document close]; // No window is required for document-close protection.
    if (mode==11) {
      [f.view prepareFindPanel];
      ((NSTextField*)[f.view valueForKey:@"findField"]).stringValue=@"a";
      [f.view findNext:nil];
    }
    if (mode==12) [f.view jumpToMatchingBracket:nil];
    const auto expected=f.document.documentSession.buffer();
    const auto expectedState=f.document.documentSession.makeSaveSnapshot().token.stateId;
    const bool canUndo=f.document.documentSession.canUndo(), canRedo=f.document.documentSession.canRedo();
    const bool dirty=f.document.isDocumentEdited;
    f.release(); f.discarded(discarded); f.finish();
    check(f.document.documentSession.buffer().sharesStorageWith(expected) &&
          f.document.documentSession.buffer().revision()==expected.revision() &&
          f.document.documentSession.makeSaveSnapshot().token.stateId==expectedState &&
          f.document.documentSession.canUndo()==canUndo && f.document.documentSession.canRedo()==canRedo &&
          f.document.isDocumentEdited==dirty && f.document.notifications==0,
        "stale/cancelled history cannot change current text, history, saved state or notifications");
    if (mode==3) check(NSEqualRanges(f.view.selectedRange,NSMakeRange(1,0)),"old history cannot overwrite manually moved caret");
    if (mode==4) check(f.view.hasMarkedText,"old history cannot discard newer IME composition");
    if (mode==11) check(pump([&]{return !f.view.hasPendingSearchNavigation;}),"new search completes after canceling history");
    if (mode==12) check(pump([&]{return !f.view.hasPendingBracketSearch;}),"new bracket request completes after canceling history");
  }
}
void queueLimitAndTimeout() {
  Fixture bounded; bounded.edit(); bounded.block();
  for (unsigned request=0;request<700;++request) [bounded.view undo:nil];
  check(statistic(bounded.view,@"historyQueuedRequests")==256 &&
        [bounded.view.searchOperationStatus containsString:@"上限"],"history queue is bounded at 256 requests");
  bounded.release(); bounded.finish();
  check(bounded.text()==u"base" && bounded.document.notifications==1 &&
        statistic(bounded.view,@"historyCompletions")==1,"excess/missing Undo requests do not create extra history actions");
  Fixture timeout; timeout.edit(); timeout.view.timeLimit=0.001; timeout.block();
  NSDate* expired=[NSDate dateWithTimeIntervalSinceNow:0.02];
  check(pump([&]{return expired.timeIntervalSinceNow<=0;}),"deadline expires while the worker remains gated");
  timeout.release(); timeout.finish();
  check(timeout.text()==u"base!" && timeout.document.notifications==0 && timeout.document.documentSession.canUndo() &&
        statistic(timeout.view,@"historyCompletions")==0 && [timeout.view.searchOperationStatus containsString:@"時間"],
      "deadline failure publishes neither text/history nor partial layouts");
  for (double invalid : {0.0,-1.0,61.0,std::numeric_limits<double>::infinity(),std::numeric_limits<double>::quiet_NaN()}) {
    Fixture invalidBudget; invalidBudget.edit(); invalidBudget.view.timeLimit=invalid;
    [invalidBudget.view undo:nil];
    check(!invalidBudget.view.hasPendingHistoryNavigation && invalidBudget.text()==u"base!" &&
          invalidBudget.document.notifications==0 && [invalidBudget.view.searchOperationStatus containsString:@"開始"],
        "invalid preparation time limits are rejected before a worker or edit starts");
  }
}
void windowAndViewLifetimes() {
  for (bool close : {false,true}) {
    Fixture f; f.edit();
    NSWindow* window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,700,250)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO; window.contentView=f.view;
    f.block(); const auto discarded=statistic(f.view,@"historyDiscards");
    if (close) [window close]; else [f.view removeFromSuperview];
    f.release(); f.discarded(discarded);
    check(f.text()==u"base!" && f.document.notifications==0,"detaching or closing the owning window rejects stale history publication");
    window.contentView=nil; [window close];
  }
  HistoryDocument* document=[[HistoryDocument alloc]init]; load(document,@"base");
  document.documentSession.insert(4,u"!");
  auto gate=std::make_shared<HistoryGate>();
  __weak HistoryEditor* weakView=nil;
  @autoreleasepool {
    HistoryEditor* view=[[HistoryEditor alloc]initWithFrame:NSMakeRect(0,0,700,220) document:document];
    view.timeLimit=5; view->workGate=gate; weakView=view; [view undo:nil];
    check(pump([&]{return gate->entered.load();}),"lifetime worker enters gate");
    view=nil;
  }
  check(weakView==nil,"history worker/layout payload do not retain their editor view");
  dispatch_semaphore_signal(gate->release); queueBarrier();
  check(document.documentSession.buffer().text()==u"base!" && document.notifications==0,
      "completion after view destruction does not publish old history");
}
void independentLayout(SakuraEditorView* view,const TextBuffer& buffer) {
  SakuraEditorSettings* settings=[view editorSettings]; NSFont* font=[settings editorFont];
  const char* family=font.fontName.UTF8String;
  sakura::platform::mac::CoreTextMetrics metrics(family?family:"Menlo-Regular",font.pointSize,settings.characterSpacing);
  const FontStyle style{0,static_cast<float>(font.pointSize),400,false};
  float wrap=0;
  if (settings.wrapMode==SakuraEditorWrapModeWindow)
    wrap=std::max(1.0F,static_cast<float>((view.enclosingScrollView?view.enclosingScrollView.contentSize.width:view.bounds.size.width)-68));
  else if (settings.wrapMode==SakuraEditorWrapModeColumn) wrap=metrics.advance(u' ',style)*settings.wrapColumn;
  const auto expected=LayoutEngine{}.layout(buffer,metrics,style,{.wrapWidth=wrap,.tabWidth=static_cast<TextOffset>(settings.tabWidth)});
  const auto layoutBuildsBeforeRead=statistic(view,@"layoutBuilds");
  const auto& actual=[view displayLineRanges].index;
  check(statistic(view,@"layoutBuilds")==layoutBuildsBeforeRead,
      "independent layout verification reads the adopted index without a synchronous fallback reflow");
  check(actual.matchesText(buffer) && actual.size()==expected.visualLines.size(),"adopted pane layout matches live source and independent main-thread row count");
  if (actual.size()!=expected.visualLines.size()) return;
  float widest=0;
  for (std::size_t row=0;row<actual.size();++row) {
    const auto got=actual.row(row); const auto& want=expected.visualLines[row];
    check(got.visual.logicalLine==want.logicalLine && got.visual.startColumn==want.startColumn && got.visual.endColumn==want.endColumn &&
          std::abs(got.visual.width-want.width)<0.001F && std::abs(got.visual.height-want.height)<0.001F &&
          got.range==sakura::core::TextRange{buffer.offsetAt({want.logicalLine,want.startColumn}),want.endColumn-want.startColumn},
        "every adopted pane row/range/width agrees with an independent full reflow");
    widest=std::max(widest,want.width);
  }
  check(std::abs(actual.widestLine()-widest)<0.001F,"adopted pane width aggregate matches independent full reflow");
}
void realTwoPaneLayoutsAndComposition() {
  HistoryDocument* document=[[HistoryDocument alloc]init];
  load(document,@"one\t桜😀 long long long line\r\nshort\nlast line\n");
  HistoryPaneController* controller=[[HistoryPaneController alloc]initWithDocument:document];
  [document addWindowController:controller]; [controller toggleSplitEditor:nil];
  check(controller.editorViews.count==2,"real history split-pane fixture creates two editors");
  NSMutableArray<SakuraEditorView*>* replacements=[NSMutableArray array];
  for (SakuraEditorView* old in controller.editorViews) {
    HistoryEditor* view=[[HistoryEditor alloc]initWithFrame:old.frame document:document]; view.timeLimit=5;
    old.enclosingScrollView.documentView=view; [replacements addObject:view];
  }
  controller.testViews=replacements;
  HistoryEditor* first=(HistoryEditor*)controller.editorViews.firstObject;
  HistoryEditor* second=(HistoryEditor*)controller.editorViews.lastObject;
  [first editorSettings].wrapMode=SakuraEditorWrapModeColumn; [first editorSettings].wrapColumn=12;
  [second editorSettings].fontSize=17; [second editorSettings].tabWidth=8; [second editorSettings].characterSpacing=0.5;
  [controller.window makeFirstResponder:first];
  document.documentSession.insert(0,u"edited\tline😀\n"); [document refreshEditorViews];
  (void)[first displayLineRanges]; (void)[second displayLineRanges];
  const auto firstUndoBuilds=statistic(first,@"layoutBuilds"),secondUndoBuilds=statistic(second,@"layoutBuilds");
  [first undo:nil]; check(settle(first),"two-pane Undo completes");
  for (SakuraEditorView* view in controller.editorViews) {
    check(statistic(view,@"historyLayoutsAdopted")==1,"both real panes adopt worker-prepared history layouts");
    checkPreparedLayoutBuilds(view,view==first?firstUndoBuilds:secondUndoBuilds,1);
    independentLayout(view,document.documentSession.buffer());
  }
  const auto firstRedoBuilds=statistic(first,@"layoutBuilds"),secondRedoBuilds=statistic(second,@"layoutBuilds");
  [first redo:nil]; check(settle(first),"two-pane Redo completes");
  for (SakuraEditorView* view in controller.editorViews) {
    checkPreparedLayoutBuilds(view,view==first?firstRedoBuilds:secondRedoBuilds,1);
    independentLayout(view,document.documentSession.buffer());
  }
  [second setMarkedText:@"入力中" selectedRange:NSMakeRange(3,0) replacementRange:NSMakeRange(NSNotFound,0)];
  const auto before=document.documentSession.buffer(); const auto notified=document.notifications;
  [first undo:nil];
  check(!first.hasPendingHistoryNavigation && second.hasMarkedText && document.documentSession.buffer().sharesStorageWith(before) &&
        document.notifications==notified,"pre-existing peer IME refuses history without changing source or composition");
  [second cancelOperation:nil];
  auto gate=std::make_shared<HistoryGate>(); first->workGate=gate;
  const auto discarded=statistic(first,@"historyDiscards"); [first undo:nil];
  check(pump([&]{return gate->entered.load();}),"two-pane history worker enters gate");
  [second setMarkedText:@"新入力" selectedRange:NSMakeRange(3,0) replacementRange:NSMakeRange(NSNotFound,0)];
  first->workGate.reset(); dispatch_semaphore_signal(gate->release);
  check(pump([&]{return statistic(first,@"historyDiscards")>discarded;}),"peer composition begun during preparation discards pending history");
  check(second.hasMarkedText && document.documentSession.buffer().sharesStorageWith(before) && document.notifications==notified,
      "new peer IME survives stale history completion with source/history unchanged");
  [second cancelOperation:nil];
  HistoryDocument* peerDocument=[[HistoryDocument alloc]init]; load(peerDocument,@"other document");
  peerDocument.documentSession.insert(0,u"peer edit ");
  const auto sourceBeforeSwitch=document.documentSession.buffer();
  const auto peerBeforeSwitch=peerDocument.documentSession.buffer();
  const auto sourceState=document.documentSession.makeSaveSnapshot().token.stateId;
  const auto peerState=peerDocument.documentSession.makeSaveSnapshot().token.stateId;
  const bool sourceDirty=document.isDocumentEdited,peerDirty=peerDocument.isDocumentEdited;
  const bool sourceUndo=document.documentSession.canUndo(),sourceRedo=document.documentSession.canRedo();
  const bool peerUndo=peerDocument.documentSession.canUndo(),peerRedo=peerDocument.documentSession.canRedo();
  const auto firstAdoptions=statistic(first,@"historyLayoutsAdopted"),secondAdoptions=statistic(second,@"historyLayoutsAdopted");
  const auto beforeSwitchDiscards=statistic(first,@"historyDiscards");
  const auto sourceNotifications=document.notifications,peerNotifications=peerDocument.notifications;
  const auto sourceRefreshes=document.refreshes,peerRefreshes=peerDocument.refreshes;
  gate=std::make_shared<HistoryGate>(); first->workGate=gate;
  [first undo:nil];
  check(pump([&]{return gate->entered.load();}),"peer-document-switch worker enters gate");
  // Keep pane identities, metrics and viewport unchanged: document identity alone
  // must invalidate the captured layout, without a content-change notification.
  [second setValue:peerDocument forKey:@"sakuraDocument"];
  first->workGate.reset(); dispatch_semaphore_signal(gate->release);
  check(pump([&]{return statistic(first,@"historyDiscards")>beforeSwitchDiscards;}),
      "peer pane switching document during preparation rejects the complete history transition");
  check(settle(first),"peer-document-switch cancellation drains the history queue");
  check([second valueForKey:@"sakuraDocument"]==peerDocument &&
        document.documentSession.buffer().sharesStorageWith(sourceBeforeSwitch) &&
        document.documentSession.buffer().revision()==sourceBeforeSwitch.revision() &&
        document.documentSession.makeSaveSnapshot().token.stateId==sourceState &&
        document.documentSession.canUndo()==sourceUndo && document.documentSession.canRedo()==sourceRedo &&
        document.isDocumentEdited==sourceDirty && document.notifications==sourceNotifications && document.refreshes==sourceRefreshes &&
        peerDocument.documentSession.buffer().sharesStorageWith(peerBeforeSwitch) &&
        peerDocument.documentSession.buffer().revision()==peerBeforeSwitch.revision() &&
        peerDocument.documentSession.makeSaveSnapshot().token.stateId==peerState &&
        peerDocument.documentSession.canUndo()==peerUndo && peerDocument.documentSession.canRedo()==peerRedo &&
        peerDocument.isDocumentEdited==peerDirty && peerDocument.notifications==peerNotifications && peerDocument.refreshes==peerRefreshes &&
        statistic(first,@"historyLayoutsAdopted")==firstAdoptions && statistic(second,@"historyLayoutsAdopted")==secondAdoptions,
      "peer document replacement preserves both sources, histories, saved states, notifications and pane layouts");
  [second setValue:document forKey:@"sakuraDocument"];
  for (bool pair : {false,true}) for (bool selected : {false,true}) {
    load(document,pair?@"😀":@"\r\n");
    const SakuraString edited=pair?SakuraString{SakuraChar(0xd83d),u'X',SakuraChar(0xde00)}:SakuraString(u"\rX\n");
    document.documentSession.replace({0,2},edited); [document refreshEditorViews];
    select(second,1,selected?1:0);
    const auto peerNotificationBaseline=document.notifications;
    const auto firstAdoptionBaseline=statistic(first,@"historyLayoutsAdopted");
    const auto secondAdoptionBaseline=statistic(second,@"historyLayoutsAdopted");
    const auto firstBuildBaseline=statistic(first,@"layoutBuilds"),secondBuildBaseline=statistic(second,@"layoutBuilds");
    [first undo:nil]; check(settle(first),"two-pane boundary normalization Undo completes");
    check(NSEqualRanges(second.selectedRange,selected?NSMakeRange(0,2):NSMakeRange(0,0)) &&
          document.documentSession.buffer().text()==(pair?u"😀":u"\r\n") &&
          document.notifications==peerNotificationBaseline+1 &&
          statistic(first,@"historyLayoutsAdopted")==firstAdoptionBaseline+1 &&
          statistic(second,@"historyLayoutsAdopted")==secondAdoptionBaseline+1,
        "peer caret/selection normalizes to whole CRLF/surrogate edit boundaries while both panes adopt once");
    checkPreparedLayoutBuilds(first,firstBuildBaseline,1);
    checkPreparedLayoutBuilds(second,secondBuildBaseline,1);
    independentLayout(first,document.documentSession.buffer());
    independentLayout(second,document.documentSession.buffer());
  }
  [controller.window close]; [document removeWindowController:controller];
}
void onNextHistoryCallback(HistoryDocument* document,bool duringRefresh,void (^callback)(HistoryDocument*)) {
  if (duringRefresh) {
    document.refreshCallback=^(HistoryDocument* liveDocument) {
      liveDocument.refreshCallback=nil;
      callback(liveDocument);
    };
  } else {
    document.noteChangeCallback=^(HistoryDocument* liveDocument,NSDocumentChangeType change) {
      check(change==NSChangeUndone,"reentry hook observes the published Undo notification");
      liveDocument.noteChangeCallback=nil;
      callback(liveDocument);
    };
  }
}
void publicationCallbackReentry() {
  for (bool duringRefresh : {false,true}) {
    const auto stage=duringRefresh?"refresh":"noteEditorChange";
    currentCase=std::string("caret reentry during ")+stage;
    {
      Fixture f; f.edit(u" one");
      const auto first=f.document.documentSession.buffer();
      const auto firstState=f.document.documentSession.makeSaveSnapshot().token.stateId;
      f.edit(u" two");
      const auto initialRefreshes=f.document.refreshes;
      __weak HistoryEditor* weakView=f.view;
      auto invoked=std::make_shared<bool>(false);
      onNextHistoryCallback(f.document,duringRefresh,^(HistoryDocument*) {
        *invoked=true;
        select(weakView,1);
      });
      f.block(); [f.view undo:nil]; f.release(); f.finish();
      check(*invoked && f.document.documentSession.buffer().sharesStorageWith(first) &&
            f.document.documentSession.makeSaveSnapshot().token.stateId==firstState &&
            f.document.documentSession.canUndo() && f.document.documentSession.canRedo() && f.document.isDocumentEdited &&
            NSEqualRanges(f.view.selectedRange,NSMakeRange(1,0)) && f.document.notifications==1 && f.document.undone==1 &&
            f.document.redone==0 && f.document.refreshes==initialRefreshes+1 && f.view.historyCaptures==1 &&
            statistic(f.view,@"historyCompletions")==1 && statistic(f.view,@"historyQueuedRequests")==0,
          "reentrant manual caret change survives and cancels all remaining queued histories after one publication/refresh");
    }
    currentCase=std::string("Undo enqueue reentry during ")+stage;
    {
      Fixture f; f.edit(u" one"); f.edit(u" two");
      const auto initialRefreshes=f.document.refreshes;
      __weak HistoryEditor* weakView=f.view;
      auto invoked=std::make_shared<bool>(false),checkedRefreshExit=std::make_shared<bool>(false);
      onNextHistoryCallback(f.document,duringRefresh,^(HistoryDocument* liveDocument) {
        *invoked=true;
        [weakView undo:nil];
        check(weakView.historyCaptures==1 && statistic(weakView,@"historyQueuedRequests")==1 &&
              [weakView valueForKey:@"historyProgress"]==nil && liveDocument.notifications==1 &&
              liveDocument.documentSession.buffer().text()==u"base one",
            "Undo requested from a publication callback queues without capturing or starting another worker");
      });
      f.document.refreshCompletedCallback=^(HistoryDocument* liveDocument) {
        if (liveDocument.notifications==1) {
          *checkedRefreshExit=true;
          check(weakView.historyCaptures==1 && statistic(weakView,@"historyQueuedRequests")==1 &&
                [weakView valueForKey:@"historyProgress"]==nil && liveDocument.refreshes==initialRefreshes+1,
              "reentrant Undo remains deferred through the end of the complete first refresh");
        }
      };
      [f.view undo:nil]; f.finish();
      check(*invoked && *checkedRefreshExit && f.text()==u"base" && !f.document.isDocumentEdited &&
            !f.document.documentSession.canUndo() && f.document.documentSession.canRedo() &&
            f.document.notifications==2 && f.document.undone==2 && f.document.redone==0 &&
            f.document.refreshes==initialRefreshes+2 && f.view.historyCaptures==2 && statistic(f.view,@"historyCompletions")==2,
          "callback-enqueued Undo executes only after refresh and publishes each history exactly once");
      f.document.refreshCompletedCallback=nil;
    }
    currentCase=std::string("direct source edit reentry during ")+stage;
    {
      Fixture f; f.edit(u" one"); f.edit(u" two");
      const auto initialRefreshes=f.document.refreshes;
      auto expected=std::make_shared<TextBuffer>();
      auto expectedState=std::make_shared<std::uint64_t>();
      auto invoked=std::make_shared<bool>(false);
      onNextHistoryCallback(f.document,duringRefresh,^(HistoryDocument* liveDocument) {
        *invoked=true;
        // Deliberately bypass view notifications: the publication source guard
        // must catch direct core edits even when no setter cancels the queue.
        liveDocument.documentSession.insert(0,u"external ");
        *expected=liveDocument.documentSession.buffer();
        *expectedState=liveDocument.documentSession.makeSaveSnapshot().token.stateId;
      });
      f.block(); [f.view undo:nil]; f.release(); f.finish();
      check(*invoked && f.text()==u"external base one" && f.document.documentSession.buffer().sharesStorageWith(*expected) &&
            f.document.documentSession.buffer().revision()==expected->revision() &&
            f.document.documentSession.makeSaveSnapshot().token.stateId==*expectedState &&
            f.document.documentSession.canUndo() && !f.document.documentSession.canRedo() && f.document.isDocumentEdited &&
            f.document.notifications==1 && f.document.undone==1 && f.document.redone==0 &&
            f.document.refreshes==initialRefreshes+1 && f.view.historyCaptures==1 &&
            statistic(f.view,@"historyCompletions")==1 && statistic(f.view,@"historyQueuedRequests")==0,
          "direct core edit from publication callbacks is retained while remaining queued histories are canceled");
    }
  }
}
void startPreparationExceptions() {
  for (bool afterProgress : {false,true}) {
    currentCase=afterProgress?"NSException from pending history status":"NSException from historyWorkGate capture";
    Fixture f;
    const auto saved=f.document.documentSession.buffer();
    const auto savedState=f.document.documentSession.makeSaveSnapshot().token.stateId;
    f.edit();
    const auto before=f.document.documentSession.buffer();
    const auto state=f.document.documentSession.makeSaveSnapshot().token.stateId;
    const auto encoding=f.document.documentSession.encodingState();
    const bool canUndo=f.document.documentSession.canUndo(),canRedo=f.document.documentSession.canRedo();
    const bool dirty=f.document.isDocumentEdited;
    const auto initialRefreshes=f.document.refreshes;
    if (afterProgress) f.view.throwNextPendingHistoryStatus=YES;
    else f.view.throwNextHistoryGateCapture=YES;
    BOOL escaped=NO;
    @try { [f.view undo:nil]; }
    @catch (NSException* exception) { (void)exception; escaped=YES; }
    check(!escaped && f.view.historyExceptionThrows==1 && f.view.historyExceptionSawProgress==afterProgress &&
          !f.view.hasPendingHistoryNavigation && [f.view valueForKey:@"historyProgress"]==nil &&
          statistic(f.view,@"historyQueuedRequests")==0 && statistic(f.view,@"historyCompletions")==0 &&
          statistic(f.view,@"historyLayoutsAdopted")==0 && f.view.historyCaptures==1 &&
          f.document.documentSession.buffer().sharesStorageWith(before) &&
          f.document.documentSession.buffer().revision()==before.revision() &&
          f.document.documentSession.makeSaveSnapshot().token.stateId==state &&
          f.document.documentSession.encodingState()==encoding && f.document.documentSession.canUndo()==canUndo &&
          f.document.documentSession.canRedo()==canRedo && f.document.isDocumentEdited==dirty &&
          f.document.notifications==0 && f.document.refreshes==initialRefreshes,
        "one-shot preparation NSException returns without pending work, mutation, layout adoption, refresh or notification");
    // Keep a failing implementation from leaving its worker pending throughout
    // later tests, while the assertions above retain the original failure.
    if (f.view.hasPendingHistoryNavigation) [f.view cancelHistoryNavigation:nil];
    f.view.throwNextHistoryGateCapture=NO; f.view.throwNextPendingHistoryStatus=NO;
    [f.view undo:nil]; f.finish();
    check(f.view.historyExceptionThrows==1 && f.view.historyCaptures==2 &&
          f.document.documentSession.buffer().sharesStorageWith(saved) &&
          f.document.documentSession.makeSaveSnapshot().token.stateId==savedState &&
          !f.document.documentSession.canUndo() && f.document.documentSession.canRedo() && !f.document.isDocumentEdited &&
          f.document.notifications==1 && f.document.undone==1 && f.document.redone==0 &&
          f.document.refreshes==initialRefreshes+1 && statistic(f.view,@"historyCompletions")==1 &&
          statistic(f.view,@"historyLayoutsAdopted")==1,
        "Undo retry after either preparation NSException succeeds with exactly one publication and refresh");
  }
}
void startExceptionPreservesNewerRequest() {
  for (bool afterProgress : {false,true}) {
    currentCase=afterProgress?"new Undo survives older start-status exception":"new Undo survives older history-capture exception";
    Fixture f;
    const auto saved=f.document.documentSession.buffer();
    const auto savedState=f.document.documentSession.makeSaveSnapshot().token.stateId;
    f.edit();
    const auto before=f.document.documentSession.buffer();
    const auto state=f.document.documentSession.makeSaveSnapshot().token.stateId;
    const auto layoutBaseline=statistic(f.view,@"layoutBuilds");
    const auto initialRefreshes=f.document.refreshes;
    auto invoked=std::make_shared<bool>(false);
    f.gate=std::make_shared<HistoryGate>(); f.view->workGate=f.gate;
    f.view.historyExceptionCallback=^(HistoryEditor* editor) {
      editor.historyExceptionCallback=nil;
      *invoked=true;
      [editor cancelHistoryNavigation:nil];
      [editor undo:nil];
    };
    if (afterProgress) f.view.throwNextPendingHistoryStatus=YES;
    else f.view.throwNextHistoryGateCapture=YES;
    BOOL escaped=NO;
    @try { [f.view undo:nil]; }
    @catch (NSException* exception) { (void)exception; escaped=YES; }
    check(pump([&]{return f.gate->entered.load();}),"reentrantly enqueued newer history reaches its own deterministic worker gate");
    NSProgress* newerProgress=[f.view valueForKey:@"historyProgress"];
    check(!escaped && *invoked && f.view.historyExceptionThrows==1 && f.view.historyExceptionSawProgress==afterProgress &&
          f.view.historyCaptures==2 && f.view.hasPendingHistoryNavigation && newerProgress && !newerProgress.cancelled &&
          statistic(f.view,@"historyQueuedRequests")==1 && statistic(f.view,@"historyCompletions")==0 &&
          statistic(f.view,@"historyLayoutsAdopted")==0 && statistic(f.view,@"layoutBuilds")==layoutBaseline &&
          f.document.documentSession.buffer().sharesStorageWith(before) &&
          f.document.documentSession.buffer().revision()==before.revision() &&
          f.document.documentSession.makeSaveSnapshot().token.stateId==state &&
          f.document.documentSession.canUndo() && !f.document.documentSession.canRedo() && f.document.isDocumentEdited &&
          f.document.notifications==0 && f.document.refreshes==initialRefreshes &&
          [f.view.searchOperationStatus containsString:@"準備中"],
        "older start exception preserves the newer request's progress, queue, status and unchanged source");
    f.release(); f.finish();
    check(f.view.historyExceptionThrows==1 && f.view.historyCaptures==2 &&
          f.document.documentSession.buffer().sharesStorageWith(saved) &&
          f.document.documentSession.makeSaveSnapshot().token.stateId==savedState &&
          !f.document.documentSession.canUndo() && f.document.documentSession.canRedo() && !f.document.isDocumentEdited &&
          f.document.notifications==1 && f.document.undone==1 && f.document.redone==0 &&
          f.document.refreshes==initialRefreshes+1 && statistic(f.view,@"historyCompletions")==1 &&
          statistic(f.view,@"historyLayoutsAdopted")==1 && statistic(f.view,@"historyQueuedRequests")==0,
        "newer reentrant Undo completes exactly once despite the older invocation's NSException cleanup");
    checkPreparedLayoutBuilds(f.view,layoutBaseline,1);
  }
}
void postCommitFailureAndCaretBoundaries() {
  Fixture failure; failure.edit(); failure.document.throwNextRefresh=YES;
  [failure.view undo:nil]; failure.finish();
  check(failure.text()==u"base" && failure.document.notifications==1 && failure.document.undone==1 &&
        failure.document.documentSession.canRedo() && !failure.document.isDocumentEdited &&
        [failure.view.searchOperationStatus containsString:@"反映済み"],
      "post-commit display failure keeps applied text/history and exactly one notification");
  [failure.view redo:nil]; failure.finish();
  check(failure.text()==u"base!" && failure.document.notifications==2,"history remains usable after a post-commit display failure");
  for (bool pair : {false,true}) for (bool selected : {false,true}) {
    Fixture f(pair?@"😀":@"\r\n");
    const SakuraString edited=pair?SakuraString{SakuraChar(0xd83d),u'X',SakuraChar(0xde00)}:SakuraString(u"\rX\n");
    f.document.documentSession.replace({0,2},edited); [f.view documentContentsDidChange];
    select(f.view,1,selected?1:0); [f.view undo:nil]; f.finish();
    check(NSEqualRanges(f.view.selectedRange,selected?NSMakeRange(0,2):NSMakeRange(0,0)),
        "history publication never leaves caret/selection inside a restored CRLF or surrogate pair");
  }
  Fixture ownIme; ownIme.edit();
  [ownIme.view setMarkedText:@"未確定" selectedRange:NSMakeRange(3,0) replacementRange:NSMakeRange(NSNotFound,0)];
  [ownIme.view undo:nil]; ownIme.finish();
  check(!ownIme.view.hasMarkedText && ownIme.text()==u"base" && ownIme.document.notifications==1,
      "Undo cancels own uncommitted composition without adding it to history");
}
struct BenchmarkShape {
  std::size_t bytes,rows,contentPerLine,extra;
};
void verifyLargeState(HistoryDocument* document,HistoryEditor* view,const BenchmarkShape& shape,
                      SakuraChar expected,const TextBuffer& retained) {
  const auto& buffer=document.documentSession.buffer();
  check(buffer.length()==shape.bytes && buffer.lineCount()==shape.rows && buffer.sharesStorageWith(retained),
      "large history restores the complete expected source root, size and logical row count");
  const auto& layout=[view displayLineRanges].index;
  check(layout.matchesText(buffer) && layout.size()==shape.rows,"large history adopts matching no-wrap layout for all logical rows");
  std::size_t row=0; TextOffset offset=0;
  for (auto lines=buffer.lineCursor();lines;lines.advance(),++row) {
    const auto& line=lines.line();
    const auto length=shape.contentPerLine+(row<shape.extra);
    check(line.content.size()==length && std::all_of(line.content.begin(),line.content.end(),
          [expected](SakuraChar value){return value==expected;}) &&
          line.ending==(row+1<shape.rows?LineEnding::lineFeed:LineEnding::none),
        "large history verifies every source character and every preserved ending");
    if (layout.size()==shape.rows && row<layout.size()) {
      const auto actual=layout.row(row);
      check(actual.range==sakura::core::TextRange{offset,length} && actual.visual.logicalLine==row &&
            actual.visual.startColumn==0 && actual.visual.endColumn==length,
          "large history verifies every adopted visual row and source range");
    }
    offset+=length+(row+1<shape.rows);
  }
  check(row==shape.rows && offset==shape.bytes,"large verification traverses the complete source");
}
void benchmarkLargeHistory(std::size_t mib) {
  using Clock=std::chrono::steady_clock;
  if (!mib || mib>128) throw std::invalid_argument("history benchmark size must be 1..128 MiB");
  const auto bytes=mib*1024*1024;
  const auto rows=std::max<std::size_t>(1,bytes/104);
  const auto content=bytes-(rows-1);
  const BenchmarkShape shape{bytes,rows,content/rows,content%rows};
  Fixture fixture(@"");
  [fixture.view editorSettings].wrapMode=SakuraEditorWrapModeNone;
  std::vector<std::byte> input(bytes,std::byte{'a'});
  SakuraString edited(bytes,u'b');
  std::size_t offset=0;
  for (std::size_t row=0;row<rows;++row) {
    offset+=shape.contentPerLine+(row<shape.extra);
    if (row+1<rows) { input[offset]=std::byte{'\n'}; edited[offset++]=u'\n'; }
  }
  check(offset==bytes,"large history fixture has the exact requested UTF-8 size");
  NSData* data=[NSData dataWithBytesNoCopy:input.data() length:input.size() freeWhenDone:NO];
  check([fixture.document readFromData:data ofType:@"public.plain-text" error:nil],"large history source decodes before measurement");
  const auto original=fixture.document.documentSession.buffer();
  fixture.document.documentSession.replace({0,original.length()},edited);
  const auto changed=fixture.document.documentSession.buffer();
  data=nil;
  input.clear(); input.shrink_to_fit(); edited.clear(); edited.shrink_to_fit();
  [fixture.view documentContentsDidChange]; (void)[fixture.view displayLineRanges];
  const auto initialLayoutBuilds=statistic(fixture.view,@"layoutBuilds");
  verifyLargeState(fixture.document,fixture.view,shape,u'b',changed);
  checkPreparedLayoutBuilds(fixture.view,initialLayoutBuilds,0);
  for (bool redo : {false,true}) {
    struct TimerState { Clock::time_point last; double maximum{}; std::uint64_t ticks{}; };
    auto timerState=std::make_shared<TimerState>(); timerState->last=Clock::now();
    NSTimer* timer=[NSTimer scheduledTimerWithTimeInterval:0.01 repeats:YES block:^(NSTimer*) {
      const auto now=Clock::now();
      timerState->maximum=std::max(timerState->maximum,
          std::chrono::duration<double,std::milli>(now-timerState->last).count());
      timerState->last=now; ++timerState->ticks;
    }];
    const auto begin=Clock::now();
    if (redo) [fixture.view redo:nil]; else [fixture.view undo:nil];
    const auto requested=Clock::now(); fixture.finish(); const auto completed=Clock::now();
    const auto ticksAtCompletion=timerState->ticks;
    check(pump([&]{return timerState->ticks>ticksAtCompletion;}),
        "main timer observes the terminal history commit/refresh before being invalidated");
    [timer invalidate];
    verifyLargeState(fixture.document,fixture.view,shape,redo?u'b':u'a',redo?changed:original);
    checkPreparedLayoutBuilds(fixture.view,initialLayoutBuilds,redo?2:1);
    check(fixture.document.isDocumentEdited==redo && fixture.document.notifications==(redo?2u:1u) &&
          fixture.document.undone==1 && fixture.document.redone==(redo?1u:0u) &&
          statistic(fixture.view,@"historyCompletions")==fixture.document.notifications &&
          statistic(fixture.view,@"historyLayoutsAdopted")==fixture.document.notifications,
        "large Undo/Redo keeps saved/dirty state, one notification and one prepared layout per transition");
    rusage usage{}; getrusage(RUSAGE_SELF,&usage);
    const auto milliseconds=[](auto duration) { return std::chrono::duration<double,std::milli>(duration).count(); };
    const auto stats=[fixture.view renderingStatistics];
    std::cout<<"scope=AppKit_view_without_window_drawing_real_IME_or_recovery_IO"
        <<" sourceBytes="<<bytes<<" logicalRows="<<rows<<" operation="<<(redo?"redo":"undo")
        <<" initialSourceEditAndLayoutOutsideTimer=1 verificationOutsideTimer=1"
        <<" completionExcludesTerminalTimerTickWait=1 mainTimerIncludesFirstTickAfterCompletion=1"
        <<" requestMilliseconds="<<milliseconds(requested-begin)
        <<" completionMilliseconds="<<milliseconds(completed-begin)
        <<" mainTimerMaximumGapMilliseconds="<<timerState->maximum<<" mainTimerTicks="<<timerState->ticks
        <<" mainCallbackMilliseconds="<<[stats[@"historyMainMilliseconds"] doubleValue]
        <<" layoutAdoptMilliseconds="<<[stats[@"historyAdoptMilliseconds"] doubleValue]
        <<" refreshMilliseconds="<<[stats[@"historyRefreshMilliseconds"] doubleValue]
        <<" initialLayoutBuilds="<<initialLayoutBuilds<<" layoutBuilds="<<[stats[@"layoutBuilds"] unsignedIntegerValue]
        <<" processLifetimeMaximumRssBytes="<<usage.ru_maxrss
        <<" lifetimeRssIncludesSetupAndVerification=1 verified="<<(failures==0)<<'\n';
  }
}
} // namespace
int main(int argc,char** argv) {
  @autoreleasepool {
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    try {
      if (argc>1 && std::string_view(argv[1])=="--benchmark-large-history") {
        currentCase="large history benchmark";
        const auto mib=argc>2?std::stoull(argv[2]):32;
        benchmarkLargeHistory(mib);
      } else {
        currentCase="normal and mixed queue"; normalTransitionsAndQueue();
        staleAndExplicitCancellation();
        currentCase="queue bound and timeout"; queueLimitAndTimeout();
        currentCase="window and view lifetime"; windowAndViewLifetimes();
        currentCase="real two-pane layout and IME"; realTwoPaneLayoutsAndComposition();
        publicationCallbackReentry();
        startPreparationExceptions();
        startExceptionPreservesNewerRequest();
        currentCase="post-commit display failure and caret"; postCommitFailureAndCaretBoundaries();
        queueBarrier();
      }
    } catch (const std::exception& error) {
      ++failures; std::cerr<<"asynchronous history test exception: "<<error.what()<<'\n';
    }
  }
  if (!failures) std::cout<<"All asynchronous history tests passed\n";
  else std::cerr<<failures<<" asynchronous history test(s) failed\n";
  return failures?1:0;
}
