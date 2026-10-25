// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import "SakuraAppDelegate.h"
#import "SakuraDocument.h"
#import "SakuraWindowController.h"
#import "SakuraEditorView.h"
#include <iostream>
#include <functional>

@interface SakuraAppDelegate (WorkflowTesting)
- (void)installMainMenu;
- (NSArray<NSDocument*>*)documentsForSaveAll;
- (NSArray<NSURL*>*)recentDocumentURLs;
- (void)clearRecentHistory:(id)sender;
@end
@interface SakuraDocument (SaveTesting)
- (void)scheduleRecoveryBackup;
- (void)removeRecoveryBackup;
@end
@interface SakuraWindowController (CommandListTesting)
- (void)appendCommandsFromMenu:(NSMenu*)menu prefix:(NSString*)prefix to:(NSMutableArray<NSDictionary*>*)entries;
@end

@interface WorkflowDelegate : SakuraAppDelegate
@property(nonatomic, copy) NSArray<NSDocument*>* testDocuments;
@property(nonatomic, copy) NSArray<NSURL*>* testURLs;
@property(nonatomic) BOOL clearedHistory;
@end
@implementation WorkflowDelegate
- (NSArray<NSDocument*>*)documentsForSaveAll { return self.testDocuments; }
- (NSArray<NSURL*>*)recentDocumentURLs { return self.testURLs; }
- (void)clearRecentHistory:(id)sender { (void)sender; self.clearedHistory = YES; }
@end

@interface DeferredDocument : SakuraDocument
@property(nonatomic) BOOL dirty;
@property(nonatomic) BOOL closed;
@property(nonatomic) NSUInteger saveRequests;
@property(nonatomic, strong) id saveDelegate;
@property(nonatomic) SEL saveSelector;
@property(nonatomic) void* saveContext;
- (void)finish:(BOOL)success dirty:(BOOL)dirty;
@end
@implementation DeferredDocument
- (BOOL)isDocumentEdited { return self.dirty; }
- (void)saveDocumentWithDelegate:(id)delegate didSaveSelector:(SEL)selector contextInfo:(void*)context {
  ++self.saveRequests; self.saveDelegate = delegate;
  self.saveSelector = selector; self.saveContext = context;
}
- (void)finish:(BOOL)success dirty:(BOOL)dirty {
  self.dirty = dirty;
  id delegate = self.saveDelegate; SEL selector = self.saveSelector;
  void* context = self.saveContext;
  self.saveDelegate = nil;
  using Callback = void (*)(id, SEL, NSDocument*, BOOL, void*);
  ((Callback)[delegate methodForSelector:selector])(delegate, selector, self, success, context);
}
- (void)close { self.closed = YES; }
@end

@interface SnapshotEditDocument : SakuraDocument
@property(nonatomic) BOOL editDuringSave;
@property(nonatomic) BOOL changeEncodingDuringSave;
@property(nonatomic) NSUInteger recoveryRemovals;
@property(nonatomic) NSUInteger recoverySchedules;
@end
@implementation SnapshotEditDocument
- (NSData*)dataOfType:(NSString*)type error:(NSError**)error {
  NSData* data = [super dataOfType:type error:error];
  if (data && self.editDuringSave) self.documentSession.insert(self.documentSession.buffer().length(), u"!");
  if (data && self.changeEncodingDuringSave)
    self.documentSession.setEncodingState({sakura::core::TextEncoding::utf16BigEndian, true});
  return data;
}
- (void)scheduleRecoveryBackup { ++self.recoverySchedules; }
- (void)removeRecoveryBackup { ++self.recoveryRemovals; }
@end

namespace {
int failures = 0;
void check(bool value, const char* label) {
  if (!value) { std::cerr << label << '\n'; ++failures; }
}
bool pump(const std::function<bool()>& predicate) {
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:3];
  while (!predicate() && deadline.timeIntervalSinceNow > 0)
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  return predicate();
}
DeferredDocument* dirtyDocument() {
  DeferredDocument* doc = [[DeferredDocument alloc] init]; doc.dirty = YES; return doc;
}
}
int main() {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    {
      WorkflowDelegate* delegate = [[WorkflowDelegate alloc] init];
      DeferredDocument *a = dirtyDocument(), *b = dirtyDocument(), *clean = [[DeferredDocument alloc] init];
      delegate.testDocuments = @[a, clean, b];
      [delegate saveAllDocuments:nil]; [delegate saveAllDocuments:nil];
      check(a.saveRequests == 1 && b.saveRequests == 0, "save all serial and reentry guarded");
      [a finish:YES dirty:NO];
      check(pump([&]{ return b.saveRequests == 1; }), "second document starts after success");
      [b finish:YES dirty:NO];
      check(pump([&]{ return ![[delegate valueForKey:@"savingAllDocuments"] boolValue]; }), "save all completes");
      check(clean.saveRequests == 0, "clean document skipped");
      check(!a.closed && !b.closed, "save all never closes documents");
    }
    for (NSUInteger mode = 0; mode < 2; ++mode) {
      WorkflowDelegate* delegate = [[WorkflowDelegate alloc] init];
      DeferredDocument *a = dirtyDocument(), *b = dirtyDocument();
      delegate.testDocuments = @[a, b];
      [delegate saveAllDocuments:nil];
      [a finish:mode == 1 dirty:YES];
      check(![[delegate valueForKey:@"savingAllDocuments"] boolValue] && b.saveRequests == 0,
            "cancel or post-snapshot edit stops save all");
      [delegate saveAllDocuments:nil];
      check(a.saveRequests == 2, "queue restart after cancellation");
      [a finish:NO dirty:YES];
    }
    {
      WorkflowDelegate* delegate = [[WorkflowDelegate alloc] init];
      DeferredDocument *a = dirtyDocument(), *b = dirtyDocument();
      delegate.testDocuments = @[a, b]; [delegate saveAllDocuments:nil];
      delegate.testDocuments = @[a]; // User closed b while a's save panel was open.
      [a finish:YES dirty:NO];
      check(pump([&]{ return ![[delegate valueForKey:@"savingAllDocuments"] boolValue]; }) && b.saveRequests == 0,
            "document closed while queued is not reopened for saving");
    }
    for (NSUInteger mode = 0; mode < 3; ++mode) {
      DeferredDocument* doc = dirtyDocument();
      [doc saveAndClose:nil]; [doc saveAndClose:nil];
      check(doc.saveRequests == 1, "save close reentry guarded");
      [doc finish:mode != 0 dirty:mode != 2];
      check(doc.closed == (mode == 2), "close requires successful save and no new edits");
    }
    {
      NSURL* folder = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
      [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
      NSURL* file = [folder URLByAppendingPathComponent:@"snapshot.txt"];
      SnapshotEditDocument* doc = [[SnapshotEditDocument alloc] init];
      doc.fileURL = file;
      doc.documentSession.insert(0, u"abc"); doc.editDuringSave = YES;
      NSError* error = nil;
      check([doc writeToURL:file ofType:@"public.plain-text" error:&error], "write own snapshot fixture");
      check([[NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:nil] isEqual:@"abc"], "disk contains saved snapshot");
      check(doc.isDocumentEdited && doc.recoverySchedules == 1 && doc.recoveryRemovals == 0,
            "post-snapshot edit keeps recovery and remains dirty");
      doc.editDuringSave = NO;
      check([doc writeToURL:file ofType:@"public.plain-text" error:&error] && !doc.isDocumentEdited,
            "second save writes new edit");
      check(doc.recoveryRemovals == 1, "clean successful save removes own recovery");
      doc.documentSession.insert(0, u"new");
      check(![doc writeToURL:folder ofType:@"public.plain-text" error:&error], "I/O failure reported");
      check(doc.isDocumentEdited && doc.recoveryRemovals == 1, "I/O failure preserves dirty state and recovery");
      [NSFileManager.defaultManager removeItemAtURL:folder error:nil];
    }
    {
      NSURL* folder = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
      [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
      NSURL* file = [folder URLByAppendingPathComponent:@"encoding-snapshot.txt"];
      SnapshotEditDocument* doc = [[SnapshotEditDocument alloc] init];
      doc.documentSession.insert(0, u"abc");
      doc.changeEncodingDuringSave = YES;
      check([doc writeToURL:file ofType:@"public.plain-text" error:nil], "save old encoding snapshot");
      check([[NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:nil] isEqual:@"abc"],
            "first save retains original encoding bytes");
      check(doc.documentSession.encodingState() == (sakura::core::EncodingState{sakura::core::TextEncoding::utf16BigEndian, true}) && doc.isDocumentEdited,
            "late save completion cannot overwrite new encoding choice");
      check(doc.recoverySchedules == 1 && doc.recoveryRemovals == 0, "new encoding choice retains recovery until next save");
      doc.changeEncodingDuringSave = NO;
      check([doc writeToURL:file ofType:@"public.plain-text" error:nil] && !doc.isDocumentEdited,
            "second save persists new encoding choice");
      const auto data = [NSData dataWithContentsOfURL:file];
      const unsigned char* bytes = static_cast<const unsigned char*>(data.bytes);
      check(data.length == 8 && bytes[0] == 0xFE && bytes[1] == 0xFF && bytes[3] == 'a',
            "new encoding and BOM appear in actual saved bytes");
      [NSFileManager.defaultManager removeItemAtURL:folder error:nil];
    }
    {
      SnapshotEditDocument* doc = [[SnapshotEditDocument alloc] init];
      SakuraWindowController* controller = [[SakuraWindowController alloc] initWithDocument:doc];
      [doc addWindowController:controller];
      [controller.editorView setMarkedText:@"未確定" selectedRange:NSMakeRange(3, 0)
                         replacementRange:NSMakeRange(NSNotFound, 0)];
      check(!doc.isDocumentEdited && controller.editorView.hasMarkedText,
            "IME fixture has uncommitted input only");
      [doc commitPendingInput];
      check(doc.isDocumentEdited && !controller.editorView.hasMarkedText,
            "save preparation commits IME before dirty check");
      NSData* data = [doc dataOfType:@"public.plain-text" error:nil];
      check([[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] isEqual:@"未確定"],
            "save snapshot includes pending Japanese input");
      WorkflowDelegate* delegate = [[WorkflowDelegate alloc] init];
      [delegate installMainMenu];
      NSMutableArray<NSDictionary*>* commands = [NSMutableArray array];
      [controller appendCommandsFromMenu:NSApp.mainMenu prefix:@"" to:commands];
      NSArray* actions = [commands valueForKey:@"action"];
      for (NSString* action in @[@"saveAllDocuments:", @"saveAndClose:", @"showLineJump:",
          @"toggleBookmark:", @"sortLinesAscending:", @"deleteLogicalLines:", @"insertDate:", @"copyWithCRLF:"])
        check([actions containsObject:action], "new actions visible in command list");
      [controller.window close];
      [doc removeWindowController:controller];
    }
    {
      const unsigned char bytes[] = {0xa4, 0xa2};
      NSData* data = [NSData dataWithBytes:bytes length:sizeof(bytes)];
      SnapshotEditDocument* doc = [[SnapshotEditDocument alloc] init];
      check([doc readFromData:data ofType:@"public.plain-text" error:nil], "read ambiguous Japanese fixture");
      SakuraWindowController* controller = [[SakuraWindowController alloc] initWithDocument:doc];
      [doc addWindowController:controller];
      [controller updateStatusForEditor:controller.editorView];
      NSTextField* encoding = [controller valueForKey:@"statusEncoding"];
      NSTextField* status = [controller valueForKey:@"statusMessage"];
      check([encoding.stringValue hasPrefix:@"? "] && [encoding.toolTip containsString:@"推定"] &&
            [status.stringValue containsString:@"保存前に確認"], "read-time ambiguity is visible in real status controls");
      [doc setOutputEncoding:sakura::core::TextEncoding::utf8 writeBom:NO];
      check([encoding.stringValue containsString:@"UTF-8"] && [encoding.stringValue containsString:@"?"] &&
            [status.stringValue containsString:@"保存前に確認"],
            "changing output encoding does not silently confirm input interpretation");
      NSURL* file = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
      check([data writeToURL:file atomically:YES], "write explicit-reload fixture");
      doc.fileURL = file;
      check([doc reloadUsingEncoding:sakura::core::TextEncoding::shiftJis error:nil], "explicit CP932 reload succeeds");
      check(doc.documentSession.buffer().text() == u"､｢" && ![encoding.stringValue containsString:@"?"] &&
            ![status.stringValue containsString:@"保存前に確認"], "explicit reload changes interpretation and clears warning");
      [NSFileManager.defaultManager removeItemAtURL:file error:nil];
      [controller.window close];
      [doc removeWindowController:controller];
    }
    {
      WorkflowDelegate* delegate = [[WorkflowDelegate alloc] init];
      delegate.testURLs = @[[NSURL fileURLWithPath:@"/example/one/a.txt"],
          [NSURL fileURLWithPath:@"/example/one/b.txt"], [NSURL fileURLWithPath:@"/example/one/a.txt"],
          [NSURL URLWithString:@"https://example.com/not-a-file"], [NSURL fileURLWithPath:@"/example/two/c.txt"]];
      [delegate installMainMenu];
      NSMenu* fileMenu = [NSApp.mainMenu itemWithTitle:@"ファイル"].submenu;
      NSMenu* files = [fileMenu itemWithTitle:@"最近使ったファイル"].submenu;
      NSMenu* folders = [fileMenu itemWithTitle:@"最近使ったフォルダー"].submenu;
      [delegate menuNeedsUpdate:files]; [delegate menuNeedsUpdate:folders];
      check(files.numberOfItems == 5 && folders.numberOfItems == 4, "history deduplicates files and folders, ignores network URLs");
      check([files.itemArray.firstObject.representedObject isEqual:delegate.testURLs.firstObject], "history keeps real URL separate from display title");
      NSMenu* copied = [folders copy];
      check(copied.delegate == delegate, "window menu copy retains update delegate");
      delegate.testURLs = @[]; [delegate menuNeedsUpdate:copied];
      check(copied.numberOfItems == 3 && !copied.itemArray.firstObject.enabled, "empty history refreshes copied menu");
      [delegate clearRecentHistory:nil]; check(delegate.clearedHistory, "clear uses test double, not real history");
      NSMutableArray* many = [NSMutableArray array];
      for (NSUInteger i = 0; i < 30; ++i) [many addObject:[NSURL fileURLWithPath:[NSString stringWithFormat:@"/example/%lu.txt", (unsigned long)i]]];
      delegate.testURLs = many; [delegate menuNeedsUpdate:files];
      check(files.numberOfItems == 22, "recent menu bounded at 20 plus separator and clear");
    }
  }
  return failures ? 1 : 0;
}
