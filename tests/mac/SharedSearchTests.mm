// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import "SakuraDocument.h"
#import "SakuraEditorView.h"
#import "SakuraSearchState.h"
#import "SearchTestSupport.h"
#include "sakura/platform/mac/StringBridge.h"
#include <functional>
#include <iostream>

@interface SakuraEditorView (SharedSearchTests)
- (void)prepareFindPanel;
- (void)findNext:(id)sender;
- (void)replaceAll:(id)sender;
- (void)replaceSearchSelection:(id)sender;
- (void)changeSearchScope:(id)sender;
- (void)captureSearchScope:(id)sender;
- (void)refreshSearchHighlights:(id)sender;
- (void)chooseReplacementHistory:(id)sender;
@end
@interface SharedSearchDocument : SakuraDocument
@end
@implementation SharedSearchDocument
- (void)noteEditorChange:(NSDocumentChangeType)change { (void)change; }
@end
@interface SharedSearchEditor : SakuraEditorView
@property(nonatomic, strong) SakuraSearchState* isolatedState;
@end
@implementation SharedSearchEditor
- (SakuraSearchState*)searchState { return self.isolatedState; }
@end
namespace {
int failures = 0;
void check(bool ok, const char* label) { if (!ok) { std::cerr << label << '\n'; ++failures; } }
bool pump(const std::function<bool()>& predicate) {
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:5];
  while (!predicate() && deadline.timeIntervalSinceNow > 0)
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  return predicate();
}
struct Fixture {
  SharedSearchDocument* doc;
  SharedSearchEditor* view;
  NSScrollView* scroll;
  Fixture(NSString* text, SakuraSearchState* state = nil) {
    doc = [[SharedSearchDocument alloc] init];
    doc.documentSession.insert(0, sakura::platform::mac::sakuraStringFromString(text));
    view = [[SharedSearchEditor alloc] initWithFrame:NSMakeRect(0, 0, 700, 250) document:doc];
    view.isolatedState = state != nil ? state : [[SakuraSearchState alloc] init];
    scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 700, 150)]; scroll.documentView = view;
    [view prepareFindPanel];
  }
  NSTextField* field(NSString* key) { return [view valueForKey:key]; }
  NSButton* button(NSString* key) { return [view valueForKey:key]; }
  void query(NSString* q, NSString* replacement = @"", BOOL regex = NO) {
    field(@"findField").stringValue = q; field(@"replaceField").stringValue = replacement;
    button(@"regularExpressionButton").state = regex ? NSControlStateValueOn : NSControlStateValueOff;
  }
  void select(NSUInteger start, NSUInteger length) { [view setValue:[NSValue valueWithRange:NSMakeRange(start,length)] forKey:@"committedSelection"]; }
  void scope(NSUInteger start, NSUInteger length) { select(start, length); [view captureSearchScope:nil]; }
  NSString* text() { return sakura::platform::mac::stringFromSakuraString(doc.documentSession.buffer().text()); }
  NSString* status() { return field(@"findStatusLabel").stringValue; }
};
NSDictionary* criteria(NSString* query, NSString* replacement) {
  return @{@"query":query, @"replacement":replacement, @"caseSensitive":@YES, @"wholeWord":@NO, @"regex":@NO, @"wrap":@YES};
}
}
int main() {
  @autoreleasepool {
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    {
      SakuraSearchState* state = [[SakuraSearchState alloc] init];
      NSMutableString* value = [@"original" mutableCopy];
      check([state updateCriteria:criteria(value,@"x") source:nil rememberQuery:YES rememberReplacement:YES], "valid criteria accepted");
      [value setString:@"changed"];
      check([state.criteria[@"query"] isEqual:@"original"], "shared criteria copy mutable input");
      for (NSUInteger n=0;n<25;++n) [state updateCriteria:criteria([NSString stringWithFormat:@"q%lu",(unsigned long)n],@"") source:nil rememberQuery:YES rememberReplacement:YES];
      check(state.queryHistory.count == 20 && state.replacementHistory.count == 2, "histories bounded and deduplicated including empty replacement");
      [state updateCriteria:criteria(@"q20",@"") source:nil rememberQuery:YES rememberReplacement:NO];
      check(state.queryHistory.count == 20 && [state.queryHistory.firstObject isEqual:@"q20"], "history promotion deduplicates");
      check(![state updateCriteria:criteria([@"" stringByPaddingToLength:4097 withString:@"x" startingAtIndex:0],@"") source:nil rememberQuery:YES rememberReplacement:NO], "oversized query rejected");
      [state clearHistory]; check(!state.queryHistory.count && !state.replacementHistory.count && [state.criteria[@"query"] length] == 0, "clear removes history and current text");
    }
    {
      SakuraSearchState* state = [[SakuraSearchState alloc] init];
      Fixture a(@"cat CAT dog",state), b(@"CAT cat",state);
      a.query(@"cat",@"new"); a.button(@"caseSensitiveButton").state = NSControlStateValueOff;
      a.button(@"wholeWordButton").state = NSControlStateValueOn;
      a.button(@"searchWrapButton").state = NSControlStateValueOff;
      [a.view refreshSearchHighlights:nil];
      check([b.field(@"findField").stringValue isEqual:@"cat"] && [b.field(@"replaceField").stringValue isEqual:@"new"] &&
          b.button(@"caseSensitiveButton").state == NSControlStateValueOff && b.button(@"searchWrapButton").state == NSControlStateValueOff, "conditions shared between documents");
      a.scope(0,7);
      check(b.button(@"searchScopeButton").state == NSControlStateValueOff, "selection region never shared across documents");
      [b.view findNext:nil]; check(SakuraWaitForSearchNavigation(b.view), "shared search completes");
      check(NSEqualRanges(b.view.selectedRange,NSMakeRange(0,3)), "shared Unicode flags applied");
      [a.view clearSharedSearchHistory:nil];
      check(!a.field(@"findField").stringValue.length && !b.field(@"findField").stringValue.length && !state.queryHistory.count, "clear shared history updates every panel");
      check(((NSSearchField*)a.field(@"findField")).recentsAutosaveName == nil, "native recents never autosave to disk");
      NSPanel* panel = [a.view valueForKey:@"findPanel"];
      for (NSView* control in panel.contentView.subviews) check(NSContainsRect(panel.contentView.bounds,control.frame), "search controls inside panel");
    }
    {
      Fixture f(@"OUT cat cat OUT cat"); f.scope(4,7); f.query(@"cat",@"doggy"); [f.view replaceAll:nil];
      check(SakuraWaitForReplacement(f.view), "scoped replacement preparation completes");
      check([f.text() isEqual:@"OUT doggy doggy OUT cat"], "scoped replace leaves outside source unchanged");
      check(NSEqualRanges(f.view.selectedRange,NSMakeRange(4,11)), "scope expands with replacement length");
      check(f.doc.documentSession.undo() && [f.text() isEqual:@"OUT cat cat OUT cat"], "one undo restores scoped operation");
      [f.view documentContentsDidChange]; [f.view replaceAll:nil];
      check([f.text() isEqual:@"OUT cat cat OUT cat"] && [f.status() containsString:@"再指定"], "stale scope cannot become full-document replace");
    }
    {
      Fixture f(@"pre aa aa post"); f.scope(4,5); f.query(@"(a)(a)",@"$2$1X",YES); [f.view jumpToDocumentOffset:4];
      [f.view findNext:nil]; check(SakuraWaitForSearchNavigation(f.view), "scoped regex search completes");
      [f.view replaceSearchSelection:nil]; check(SakuraWaitForReplacement(f.view), "scoped single replacement completes");
      check(SakuraWaitForSearchNavigation(f.view), "post-replacement search completes");
      check([f.text() isEqual:@"pre aaX aa post"] && NSEqualRanges(f.view.selectedRange,NSMakeRange(8,2)), "single regex replace updates scope and selects next scoped match");
    }
    {
      Fixture f(@"aa"); f.query(@"(?=a)|$",@"",YES); f.button(@"searchWrapButton").state = NSControlStateValueOff;
      [f.view findNext:nil]; [f.view findNext:nil]; [f.view findNext:nil]; [f.view findNext:nil];
      check(SakuraWaitForSearchNavigation(f.view), "queued zero-width searches complete");
      check(NSEqualRanges(f.view.selectedRange,NSMakeRange(2,0)) && [f.status() containsString:@"末尾"], "zero-width nowrap search stops at end");
      [f.view jumpToDocumentOffset:0]; [f.view findPrevious:nil];
      check(SakuraWaitForSearchNavigation(f.view), "nowrap reverse search completes");
      check(NSEqualRanges(f.view.selectedRange,NSMakeRange(0,0)) && [f.status() containsString:@"見つかりません"], "backward nowrap does not wrap");
    }
    {
      Fixture f(@"(a) dog DOG"); f.select(0,3); [f.view useSelectionForFind:nil];
      check([f.field(@"findField").stringValue isEqual:@"(a)"] && f.button(@"regularExpressionButton").state == NSControlStateValueOff, "selection becomes literal query");
      [f.view findNext:nil]; check(SakuraWaitForSearchNavigation(f.view), "selection literal search completes");
      check(NSEqualRanges(f.view.selectedRange,NSMakeRange(0,3)), "selection query preserves metacharacters literally");
      f.button(@"caseSensitiveButton").state = NSControlStateValueOff;
      [f.view jumpToDocumentOffset:8]; [f.view findTextFromToolbar:@"dog"];
      check(SakuraWaitForSearchNavigation(f.view), "toolbar search completes");
      check(NSEqualRanges(f.view.selectedRange,NSMakeRange(8,3)), "toolbar uses current shared search flags");
    }
    {
      Fixture f(@"cat cat OUT cat"); f.scope(0,7); f.query(@"cat");
      [f.view countSearchMatches:nil];
      check(pump([&]{return [f.status() containsString:@"2 件"]; }), "async count respects selection scope");
      check([f.text() isEqual:@"cat cat OUT cat"] && NSEqualRanges(f.view.selectedRange,NSMakeRange(0,7)), "count does not edit or move selection");
      f.query(@"OUT"); [f.view refreshSearchHighlights:nil];
      check(!f.status().length, "new criteria clear stale count status");
      f.query(@"cat");
      [f.view countSearchMatches:nil]; f.doc.documentSession.insert(0,u"new "); [f.view documentContentsDidChange];
      check([f.status() containsString:@"中止"], "edit cancels pending count");
    }
    {
      Fixture f(@"cat cat"); f.query(@"[",@"",YES);
      [f.view countSearchMatches:nil];
      check(pump([&]{return [f.status() containsString:@"正規表現が正しくありません"]; }), "count validates malformed regex on worker");
      f.query(@"cat"); [f.view countSearchMatches:nil];
      f.field(@"findField").stringValue = @"other"; // Deliberately no control notification.
      check(pump([&]{return [f.view valueForKey:@"searchCountProgress"]==nil;}), "count revalidates actual query at completion");
      check(![f.status() containsString:@"2 件"], "stale count never appears after silent condition change");
    }
  }
  return failures ? 1 : 0;
}
