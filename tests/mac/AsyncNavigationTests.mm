// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import "SakuraDocument.h"
#import "SakuraSearchState.h"
#import "SakuraWindowController.h"
#import "SearchTestSupport.h"
#include "sakura/platform/mac/StringBridge.h"
#include <functional>
#include <chrono>
#include <iostream>
#include <memory>
#include <string_view>
#include <vector>
@interface SakuraEditorView (AsyncNavigationTests)
- (void)prepareFindPanel;
- (void)findNext:(id)sender;
- (void)replaceSearchSelection:(id)sender;
- (void)refreshSearchHighlights:(id)sender;
- (NSDictionary*)renderingStatistics;
@end
@interface AsyncNavigationDocument : SakuraDocument
@end
@implementation AsyncNavigationDocument
- (void)noteEditorChange:(NSDocumentChangeType)change { (void)change; }
- (void)removeRecoveryBackup {}
- (void)scheduleRecoveryBackup {}
@end
@interface AsyncNavigationEditor : SakuraEditorView
@property(nonatomic,strong) SakuraSearchState* isolatedState;
@end
@implementation AsyncNavigationEditor
- (SakuraSearchState*)searchState {
  if(!self.isolatedState) self.isolatedState=[[SakuraSearchState alloc]init];
  return self.isolatedState;
}
@end
namespace {
int failures=0;
void check(bool value,const char* message){if(!value){std::cerr<<message<<'\n';++failures;}}
bool pump(const std::function<bool()>& predicate) {
  NSDate* until=[NSDate dateWithTimeIntervalSinceNow:6];
  while(!predicate() && until.timeIntervalSinceNow>0)
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
  return predicate();
}
struct Fixture {
  AsyncNavigationDocument* doc;
  AsyncNavigationEditor* view;
  Fixture(NSString* text,SakuraSearchState* state=nil) {
    doc=[[AsyncNavigationDocument alloc]init];doc.documentSession.insert(0,sakura::platform::mac::sakuraStringFromString(text));
    view=[[AsyncNavigationEditor alloc]initWithFrame:NSMakeRect(0,0,700,200) document:doc];
    if(state)view.isolatedState=state;
    [view prepareFindPanel];
  }
  NSTextField* field(NSString* key){return [view valueForKey:key];}
  NSButton* button(NSString* key){return [view valueForKey:key];}
  void query(NSString* text,BOOL regex=NO) {
    field(@"findField").stringValue=text;button(@"regularExpressionButton").state=regex?NSControlStateValueOn:NSControlStateValueOff;
  }
  bool settle(){return SakuraWaitForSearchNavigation(view);}
  void selected(NSUInteger start,NSUInteger length,const char* message){check(NSEqualRanges(view.selectedRange,NSMakeRange(start,length)),message);}
  NSString* status(){return field(@"findStatusLabel").stringValue;}
};
void benchmarkLargeSearch() {
  using Clock=std::chrono::steady_clock;
  auto milliseconds=[](auto duration){return std::chrono::duration<double,std::milli>(duration).count();};
  constexpr std::size_t count=100*1024*1024,rows=1000000;
  std::vector<std::byte> input(count,std::byte{'a'});
  const auto content=count-(rows-1), perLine=content/rows, extra=content%rows;
  std::size_t offset=0;
  for(std::size_t line=0;line<rows;++line) {
    offset+=perLine+(line<extra?1:0);
    if(line+1<rows)input[offset++]=std::byte{'\n'};
  }
  constexpr std::string_view needle="needle";
  for(std::size_t n=0;n<needle.size();++n) {
    input[n]=static_cast<std::byte>(needle[n]);input[count-needle.size()+n]=static_cast<std::byte>(needle[n]);
  }
  Fixture f(@"");
  {auto decoded=f.doc.documentSession.load(input,sakura::core::TextEncoding::utf8);check(decoded.ok(),"large search UTF-8 fixture decodes");}
  input.clear();input.shrink_to_fit();[f.view documentContentsDidChange];f.query(@"needle");
  const auto revision=f.doc.documentSession.buffer().revision();
  check(f.doc.documentSession.buffer().length()==count && f.doc.documentSession.buffer().lineCount()==rows,"large search fixture has exact size and line count");
  const auto start=Clock::now();[f.view findNext:nil];const auto requested=Clock::now();
  auto heartbeat=std::make_shared<bool>(false);auto heartbeatTime=std::make_shared<Clock::time_point>();
  dispatch_async(dispatch_get_main_queue(),^{*heartbeatTime=Clock::now();*heartbeat=true;});
  check(pump([&]{return *heartbeat;}),"large search main queue heartbeat delivered");
  check(f.settle(),"100 MiB forward search completed");const auto found=Clock::now();f.selected(0,6,"large first result exact");
  const auto reverseStart=Clock::now();[f.view findPrevious:nil];const auto reverseRequested=Clock::now();
  auto reverseHeartbeat=std::make_shared<bool>(false);auto reverseHeartbeatTime=std::make_shared<Clock::time_point>();
  dispatch_async(dispatch_get_main_queue(),^{*reverseHeartbeatTime=Clock::now();*reverseHeartbeat=true;});
  check(pump([&]{return *reverseHeartbeat;}),"large reverse search main queue heartbeat delivered");
  check(f.settle(),"100 MiB wrapped reverse search completed");const auto reverseFound=Clock::now();
  f.selected(count-6,6,"large wrapped reverse result exact");
  check(f.doc.documentSession.buffer().revision()==revision,"large search preserves source revision");
  std::cout<<"scope=AppKit_objects_search_without_window_drawing_or_IME\n"
    <<"source_bytes="<<count<<"\nlogical_lines="<<rows
    <<"\nforward_request_ms="<<milliseconds(requested-start)
    <<"\nmain_heartbeat_ms="<<milliseconds(*heartbeatTime-requested)
    <<"\nforward_result_ms="<<milliseconds(found-start)
    <<"\nreverse_request_ms="<<milliseconds(reverseRequested-reverseStart)
    <<"\nreverse_main_heartbeat_ms="<<milliseconds(*reverseHeartbeatTime-reverseRequested)
    <<"\nreverse_result_ms="<<milliseconds(reverseFound-reverseStart)<<'\n';
}
}
int main(int argc,char** argv){
 @autoreleasepool {
  [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
  if(argc==2 && std::string_view(argv[1])=="--benchmark-large-search") {benchmarkLargeSearch();return failures?1:0;}
  {
    Fixture f(@"a a a a");f.query(@"a");
    const auto revision=f.doc.documentSession.buffer().revision();
    [f.view findNext:nil];
    check(f.view.hasPendingSearchNavigation && !f.view.selectedRange.length,"forward search returns before worker completion");
    check([f.view.searchOperationStatus containsString:@"検索中"],"pending status available outside hidden find panel");
    [f.view findNext:nil];[f.view findNext:nil];[f.view findPrevious:nil];[f.view findNext:nil];
    check(f.settle(),"mixed queued navigation completes");f.selected(4,1,"mixed queued directions preserve user order");
    check([[f.view renderingStatistics][@"navigationCompletions"] unsignedIntegerValue]==5 && ![[f.view renderingStatistics][@"navigationWorkerOnMain"] boolValue],"all five selections computed off main thread");
    check(f.doc.documentSession.buffer().revision()==revision && f.doc.documentSession.buffer().text()==u"a a a a","navigation never modifies document");
  }
  {
    Fixture f(@"aa");f.query(@"(?=a)|$",YES);
    for(unsigned i=0;i<4;++i)[f.view findNext:nil];
    check(f.settle(),"zero-width queued search completes");f.selected(0,0,"zero width queue advances then wraps");
    [f.view jumpToDocumentOffset:0];[f.view findNext:nil];check(f.settle(),"manual reposition search completes");
    f.selected(0,0,"manual reposition resets zero-width continuation identity");
    f.button(@"searchWrapButton").state=NSControlStateValueOff;
    for(unsigned i=0;i<260;++i)[f.view findNext:nil];
    check(f.settle() && [f.status() containsString:@"末尾"],"large zero-width nowrap queue drains without recursion overflow");
    f.selected(2,0,"zero-width nowrap stops at true endpoint");
  }
  {
    Fixture f(@"a a");f.query(@"a");f.button(@"searchWrapButton").state=NSControlStateValueOff;
    [f.view findPrevious:nil];[f.view findNext:nil];
    check(f.settle(),"queue continues after a not-found request");f.selected(0,1,"later direction is not lost after nowrap failure");
  }
  {
    Fixture f(@"a a a a");f.query(@"a");[f.view findNext:nil];[f.view findNext:nil];
    NSProgress* old=[f.view valueForKey:@"searchNavigationProgress"];
    [f.view jumpToDocumentOffset:6];
    check(old.cancelled && !f.view.hasPendingSearchNavigation,"manual cursor move cancels active and queued requests");
    check(pump([&]{return old.completedUnitCount==2;}),"cancelled worker terminates");
    f.query(@"none");[f.view findNext:nil];check(f.settle(),"new query finishes after cancellation");
    f.selected(6,0,"old completion cannot overwrite manual cursor position");
    f.query(@"a");[f.view findNext:nil];old=[f.view valueForKey:@"searchNavigationProgress"];
    f.doc.documentSession.insert(0,u"changed ");[f.view documentContentsDidChange];
    check(old.cancelled && !f.view.hasPendingSearchNavigation && [f.status() containsString:@"中止"],"text edit cancels navigation");
    f.query(@"changed");[f.view jumpToDocumentOffset:0];[f.view findNext:nil];check(f.settle(),"search on new root completes");
    f.selected(0,7,"new snapshot supplies new document offsets");
  }
  {
    Fixture f(@"a a");f.query(@"a");[f.view findNext:nil];
    [f.doc close];
    check(f.settle(),"closed-document navigation reaches terminal state");
    f.selected(0,0,"a retained view cannot receive a late cursor jump after its document closes");
    check(f.doc.documentSession.buffer().text()==u"a a","closed-document cancellation preserves text");
  }
  {
    Fixture f(@"a a");f.query(@"a");[f.view findNext:nil];
    f.field(@"findField").stringValue=@"different";
    check(f.settle() && [f.status() containsString:@"変更"],"completion checks silently changed actual criteria");
    f.selected(0,0,"silent criteria change cannot apply stale selection");
    f.query(@"a");[f.view findNext:nil];
    [f.view setMarkedText:@"入力" selectedRange:NSMakeRange(0,0) replacementRange:NSMakeRange(0,0)];
    check(!f.view.hasPendingSearchNavigation && f.view.hasMarkedText,"IME preview cancels outstanding selection search");
    [f.view cancelOperation:nil];
    check(f.doc.documentSession.buffer().text()==u"a a","cancelling composition leaves source intact");
  }
  {
    Fixture f([[@"" stringByPaddingToLength:20000 withString:@"a" startingAtIndex:0] stringByAppendingString:@"b"]);
    f.query(@"(a+)+$",YES);[f.view findPrevious:nil];
    auto heartbeat=std::make_shared<bool>(false);dispatch_async(dispatch_get_main_queue(),^{*heartbeat=true;});
    check(f.view.hasPendingSearchNavigation && pump([&]{return *heartbeat;}),"main queue stays available during expensive reverse regex");
    check(f.settle() && [f.status() containsString:@"中止"],"reverse regex timeout is a nonmutating error");
    f.query(@"[",YES);[f.view findNext:nil];[f.view findNext:nil];
    check(f.settle() && [f.status() containsString:@"正規表現"],"invalid regex clears queued work without selecting anything");
    f.selected(0,0,"error leaves selection unchanged");
  }
  {
    Fixture f(@"cat cat");f.query(@"cat");f.field(@"replaceField").stringValue=@"dog";
    [f.view findNext:nil];[f.view replaceSearchSelection:nil];
    check(f.doc.documentSession.buffer().text()==u"cat cat" && [f.status() containsString:@"検索中"],"replace during pending navigation does not edit an unconfirmed selection");
    check(f.settle(),"find completes before explicit replacement");[f.view replaceSearchSelection:nil];
    check(SakuraWaitForReplacement(f.view),"single replacement finishes before post-replacement navigation");
    check(f.settle() && f.doc.documentSession.buffer().text()==u"dog cat","replacement schedules next search on new root");
    f.selected(4,3,"post-replacement navigation uses adjusted offset");
  }
  {
    Fixture f(@"cat cat");f.query(@"cat");[f.view findNext:nil];
    NSProgress* old=[f.view valueForKey:@"searchNavigationProgress"];
    [f.view countSearchMatches:nil];
    check(old.cancelled && !f.view.hasPendingSearchNavigation,"count supersedes pending navigation");
    check(pump([&]{return [f.status() containsString:@"2 件"]; }),"count after cancellation completes");
    f.selected(0,0,"count does not inherit a late cursor jump");
  }
  {
    SakuraSearchState* state=[[SakuraSearchState alloc]init];Fixture a(@"a a",state),b(@"a a",state);
    a.query(@"a");[a.view refreshSearchHighlights:nil];
    [b.view findNext:nil];NSProgress* pending=[b.view valueForKey:@"searchNavigationProgress"];
    [a.view findNext:nil];
    check(!pending.cancelled,"history-only shared notification does not cancel peer search");
    check(a.settle() && b.settle(),"both documents complete same shared query independently");
  }
  {
    Fixture f(@"a a");f.query(@"a");[f.view findNext:nil];[f.view findNext:nil];
    NSProgress* pending=[f.view valueForKey:@"searchNavigationProgress"];
    [f.view cancelSearchOperations:nil];
    check(pending.cancelled && !f.view.hasPendingSearchNavigation && [f.status() containsString:@"中止"],"explicit stop cancels active and queued navigation");
    [f.view findNext:nil];
    NSPanel* panel=[f.view valueForKey:@"findPanel"];
    check(panel.delegate==f.view,"find panel close delegate installed");
    [f.view windowWillClose:[NSNotification notificationWithName:NSWindowWillCloseNotification object:panel]];
    check(!f.view.hasPendingSearchNavigation,"closing find panel cancels search work");
  }
  {
    AsyncNavigationDocument* doc=[[AsyncNavigationDocument alloc]init];doc.documentSession.insert(0,u"a a");
    SakuraWindowController* controller=[[SakuraWindowController alloc]initWithDocument:doc];
    [doc addWindowController:controller];SakuraEditorView* editor=controller.editorView;
    [controller.window makeFirstResponder:editor];[editor findTextFromToolbar:@"a"];
    NSTextField* status=[controller valueForKey:@"statusMessage"];
    check([status.stringValue containsString:@"検索中"],"hidden find-panel job is visible in actual document status bar");
    check(SakuraWaitForSearchNavigation(editor) && [status.stringValue containsString:@"選択しました"],"actual status bar updates after async result");
    [controller.window close];[doc removeWindowController:controller];
  }
 }
 return failures?1:0;
}
