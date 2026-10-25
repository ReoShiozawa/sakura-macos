// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import "SakuraDocument.h"
#import "SakuraEditorView.h"
#include "sakura/platform/mac/StringBridge.h"
#include <functional>
#include <iostream>
#include <memory>
#include <vector>
@interface SakuraEditorView (AsyncHighlightTests)
- (const std::vector<NSRange>&)activeSearchRanges;
- (NSDictionary*)renderingStatistics;
@end
@interface AsyncHighlightDocument : SakuraDocument
@end
@implementation AsyncHighlightDocument
- (void)noteEditorChange:(NSDocumentChangeType)change { (void)change; }
@end
@interface AsyncVisiblePanel : NSPanel
@end
@implementation AsyncVisiblePanel
- (BOOL)isVisible { return YES; }
@end
namespace {
int failures=0;
void check(bool value,const char* message) {if(!value){std::cerr<<message<<'\n';++failures;}}
bool pump(const std::function<bool()>& predicate) {
  NSDate* end=[NSDate dateWithTimeIntervalSinceNow:5];
  while(!predicate() && end.timeIntervalSinceNow>0)
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
  return predicate();
}
struct Fixture {
  AsyncHighlightDocument* doc;
  SakuraEditorView* view;
  NSSearchField* query;
  NSButton* regex;
  Fixture(NSString* text) {
    doc=[[AsyncHighlightDocument alloc]init];
    doc.documentSession.insert(0,sakura::platform::mac::sakuraStringFromString(text));
    view=[[SakuraEditorView alloc]initWithFrame:NSMakeRect(0,0,700,200) document:doc];
    query=[[NSSearchField alloc]init]; regex=[[NSButton alloc]init];
    NSButton* caseButton=[[NSButton alloc]init];caseButton.state=NSControlStateValueOn;
    [view setValue:[[AsyncVisiblePanel alloc]init] forKey:@"findPanel"];
    [view setValue:query forKey:@"findField"]; [view setValue:regex forKey:@"regularExpressionButton"];
    [view setValue:caseButton forKey:@"caseSensitiveButton"];
    [view setValue:[[NSButton alloc]init] forKey:@"wholeWordButton"];
  }
  bool pending() {return [[view renderingStatistics][@"searchPending"] boolValue];}
  bool settle() {return pump([&]{return !pending();});}
};
}
int main() {
 @autoreleasepool {
  [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
  {
    Fixture f(@"cat dog cat"); f.query.stringValue=@"cat";
    check([f.view activeSearchRanges].empty() && f.pending(),"draw request schedules asynchronous work without scanning inline");
    check(f.settle(),"asynchronous highlighting completes");
    const auto& ranges=[f.view activeSearchRanges];
    check(ranges.size()==2 && NSEqualRanges(ranges[0],NSMakeRange(0,3)) && NSEqualRanges(ranges[1],NSMakeRange(8,3)),"async literal ranges exact");
    check(![[f.view renderingStatistics][@"searchWorkerOnMain"] boolValue] && [[f.view renderingStatistics][@"searchCompletions"] unsignedIntegerValue]==1,"accepted highlight result was computed off main thread");
    f.query.stringValue=@"dog";
    check([f.view activeSearchRanges].empty() && f.pending(),"new query immediately hides old highlights");
    f.doc.documentSession.insert(0,u"new ");[f.view documentContentsDidChange];
    check([f.view activeSearchRanges].empty() && f.pending() && f.settle(),"edit cancels old job and schedules latest immutable snapshot");
    check([f.view activeSearchRanges].size()==1 && NSEqualRanges([f.view activeSearchRanges][0],NSMakeRange(8,3)),"old snapshot cannot overwrite newer document offsets");
  }
  {
    Fixture f(@"cat cat");f.query.stringValue=@"cat";(void)[f.view activeSearchRanges];
    f.query.stringValue=@"none"; // No redraw/notification before the queued completion.
    check(pump([&]{return [[f.view renderingStatistics][@"searchDiscards"] unsignedIntegerValue]>0;}),"completion revalidates actual current query, not only scheduled cache key");
    check([f.view activeSearchRanges].empty() && f.settle() && [f.view activeSearchRanges].empty(),"stale result never becomes visible");
    f.query.stringValue=@"cat";(void)[f.view activeSearchRanges];
    [f.view setMarkedText:@"未確定" selectedRange:NSMakeRange(0,0) replacementRange:NSMakeRange(0,0)];
    check([f.view activeSearchRanges].empty() && !f.pending(),"IME hides and cancels highlighting");
    [f.view cancelOperation:nil];(void)[f.view activeSearchRanges];
    check(f.settle() && [f.view activeSearchRanges].size()==2,"highlighting resumes after composition cancellation");
    [f.view clearSearchMarks:nil];
    check([f.view activeSearchRanges].empty() && !f.pending(),"clear marks cancels pending work and hides accepted highlights");
  }
  {
    Fixture f([[@"" stringByPaddingToLength:12000 withString:@"a" startingAtIndex:0] stringByAppendingString:@"b"]);
    f.query.stringValue=@"(a+)+$";f.regex.state=NSControlStateValueOn;
    (void)[f.view activeSearchRanges]; auto heartbeat=std::make_shared<bool>(false);
    dispatch_async(dispatch_get_main_queue(),^{*heartbeat=true;});
    check(f.pending() && pump([&]{return *heartbeat;}),"main queue remains available while expensive regex is pending");
    check(f.settle() && [f.view activeSearchRanges].empty() && [f.view.searchHighlightStatus containsString:@"中止"],"regex time limit discards incomplete highlight result");
    f.query.stringValue=@"[";(void)[f.view activeSearchRanges];
    check(f.settle() && [f.view.searchHighlightStatus containsString:@"正規表現"],"malformed pattern reports nonfatal highlight status");
  }
  {
    Fixture f([@"" stringByPaddingToLength:40020 withString:@"cat " startingAtIndex:0]);
    const auto original = f.doc.documentSession.buffer().text();
    const auto revision = f.doc.documentSession.buffer().revision();
    f.query.stringValue=@"cat";(void)[f.view activeSearchRanges];
    check(f.settle() && [f.view activeSearchRanges].size()==10000 && [f.view.searchHighlightStatus containsString:@"10,000"],"async result limit is explicit and retains first ten thousand ranges");
    check(f.doc.documentSession.buffer().text()==original && f.doc.documentSession.buffer().revision()==revision,"highlighting never changes source text or revision");
  }
 }
 return failures ? 1:0;
}
