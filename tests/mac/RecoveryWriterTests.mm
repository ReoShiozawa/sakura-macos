// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import <AppKit/AppKit.h>
#import "SakuraAppDelegate.h"
#import "SakuraDocument.h"
#import "SakuraRecoveryStore.h"
#import "SakuraRecoveryWriter.h"
#include "sakura/platform/mac/StringBridge.h"
#include <atomic>
#include <functional>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <vector>

@interface SakuraRecoveryWriter (Testing)
- (instancetype)initWithWriteHandler:(BOOL (^)(NSURL*, NSDictionary*, unsigned long long,
    NSUInteger, NSError**))writer removeHandler:(BOOL (^)(NSURL*, NSError**))remover;
@end
@interface SakuraAppDelegate (TerminationTesting)
- (NSDocumentController*)documentControllerForTermination;
@end
@interface SakuraDocument (RecoveryPipelineTesting)
@property(nonatomic, strong) SakuraRecoveryWriter* recoveryWriter;
- (NSURL*)recoveryBackupURL;
- (void)writeRecoveryBackupIfNeeded;
- (void)reportRecoveryError:(NSError*)error removing:(BOOL)removing;
@end
@interface RecoveryPipelineDocument : SakuraDocument
@property(nonatomic, strong) NSURL* isolatedURL;
@property(nonatomic) NSUInteger errors;
@end
@implementation RecoveryPipelineDocument
- (NSURL*)recoveryBackupURL { return self.isolatedURL; }
- (void)scheduleRecoveryBackup {} // No user defaults/timers in isolated fixtures.
- (void)reportRecoveryError:(NSError*)error removing:(BOOL)removing {
  (void)removing;
  if (error) ++self.errors;
}
@end

// Deliberately not NSApplication/NSDocumentController subclasses: tests never
// terminate the process, touch real documents, or replace AppKit singletons.
@interface TerminationApplication : NSObject
@property(nonatomic) NSUInteger replies;
@property(nonatomic) BOOL lastReply;
- (void)replyToApplicationShouldTerminate:(BOOL)reply;
@end
@implementation TerminationApplication
- (void)replyToApplicationShouldTerminate:(BOOL)reply {
  ++self.replies;
  self.lastReply = reply;
}
@end
@interface TerminationController : NSObject
@property(nonatomic, copy) NSArray* documents;
@property(nonatomic) NSUInteger requests;
@property(nonatomic, strong) id callback;
@property(nonatomic) SEL selector;
- (void)closeAllDocumentsWithDelegate:(id)delegate didCloseAllSelector:(SEL)selector contextInfo:(void*)context;
- (void)finish:(BOOL)closed;
@end
@implementation TerminationController
- (void)closeAllDocumentsWithDelegate:(id)delegate didCloseAllSelector:(SEL)selector contextInfo:(void*)context {
  (void)context;
  ++self.requests; self.callback = delegate; self.selector = selector;
}
- (void)finish:(BOOL)closed {
  if (closed) self.documents = @[];
  id callback = self.callback;
  SEL selector = self.selector;
  self.callback = nil;
  using Callback = void (*)(id, SEL, NSDocumentController*, BOOL, void*);
  ((Callback)[callback methodForSelector:selector])(callback, selector,
      (NSDocumentController*)self, closed, nullptr);
}
@end
@interface TerminationDelegate : SakuraAppDelegate
@property(nonatomic, strong) TerminationController* controller;
@end

@interface ReviewedTerminationDocument : NSObject
@property(nonatomic, weak) TerminationController* controller;
@property(nonatomic) NSUInteger closes;
- (void)close;
@end
@implementation ReviewedTerminationDocument
- (void)close {
  ++self.closes;
  NSMutableArray* documents = [self.controller.documents mutableCopy];
  [documents removeObjectIdenticalTo:self];
  self.controller.documents = documents;
}
@end
@implementation TerminationDelegate
- (NSDocumentController*)documentControllerForTermination { return (NSDocumentController*)self.controller; }
@end

namespace {
int failures = 0;
void check(bool value, const char* label) {
  if (!value) { ++failures; std::cerr << label << '\n'; }
}
bool pump(const std::function<bool()>& predicate, NSTimeInterval seconds = 10,
          NSString* mode = NSDefaultRunLoopMode) {
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while (!predicate() && deadline.timeIntervalSinceNow > 0)
    [NSRunLoop.currentRunLoop runMode:mode
        beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
  return predicate();
}
void drain() {
  auto done = std::make_shared<bool>(false);
  SakuraRecoveryWhenIdle(^{ check(NSThread.isMainThread, "drain callback on main"); *done = true; });
  check(pump([&]{ return *done; }), "recovery queue drains");
}
NSDictionary* metadata() {
  return @{@"version":@1, @"encoding":@1, @"bom":@NO, @"sourceEncodingAmbiguous":@YES,
      @"lineEnding":@"CRLF", @"date":NSDate.date, @"displayName":@"isolated",
      @"originalPath":@"/not-a-user-document"};
}
struct Events {
  dispatch_semaphore_t release = dispatch_semaphore_create(0);
  std::atomic<bool> entered{}, offMain{true};
  std::atomic<unsigned> writes{};
  std::mutex mutex;
  std::vector<sakura::core::SakuraString> values;
};
SakuraRecoveryWriter* gatedWriter(std::shared_ptr<Events> events, bool failFirst = false,
                                 bool throwFirst = false) {
  return [[SakuraRecoveryWriter alloc] initWithWriteHandler:^BOOL(NSURL* url, NSDictionary* record,
      unsigned long long budget, NSUInteger generations, NSError** error) {
    if (NSThread.isMainThread) events->offMain = false;
    auto value = sakura::platform::mac::sakuraStringFromString(record[@"text"]);
    {
      std::lock_guard lock(events->mutex); events->values.push_back(std::move(value));
    }
    if (++events->writes == 1) {
      events->entered = true;
      if (dispatch_semaphore_wait(events->release, dispatch_time(DISPATCH_TIME_NOW, 10*NSEC_PER_SEC))) {
        if (error) *error = [NSError errorWithDomain:@"IsolatedTestTimeout" code:1 userInfo:nil];
        return NO;
      }
      if (throwFirst) throw std::runtime_error("isolated worker failure");
      if (failFirst) {
        if (error) *error = [NSError errorWithDomain:@"IsolatedTestFailure" code:1 userInfo:nil];
        return NO;
      }
    }
    return SakuraWriteRecoveryWithGenerations(url, record, budget, generations, error);
  } removeHandler:^BOOL(NSURL* url, NSError** error) {
    if (NSThread.isMainThread) events->offMain = false;
    {
      std::lock_guard lock(events->mutex); events->values.push_back(u"<remove>");
    }
    return SakuraRemoveRecoveryChecked(url, error);
  }];
}
void enqueue(SakuraRecoveryWriter* writer, sakura::core::TextBuffer& source, NSURL* url,
             void (^completion)(NSError*)) {
  [writer writeSnapshot:source metadata:metadata() toURL:url budget:1024*1024
      generations:2 completion:completion];
}

void coalescingOrderingAndLifetime(NSURL* directory) {
  for (unsigned mode = 0; mode < 7; ++mode) {
    NSURL* url = [directory URLByAppendingPathComponent:
        [NSString stringWithFormat:@"mode-%u.sakura-recovery", mode]];
    auto events = std::make_shared<Events>();
    SakuraRecoveryWriter* writer = gatedWriter(events, mode == 5, mode == 6);
    sakura::core::TextBuffer source(u"first\r\n😀");
    __block unsigned completed = 0, errors = 0;
    void (^completion)(NSError*) = ^(NSError* error) {
      check(NSThread.isMainThread, "operation completion on main");
      ++completed; if (error) ++errors;
    };
    enqueue(writer, source, url, completion);
    check(pump([&]{ return events->entered.load(); }), "worker reaches gated durable I/O");
    // Mutating and releasing the original source must not alter its frozen job.
    for (unsigned index = 0; index < 100; ++index) {
      source.assign(index == 99 ? u"latest\n桜" : u"superseded");
      enqueue(writer, source, url, completion);
    }
    if (mode >= 1 && mode <= 3) {
      [writer removeAtURL:url completion:completion];
      if (mode == 2) {
        source.assign(u"after-removal"); enqueue(writer, source, url, completion);
      } else if (mode == 3) {
        source.assign(u"must-not-return"); enqueue(writer, source, url, completion);
        [writer removeAtURL:url completion:completion];
      }
    }
    if (mode == 4) writer = nil; // Queued work must outlive document/writer ownership.
    source.assign(u"not the queued text");
    auto idle = std::make_shared<bool>(false);
    SakuraRecoveryWhenIdle(^{ *idle = true; });
    auto mainTicks = std::make_shared<unsigned>(0);
    NSTimer* timer = [NSTimer scheduledTimerWithTimeInterval:0.002 repeats:YES
        block:^(NSTimer*) { ++*mainTicks; }];
    // Cover delayed delivery deterministically as well as the runner's own
    // scheduling: no first tick is eligible inside the former 30 ms window.
    if (mode == 0) timer.fireDate = [NSDate dateWithTimeIntervalSinceNow:0.05];
    // Timer coalescing and runner scheduling do not guarantee four callbacks
    // in a fixed 30 ms window. Keep I/O gated until actual main-loop progress
    // is observed, while an early drain still fails immediately.
    const bool progressed = pump([&]{ return *mainTicks > 3 || *idle; }, 2);
    if (!progressed || *mainTicks <= 3 || *idle || completed != 0)
      std::cerr << "gated I/O mode=" << mode << " timerTicks=" << *mainTicks
                << " idle=" << *idle << " completions=" << completed << '\n';
    check(progressed && *mainTicks > 3, "main run loop makes progress during gated I/O");
    check(!*idle && completed == 0, "idle drain and completions cannot precede active I/O");
    [timer invalidate];
    dispatch_semaphore_signal(events->release);
    check(pump([&]{ return *idle; }), "idle callback follows active and queued operations");
    check(events->offMain && completed == 1 && errors == 0, "only latest authentic completion is delivered");
    std::vector<sakura::core::SakuraString> values;
    { std::lock_guard lock(events->mutex); values = events->values; }
    std::vector<sakura::core::SakuraString> expected{u"first\r\n😀"};
    if (mode >= 1 && mode <= 3) expected.push_back(u"<remove>");
    if (mode == 2) expected.push_back(u"after-removal");
    else if (mode == 0 || mode >= 4) expected.push_back(u"latest\n桜");
    check(values == expected, "bounded coalescing preserves removal barriers and frozen Unicode text");
    NSDictionary* stored = SakuraReadRecovery(url);
    if (mode == 1 || mode == 3) check(!stored, "remove prevents late backup resurrection");
    else {
      check([stored[@"text"] isEqualToString:mode == 2 ? @"after-removal" : @"latest\n桜"],
          "latest frozen snapshot is durably stored");
      check([stored[@"sourceEncodingAmbiguous"] boolValue], "snapshot preserves uncertainty metadata");
    }
    if (mode == 2) {
      NSURL* previous = [NSURL fileURLWithPath:[url.path stringByAppendingString:@".previous-1"]];
      check(![NSFileManager.defaultManager fileExistsAtPath:previous.path], "new post-removal write cannot archive obsolete backup");
    }
    check(SakuraRemoveRecoveryChecked(url, nil), "clean isolated scenario records");
  }
}

void shutdownReviewAndDrain(NSURL* directory) {
  TerminationDelegate* delegate = [[TerminationDelegate alloc] init];
  delegate.controller = [[TerminationController alloc] init];
  ReviewedTerminationDocument* reviewed = [[ReviewedTerminationDocument alloc] init];
  reviewed.controller = delegate.controller;
  delegate.controller.documents = @[reviewed];
  TerminationApplication* application = [[TerminationApplication alloc] init];
  check([delegate applicationShouldTerminate:(NSApplication*)application] == NSTerminateLater,
      "shutdown defers for recovery after AppKit's document review");
  check(delegate.controller.requests == 0 && application.replies == 0, "no reply before NSTerminateLater returns");
  check(reviewed.closes == 1, "already reviewed documents close without a second save prompt");
  CFRunLoopAddCommonMode(CFRunLoopGetCurrent(), (__bridge CFStringRef)NSModalPanelRunLoopMode);
  check(pump([&]{ return application.replies == 1; }, 10, NSModalPanelRunLoopMode) && application.lastReply,
      "idle drain is delivered in AppKit's termination modal mode");
  auto nestedDone = std::make_shared<bool>(false);
  dispatch_async(dispatch_get_main_queue(), ^{
    TerminationDelegate* nested = [[TerminationDelegate alloc] init];
    nested.controller = [[TerminationController alloc] init];
    nested.controller.documents = @[];
    TerminationApplication* nestedApplication = [[TerminationApplication alloc] init];
    [nested applicationShouldTerminate:(NSApplication*)nestedApplication];
    check(pump([&]{ return nestedApplication.replies == 1; }, 3, NSModalPanelRunLoopMode) && nestedApplication.lastReply,
        "nested termination modal loop cannot deadlock waiting on its own main GCD queue");
    *nestedDone = true;
  });
  check(pump([&]{ return *nestedDone; }), "nested modal termination test returns");

  auto events = std::make_shared<Events>();
  SakuraRecoveryWriter* writer = gatedWriter(events);
  NSURL* url = [directory URLByAppendingPathComponent:@"shutdown.sakura-recovery"];
  sakura::core::TextBuffer source(u"pending before close");
  enqueue(writer, source, url, nil);
  check(pump([&]{ return events->entered.load(); }), "shutdown fixture has real live I/O");
  [writer removeAtURL:url completion:nil];
  reviewed = [[ReviewedTerminationDocument alloc] init];
  reviewed.controller = delegate.controller;
  delegate.controller.documents = @[reviewed];
  [delegate applicationShouldTerminate:(NSApplication*)application];
  check(reviewed.closes == 1 && delegate.controller.requests == 0, "approved close requests no duplicate review");
  [delegate applicationShouldTerminate:(NSApplication*)application];
  check(reviewed.closes == 1, "duplicate quit cannot repeat document close");
  check(application.replies == 1, "quit waits for outstanding write and ordered removal");
  delegate.controller.documents = @[[NSObject new]]; // New document opened during the drain.
  dispatch_semaphore_signal(events->release);
  check(pump([&]{ return delegate.controller.requests == 1; }, 10, NSModalPanelRunLoopMode), "new document during drain gets close review");
  check(application.replies == 1 && !SakuraReadRecovery(url), "no premature quit and cleanup completed");
  [delegate.controller finish:NO];
  check(application.replies == 2 && !application.lastReply, "new document can cancel pending quit");
  // NSApplication's next preflight has now approved the remaining document.
  reviewed = [[ReviewedTerminationDocument alloc] init];
  reviewed.controller = delegate.controller;
  delegate.controller.documents = @[reviewed];
  [delegate applicationShouldTerminate:(NSApplication*)application];
  check(reviewed.closes == 1, "subsequent quit remains usable");
  check(pump([&]{ return application.replies == 3; }, 10, NSModalPanelRunLoopMode) && application.lastReply,
      "successful close plus idle drain finally approves quit");
}

void documentPipeline(NSURL* directory) {
  for (unsigned mode = 0; mode < 5; ++mode) {
    RecoveryPipelineDocument* document = [[RecoveryPipelineDocument alloc] init];
    document.isolatedURL = [directory URLByAppendingPathComponent:
        [NSString stringWithFormat:@"document-%u.sakura-recovery", mode]];
    NSData* original = [@"original" dataUsingEncoding:NSUTF8StringEncoding];
    check([document readFromData:original ofType:@"public.plain-text" error:nil], "load pipeline document");
    auto events = std::make_shared<Events>();
    document.recoveryWriter = gatedWriter(events, mode == 4);
    if (mode == 4) {
      NSMutableDictionary* previous = [metadata() mutableCopy];
      previous[@"text"] = @"previous-safe";
      check(SakuraWriteRecovery(document.isolatedURL, previous, 1024*1024, nil), "seed previous durable backup");
    }
    document.documentSession.insert(8, u"!");
    [document writeRecoveryBackupIfNeeded];
    check(pump([&]{ return events->entered.load(); }), "actual document enters background write");
    if (mode == 0) {
      NSURL* file = [directory URLByAppendingPathComponent:@"saved.txt"];
      check([document writeToURL:file ofType:@"public.plain-text" error:nil], "explicit save succeeds during recovery I/O");
      check(!document.isDocumentEdited, "save marks exactly saved text clean");
    } else if (mode == 1) {
      check([document readFromData:[@"reloaded" dataUsingEncoding:NSUTF8StringEncoding]
          ofType:@"public.plain-text" error:nil], "successful reload supersedes recovery");
    } else if (mode == 2) {
      [document close];
      [document writeRecoveryBackupIfNeeded]; // A late timer/message after close is harmless.
    } else if (mode == 3) {
      const unsigned char invalid[] = {0xEF, 0xBB, 0xBF, 0xFF};
      check(![document readFromData:[NSData dataWithBytes:invalid length:sizeof(invalid)]
          ofType:@"public.plain-text" error:nil], "failed reload preserves document and pending recovery");
    }
    dispatch_semaphore_signal(events->release);
    drain();
    if (mode <= 2) {
      check(!SakuraReadRecovery(document.isolatedURL), "save/reload/close prevent obsolete backup resurrection");
      check(document.errors == 0, "superseded completion cannot report a stale error");
    } else if (mode == 3) {
      check([SakuraReadRecovery(document.isolatedURL)[@"text"] isEqualToString:@"original!"],
          "failed reload still stores original dirty snapshot");
      check(document.isDocumentEdited && document.documentSession.buffer().text() == u"original!",
          "failed reload preserves dirty text");
    } else {
      check(document.errors == 1 && document.isDocumentEdited, "latest recovery error is delivered without clearing dirty text");
      check([SakuraReadRecovery(document.isolatedURL)[@"text"] isEqualToString:@"previous-safe"],
          "I/O failure preserves previous durable backup");
      [document writeRecoveryBackupIfNeeded];
      drain();
      check([SakuraReadRecovery(document.isolatedURL)[@"text"] isEqualToString:@"original!"],
          "recovery can retry after I/O failure");
    }
    [document close];
    drain();
  }
}
} // namespace

int main() {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSURL* directory = [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    check([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:nil], "create owned fixture directory");
    coalescingOrderingAndLifetime(directory);
    documentPipeline(directory);
    shutdownReviewAndDrain(directory);
    drain();
    [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
  }
  if (!failures) std::cout << "All recovery writer tests passed\n";
  return failures ? 1 : 0;
}
