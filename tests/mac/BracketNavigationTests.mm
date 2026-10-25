// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import "SakuraAppDelegate.h"
#import "SakuraDocument.h"
#import "SakuraEditorView.h"
#import "SakuraWindowController.h"
#include "sakura/core/search/BracketSearch.h"
#include "sakura/platform/mac/StringBridge.h"
#include <atomic>
#include <functional>
#include <iostream>
#include <limits>
#include <memory>
#include <stdexcept>
#include <utility>

namespace {
struct Gate {
  dispatch_semaphore_t release = dispatch_semaphore_create(0);
  std::atomic<bool> entered{};
};
}

@interface SakuraEditorView (BracketTests)
- (NSDictionary*)bracketSearchStatistics;
- (NSTimeInterval)bracketSearchTimeLimit;
- (sakura::core::TextOffset)bracketSearchScanLimit;
- (std::function<void()>)bracketSearchWorkGate;
- (void)cancelOperation:(id)sender;
- (NSRect)localRectForDisplayIndex:(NSUInteger)offset;
- (NSUInteger)bracketSearchCaretOffset;
- (NSArray*)layoutConfigurationKey;
- (void)setFindStatus:(NSString*)status;
@end
@interface SakuraAppDelegate (BracketMenuTests)
- (void)installMainMenu;
@end
@interface BracketDocument : SakuraDocument
@property(nonatomic) NSUInteger editNotifications;
@end
@implementation BracketDocument
- (void)noteEditorChange:(NSDocumentChangeType)change { (void)change; ++self.editNotifications; }
- (void)scheduleRecoveryBackup {}
- (void)removeRecoveryBackup {}
@end
@interface BracketEditor : SakuraEditorView {
 @public
  std::shared_ptr<Gate> workGate;
}
@property(nonatomic) NSTimeInterval testTimeLimit;
@property(nonatomic) sakura::core::TextOffset testScanLimit;
@property(nonatomic) BOOL throwOnBracketJump;
@property(nonatomic) BOOL throwNextStartStatus;
@property(nonatomic) BOOL throwNextCapture;
@property(nonatomic) BOOL throwNextWorkerObjCException;
@property(nonatomic) BOOL throwNextJumpObjCException;
@property(nonatomic) BOOL throwNextCompletionStatus;
@property(nonatomic) BOOL restartBeforeException;
@end
@implementation BracketEditor
- (NSTimeInterval)bracketSearchTimeLimit { return self.testTimeLimit; }
- (sakura::core::TextOffset)bracketSearchScanLimit { return self.testScanLimit; }
- (NSArray*)layoutConfigurationKey {
  if (self.throwNextCapture) {
    self.throwNextCapture=NO;
    [NSException raise:NSInternalInconsistencyException format:@"isolated bracket capture failure"];
  }
  return [super layoutConfigurationKey];
}
- (void)setFindStatus:(NSString*)status {
  if (self.throwNextStartStatus && [status hasPrefix:@"対括弧を検索しています"]) {
    self.throwNextStartStatus=NO;
    if (self.restartBeforeException) { self.restartBeforeException=NO; [self jumpToMatchingBracket:nil]; }
    [NSException raise:NSInternalInconsistencyException format:@"isolated bracket start status failure"];
  }
  if (self.throwNextCompletionStatus && [status isEqualToString:@"対応する括弧へ移動しました。"]) {
    self.throwNextCompletionStatus=NO;
    [NSException raise:NSInternalInconsistencyException format:@"isolated bracket completion status failure"];
  }
  [super setFindStatus:status];
}
- (void)jumpToDocumentOffset:(NSUInteger)offset {
  if (self.throwNextJumpObjCException) {
    self.throwNextJumpObjCException=NO;
    if (self.restartBeforeException) { self.restartBeforeException=NO; [self jumpToMatchingBracket:nil]; }
    [NSException raise:NSInternalInconsistencyException format:@"isolated Objective-C bracket jump failure"];
  }
  if (self.throwOnBracketJump) throw std::runtime_error("isolated main-thread bracket display failure");
  [super jumpToDocumentOffset:offset];
}
- (std::function<void()>)bracketSearchWorkGate {
  const auto gate = workGate;
  const BOOL throwObjCException=self.throwNextWorkerObjCException;
  self.throwNextWorkerObjCException=NO;
  if (!gate && !throwObjCException) return {};
  return [gate,throwObjCException] {
    if (gate) {
      gate->entered = true;
      if (dispatch_semaphore_wait(gate->release, dispatch_time(DISPATCH_TIME_NOW, 10*NSEC_PER_SEC)))
        throw std::runtime_error("isolated bracket test gate timed out");
    }
    if (throwObjCException)
      [NSException raise:NSInternalInconsistencyException format:@"isolated bracket worker failure"];
  };
}
@end

namespace {
using namespace sakura::core;
int failures{};
void check(bool value, const char* message) {
  if (!value) { ++failures; std::cerr << message << '\n'; }
}
bool pump(const std::function<bool()>& condition, NSTimeInterval seconds = 10) {
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while (!condition() && deadline.timeIntervalSinceNow > 0)
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
        beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.003]];
  return condition();
}
struct Fixture {
  BracketDocument* document;
  BracketEditor* view;
  TextBuffer original;
  std::uint64_t savedState{};
  Fixture(NSString* text) {
    document = [[BracketDocument alloc] init];
    document.documentSession.insert(0,sakura::platform::mac::sakuraStringFromString(text));
    const auto saved = document.documentSession.makeSaveSnapshot();
    document.documentSession.markSaved(saved.token);
    savedState = saved.token.stateId;
    original = document.documentSession.buffer();
    view = [[BracketEditor alloc] initWithFrame:NSMakeRect(0,0,700,220) document:document];
    view.testTimeLimit = 5;
  }
  ~Fixture() {
    if (view && view->workGate) dispatch_semaphore_signal(view->workGate->release);
    [view cancelBracketSearch];
    [view cancelSyntaxHighlighting:nil];
  }
  void select(NSUInteger offset, NSUInteger length = 0) {
    [view setValue:[NSValue valueWithRange:NSMakeRange(offset,length)] forKey:@"committedSelection"];
  }
  NSUInteger stat(NSString* key) { return [[view bracketSearchStatistics][key] unsignedIntegerValue]; }
  void settle() { check(pump([&] { return !view.hasPendingBracketSearch; }), "bracket request reaches terminal state"); }
  void selected(NSUInteger offset, const char* message) {
    check(NSEqualRanges(view.selectedRange,NSMakeRange(offset,0)),message);
  }
  void unchanged() {
    const auto& buffer = document.documentSession.buffer();
    check(buffer.sharesStorageWith(original) && buffer.revision()==original.revision(), "bracket navigation preserves source root and revision");
    check(!document.isDocumentEdited && document.editNotifications==0, "bracket navigation never dirties or notifies an edit");
    check(document.documentSession.makeSaveSnapshot().token.stateId==savedState, "navigation does not add or consume Undo history");
    check(document.documentSession.canUndo() && !document.documentSession.canRedo(),
        "navigation preserves both Undo and Redo availability");
  }
  std::shared_ptr<Gate> block() {
    auto gate = std::make_shared<Gate>();
    view->workGate = gate;
    [view jumpToMatchingBracket:nil];
    check(pump([&] { return gate->entered.load(); }), "bracket operation enters worker gate");
    return gate;
  }
  void discardAfter(const std::shared_ptr<Gate>& gate, NSUInteger before) {
    dispatch_semaphore_signal(gate->release);
    check(pump([&] { return stat(@"discards")>before; }), "stale or cancelled bracket completion is discarded");
  }
};

void defaultsAndCaretSemantics() {
  for (const auto& pair : defaultBracketPairs()) {
    SakuraString source(1,pair.opening); source += u"😀\r\n"; source += pair.closing;
    Fixture fixture(sakura::platform::mac::stringFromSakuraString(source));
    fixture.select(0); [fixture.view jumpToMatchingBracket:nil]; fixture.settle();
    fixture.selected(5,"all documented default pairs navigate forward across Unicode and CRLF");
    [fixture.view jumpToMatchingBracket:nil]; fixture.settle();
    fixture.selected(0,"default pairs navigate backwards from a closing bracket");
    check(fixture.stat(@"completions")==2 && !fixture.stat(@"workerOnMain"), "both directions execute off main");
    fixture.unchanged();
  }
  {
    Fixture fixture(@"(x)");
    fixture.select(1); [fixture.view jumpToMatchingBracket:nil]; fixture.settle();
    fixture.selected(2,"nonbracket caret can use the preceding opening bracket");
    fixture.select(3); [fixture.view jumpToMatchingBracket:nil]; fixture.settle();
    fixture.selected(0,"EOF caret can use the preceding closing bracket on its logical line");
    fixture.unchanged();
  }
  {
    Fixture fixture(@"()["); fixture.select(2);
    [fixture.view jumpToMatchingBracket:nil]; fixture.settle();
    fixture.selected(2,"unmatched right-side bracket never falls back to matching left side");
    check([fixture.view.searchOperationStatus containsString:@"見つかりません"], "not-found status is visible");
    fixture.unchanged();
  }
  for (const auto& example : {std::pair<NSString*,NSUInteger>{@"([)]",2},
                              std::pair<NSString*,NSUInteger>{@"(/* ) */)",4},
                              std::pair<NSString*,NSUInteger>{@"(\" ) \")",3}}) {
    Fixture fixture(example.first); fixture.select(0);
    [fixture.view jumpToMatchingBracket:nil]; fixture.settle();
    fixture.selected(example.second,"bracket command counts only its own pair, including comment and string characters");
    fixture.unchanged();
  }
  {
    Fixture fixture(@"[a](b)"); fixture.select(0,3);
    [fixture.view jumpToMatchingBracket:nil]; fixture.settle();
    fixture.selected(5,"normal selection uses its active end caret rather than the sorted range start");
    fixture.select(0,3); [fixture.view setValue:@0 forKey:@"navigationCaret"];
    [fixture.view jumpToMatchingBracket:nil]; fixture.settle();
    fixture.selected(2,"backwards selection uses its active beginning caret");
    fixture.unchanged();
  }
  {
    NSMutableString* source = [@"(" mutableCopy];
    [source appendString:[@"" stringByPaddingToLength:24000 withString:@"x" startingAtIndex:0]];
    [source appendString:@")"];
    Fixture fixture(source); [fixture.view jumpToMatchingBracket:nil]; fixture.settle();
    fixture.selected(24001,"bracket result spans several bounded core read windows"); fixture.unchanged();
  }
}

void cancellationStaleAndResourceSafety() {
  for (unsigned mode=0;mode<10;++mode) {
    Fixture fixture(@"(x)");
    const auto before=fixture.stat(@"discards");
    const auto gate=fixture.block();
    switch(mode) {
      case 0: [fixture.view cancelBracketSearch]; break;
      case 1: [fixture.view cancelSearchOperations:nil]; break;
      case 2: [fixture.view cancelOperation:nil]; break;
      case 3: fixture.select(1); break;
      case 4: fixture.select(0); break; // Same range, newer manual selection generation.
      case 5: fixture.document.documentSession.insert(1,u"!"); [fixture.view documentContentsDidChange]; break;
      case 6: fixture.document.documentSession.insert(1,u"!"); fixture.document.documentSession.undo(); break;
      case 7: {
        const auto saved=fixture.document.documentSession.makeSaveSnapshot();
        check(fixture.document.documentSession.load(saved.encoded.bytes).ok(), "reload stale fixture"); break;
      }
      case 8: [fixture.view setMarkedText:@"未確定" selectedRange:NSMakeRange(3,0) replacementRange:NSMakeRange(0,0)]; break;
      case 9: [fixture.document close]; break;
    }
    fixture.discardAfter(gate,before);
    const auto observed=fixture.view.selectedRange;
    const auto committed=[[fixture.view valueForKey:@"committedSelection"] rangeValue];
    const auto expected=NSMakeRange(mode==3?1:mode==8?3:0,0);
    if(!NSEqualRanges(observed,expected))
      std::cerr<<"stale mode="<<mode<<" displayed="<<observed.location<<':'<<observed.length
          <<" committed="<<committed.location<<':'<<committed.length
          <<" marked="<<fixture.view.hasMarkedText<<'\n';
    if(mode==3) fixture.selected(1,"manual selection is not overwritten by late bracket result");
    else if(mode==8) {
      fixture.selected(3,"late bracket result preserves the IME's display caret rather than resetting it to the committed caret");
      check(NSEqualRanges(committed,NSMakeRange(0,0)) && fixture.view.hasMarkedText &&
          NSEqualRanges(fixture.view.markedRange,NSMakeRange(0,3)) &&
          [[[fixture.view valueForKey:@"markedTextStorage"] string] isEqualToString:@"未確定"],
          "uncommitted text and committed source selection both survive rejected bracket navigation");
      fixture.unchanged();
    } else fixture.selected(0,"cancel, edit, reload and close never apply an old bracket result");
    check(fixture.document.editNotifications==0,"rejected bracket result never emits an edit notification");
  }
  {
    Fixture fixture(@"(x)");
    const auto gate=fixture.block(); fixture.view->workGate.reset();
    [fixture.view jumpToMatchingBracket:nil];
    dispatch_semaphore_signal(gate->release); fixture.settle();
    check(pump([&]{return fixture.stat(@"discards")==1;}),"superseded completion is accounted for");
    check(fixture.stat(@"requests")==2 && fixture.stat(@"completions")==1,"new bracket request supersedes rather than queues a stale selection change");
    fixture.selected(2,"only the newest bracket request moves the caret"); fixture.unchanged();
  }
  for(unsigned mode=0;mode<2;++mode) {
    Fixture fixture(@"(xxxxxxxxxxxxxxxxxxxx)");
    if(mode==0) {
      fixture.view.testTimeLimit=0.001;
      auto gate=fixture.block();
      auto elapsed=std::make_shared<bool>(false);
      [NSTimer scheduledTimerWithTimeInterval:0.02 repeats:NO block:^(NSTimer*) {*elapsed=true;}];
      check(pump([&]{return *elapsed;}),"positive bracket deadline expires while the worker is gated");
      dispatch_semaphore_signal(gate->release);
    } else {
      fixture.view.testScanLimit=3;
      [fixture.view jumpToMatchingBracket:nil];
    }
    fixture.settle();
    fixture.selected(0,"timeout or scan cap cannot publish a partial bracket result");
    check(fixture.stat(@"errors")==1 && [fixture.view.searchOperationStatus containsString:@"中止"],"resource failure is reported");
    fixture.unchanged();
  }
  for(const double invalid : {0.0,-1.0,61.0,std::numeric_limits<double>::infinity(),
      -std::numeric_limits<double>::infinity(),std::numeric_limits<double>::quiet_NaN(),
      std::numeric_limits<double>::max()}) {
    Fixture fixture(@"(x)"); fixture.view.testTimeLimit=invalid;
    [fixture.view jumpToMatchingBracket:nil];
    check(!fixture.view.hasPendingBracketSearch && fixture.stat(@"requests")==0 && fixture.stat(@"errors")==1,
        "nonfinite, nonpositive and excessive deadlines are rejected before queueing or duration conversion");
    check([fixture.view.searchOperationStatus containsString:@"時間上限"],"invalid time budget reports its own error");
    fixture.selected(0,"invalid bracket budget never moves the selection"); fixture.unchanged();
  }
  {
    Fixture fixture(@"(x)"); fixture.view.throwOnBracketJump=YES;
    [fixture.view jumpToMatchingBracket:nil]; fixture.settle();
    check(fixture.stat(@"errors")==1 && [fixture.view.searchOperationStatus containsString:@"表示"],
        "main-thread navigation/display failure is reported after worker completion");
    fixture.selected(0,"failed result display does not apply the injected jump"); fixture.unchanged();
  }
  {
    Fixture fixture(@"(x)"); auto gate=fixture.block();
    auto ticks=std::make_shared<unsigned>(0);
    NSTimer* timer=[NSTimer scheduledTimerWithTimeInterval:0.002 repeats:YES block:^(NSTimer*) {++*ticks;}];
    check(pump([&]{return *ticks>=4;}),"main run loop advances while bracket worker is busy");
    [timer invalidate]; dispatch_semaphore_signal(gate->release); fixture.settle(); fixture.unchanged();
  }
}

void objectiveCExceptionsAndReentry() {
  for (unsigned mode=0;mode<5;++mode) {
    Fixture fixture(@"(x)");
    if (mode==0) fixture.view.throwNextStartStatus=YES;
    if (mode==1) fixture.view.throwNextCapture=YES;
    if (mode==2) fixture.view.throwNextWorkerObjCException=YES;
    if (mode==3) fixture.view.throwNextJumpObjCException=YES;
    if (mode==4) fixture.view.throwNextCompletionStatus=YES;
    [fixture.view jumpToMatchingBracket:nil]; fixture.settle();
    check(fixture.stat(@"errors")==1 && !fixture.view.hasPendingBracketSearch,
        "Objective-C start, capture, worker, jump and status failures all retire the owned request");
    fixture.selected(mode==4?2:0,"failed bracket operation never makes an uninjected jump");
    fixture.unchanged();
    fixture.select(0);
    [fixture.view jumpToMatchingBracket:nil]; fixture.settle();
    fixture.selected(2,"bracket worker queue remains usable after each Objective-C failure");
    fixture.unchanged();
  }
  for (bool duringJump : {false,true}) {
    Fixture fixture(@"(x)");
    fixture.view.restartBeforeException=YES;
    if (duringJump) fixture.view.throwNextJumpObjCException=YES;
    else fixture.view.throwNextStartStatus=YES;
    [fixture.view jumpToMatchingBracket:nil]; fixture.settle();
    check(fixture.stat(@"requests")==2 && fixture.stat(@"errors")==1 &&
          fixture.stat(@"completions")==static_cast<NSUInteger>(duringJump?2:1),
        "failure cleanup never clears a newer reentrant bracket request");
    fixture.selected(2,"newer request survives an old request's start or completion exception");
    fixture.unchanged();
  }
}

void rectangularCaretSafety() {
  for (unsigned mode=0;mode<2;++mode) {
    Fixture fixture(@"(x)\n[a]");
    const NSRect anchor=[fixture.view localRectForDisplayIndex:1];
    const NSRect current=[fixture.view localRectForDisplayIndex:4];
    const NSPoint point=NSMakePoint(NSMinX(current)+0.1,NSMidY(current));
    [fixture.view setValue:@YES forKey:@"rectangularSelectionActive"];
    [fixture.view setValue:[NSValue valueWithPoint:NSMakePoint(NSMinX(anchor)+0.1,NSMidY(anchor))]
        forKey:@"rectangularAnchorPoint"];
    [fixture.view setValue:[NSValue valueWithPoint:point] forKey:@"rectangularCurrentPoint"];
    check([fixture.view bracketSearchCaretOffset]==4,"rectangular command derives the active visual caret");
    if(mode==0) {
      [fixture.view jumpToMatchingBracket:nil]; fixture.settle();
      fixture.selected(6,"rectangular caret searches its bracket and returns a normal caret");
      check(!fixture.view.hasRectangularSelection,"successful bracket command exits unlocked rectangular selection");
    } else {
      const auto before=fixture.stat(@"discards"); auto gate=fixture.block();
      [fixture.view setValue:[NSValue valueWithPoint:NSMakePoint(point.x+15,point.y)] forKey:@"rectangularCurrentPoint"];
      fixture.discardAfter(gate,before);
      fixture.selected(0,"moving a rectangle without changing the linear selection invalidates old bracket work");
    }
    fixture.unchanged();
  }
}

void windowsPanesAndLifetime() {
  {
    Fixture fixture(@"(x)");
    NSWindow* window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,700,250)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO; window.contentView=fixture.view; [window makeFirstResponder:fixture.view];
    auto gate=fixture.block(); const auto before=fixture.stat(@"discards");
    [window close]; fixture.discardAfter(gate,before); fixture.selected(0,"closing a hidden editor window cancels pending bracket navigation");
  }
  for (bool switchWhilePending : {false,true}) {
    Fixture blocker(@"(x)"); auto gate=blocker.block();
    BracketDocument* document=[[BracketDocument alloc] init];
    document.documentSession.insert(0,u"(x)");
    document.documentSession.markSaved(document.documentSession.makeSaveSnapshot().token);
    const auto original=document.documentSession.buffer();
    const auto state=document.documentSession.makeSaveSnapshot().token.stateId;
    BracketDocument* other=[[BracketDocument alloc] init];
    other.documentSession.insert(0,u"[other]");
    other.documentSession.markSaved(other.documentSession.makeSaveSnapshot().token);
    const auto otherOriginal=other.documentSession.buffer();
    SakuraWindowController* controller=[[SakuraWindowController alloc] initWithDocument:document];
    [document addWindowController:controller]; [controller toggleSplitEditor:nil];
    SakuraEditorView* first=controller.editorViews.firstObject;
    SakuraEditorView* second=controller.editorViews.lastObject;
    const auto before=[[[first bracketSearchStatistics] objectForKey:@"discards"] unsignedIntegerValue];
    if (switchWhilePending) {
      [first jumpToMatchingBracket:nil];
      check(first.hasPendingBracketSearch,"peer-owner fixture starts a pending bracket request");
    }
    [second setValue:other forKey:@"sakuraDocument"];
    if (!switchWhilePending) {
      [first jumpToMatchingBracket:nil];
      check(!first.hasPendingBracketSearch && [first.searchOperationStatus containsString:@"ペイン"],
          "mismatched peer document is refused before bracket work starts");
    }
    dispatch_semaphore_signal(gate->release);
    if (switchWhilePending)
      check(pump([&]{return [[[first bracketSearchStatistics] objectForKey:@"discards"] unsignedIntegerValue]>before;}),
          "peer document replacement invalidates already prepared bracket navigation");
    check(NSEqualRanges(first.selectedRange,NSMakeRange(0,0)) &&
          document.documentSession.buffer().sharesStorageWith(original) &&
          document.documentSession.buffer().revision()==original.revision() &&
          document.documentSession.makeSaveSnapshot().token.stateId==state &&
          document.documentSession.canUndo() && !document.documentSession.canRedo() &&
          other.documentSession.buffer().sharesStorageWith(otherOriginal) &&
          other.documentSession.buffer().revision()==otherOriginal.revision() &&
          !document.isDocumentEdited && !other.isDocumentEdited &&
          document.editNotifications==0 && other.editNotifications==0,
        "peer-owner mismatch preserves both documents, original history and caret");
    [second setValue:document forKey:@"sakuraDocument"];
    [controller.window close]; [document removeWindowController:controller];
  }
  {
    // Hold the common serial queue with a separate isolated document so the
    // actual split-pane editor can be tested without replacing its view class.
    Fixture blocker(@"(x)"); auto gate=blocker.block();
    BracketDocument* document=[[BracketDocument alloc] init];
    document.documentSession.insert(0,u"(x)");
    document.documentSession.markSaved(document.documentSession.makeSaveSnapshot().token);
    SakuraWindowController* controller=[[SakuraWindowController alloc] initWithDocument:document];
    [document addWindowController:controller]; [controller toggleSplitEditor:nil];
    check(controller.editorViews.count==2,"actual controller has two bracket-search panes");
    SakuraEditorView* first=controller.editorViews.firstObject;
    SakuraEditorView* second=controller.editorViews.lastObject;
    [second setMarkedText:@"入力" selectedRange:NSMakeRange(2,0) replacementRange:NSMakeRange(0,0)];
    [first jumpToMatchingBracket:nil];
    check(!first.hasPendingBracketSearch && [first.searchOperationStatus containsString:@"IME"],"existing peer composition prevents bracket command");
    [second cancelOperation:nil];
    [first jumpToMatchingBracket:nil];
    check(first.hasPendingBracketSearch,"actual split-pane bracket request is queued");
    const auto before=[[[first bracketSearchStatistics] objectForKey:@"discards"] unsignedIntegerValue];
    [second setMarkedText:@"途中入力" selectedRange:NSMakeRange(4,0) replacementRange:NSMakeRange(0,0)];
    [second cancelOperation:nil]; // Even a cancelled peer composition invalidates the old request.
    dispatch_semaphore_signal(gate->release);
    check(pump([&]{return [[[first bracketSearchStatistics] objectForKey:@"discards"] unsignedIntegerValue]>before;}),"peer IME start/end invalidates queued bracket search");
    check(NSEqualRanges(first.selectedRange,NSMakeRange(0,0)),"peer IME cannot cause a stale jump or focus steal");
    [first jumpToMatchingBracket:nil];
    check(pump([&]{return !first.hasPendingBracketSearch;}),"split-pane bracket navigation completes after IME ends");
    check(NSEqualRanges(first.selectedRange,NSMakeRange(2,0)) && NSEqualRanges(second.selectedRange,NSMakeRange(0,0)),"successful navigation changes only the invoking pane");
    check(!document.isDocumentEdited && document.editNotifications==0,"two-pane bracket navigation does not edit shared text");
    NSArray* history=[controller valueForKey:@"navigationHistory"];
    check(history.count>=2 && [history.firstObject unsignedIntegerValue]==0 && [history.lastObject unsignedIntegerValue]==2,
          "bracket jump records ordinary navigation history");
    [controller.window close]; [document removeWindowController:controller];
  }
  {
    auto gate=std::make_shared<Gate>(); __weak BracketEditor* weakView;
    @autoreleasepool {
      Fixture fixture(@"(x)"); fixture.view->workGate=gate; weakView=fixture.view;
      [fixture.view jumpToMatchingBracket:nil]; check(pump([&]{return gate->entered.load();}),"lifetime fixture reaches worker");
      fixture.view=nil;
    }
    check(!weakView,"worker does not retain the editor object");
    dispatch_semaphore_signal(gate->release);
    Fixture sentinel(@"[x]"); [sentinel.view jumpToMatchingBracket:nil]; sentinel.settle();
    sentinel.selected(2,"queue remains usable after owner destruction");
  }
}

NSMenuItem* bracketItem(NSMenu* menu) {
  for(NSMenuItem* item in menu.itemArray) {
    if(item.action==@selector(jumpToMatchingBracket:)) return item;
    if(item.submenu) if(NSMenuItem* found=bracketItem(item.submenu)) return found;
  }
  return nil;
}
void menuAndKeyboard() {
  SakuraAppDelegate* delegate=[[SakuraAppDelegate alloc] init]; [delegate installMainMenu];
  NSMenuItem* item=bracketItem(NSApp.mainMenu);
  check(item && item.enabled && [item.title isEqual:@"対括弧の検索"],"upstream-position menu command is implemented and enabled");
  check([item.keyEquivalent isEqual:@"]"] && item.keyEquivalentModifierMask==NSEventModifierFlagCommand,"macOS command shortcut is explicit");
  Fixture fixture(@"(x)"); item.target=fixture.view;
  NSEvent* key=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
      modifierFlags:NSEventModifierFlagCommand timestamp:0 windowNumber:0 context:nil
      characters:@"]" charactersIgnoringModifiers:@"]" isARepeat:NO keyCode:30];
  check([NSApp.mainMenu performKeyEquivalent:key],"menu key equivalent dispatches the bracket selector");
  fixture.settle(); fixture.selected(2,"keyboard/menu command reaches bracket navigation"); fixture.unchanged();
}
} // namespace

int main() {
  @autoreleasepool {
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    defaultsAndCaretSemantics(); cancellationStaleAndResourceSafety(); objectiveCExceptionsAndReentry();
    rectangularCaretSafety(); windowsPanesAndLifetime(); menuAndKeyboard();
  }
  if(!failures) std::cout<<"All bracket navigation tests passed\n";
  return failures?1:0;
}
