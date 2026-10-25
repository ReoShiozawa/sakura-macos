// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import "SakuraDurableFile.h"
#import "SakuraDocument.h"
#import "SakuraRecoveryStore.h"
#import "SakuraWindowController.h"
#include <iostream>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
extern char** environ;

@interface SakuraDocument (DurabilityTests)
- (BOOL)synchronizeSavedFileAtURL:(NSURL*)url error:(NSError**)error;
- (void)removeRecoveryBackup;
- (void)scheduleRecoveryBackup;
@end
@interface SakuraWindowController (DurableSettingsTests)
- (NSUserDefaults*)commonSettingsDefaults;
- (void)applyCommonSettings:(id)sender;
- (void)prepareCommonSettingsPanel;
@end
@interface DurableSettingsController : SakuraWindowController
@property(nonatomic, strong) NSUserDefaults* isolatedDefaults;
@end
@implementation DurableSettingsController
- (NSUserDefaults*)commonSettingsDefaults { return self.isolatedDefaults; }
@end
@interface DurabilityDocument : SakuraDocument
@property(nonatomic) NSUInteger syncCalls;
@property(nonatomic) NSUInteger failAt;
@property(nonatomic) NSUInteger removals;
@end
@implementation DurabilityDocument
- (BOOL)synchronizeSavedFileAtURL:(NSURL*)url error:(NSError**)error {
  ++self.syncCalls;
  if (self.failAt == self.syncCalls) {
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO
        userInfo:@{SakuraWriteCommittedKey:@YES}];
    return NO;
  }
  return [super synchronizeSavedFileAtURL:url error:error];
}
- (void)removeRecoveryBackup { ++self.removals; }
- (void)scheduleRecoveryBackup {}
@end
namespace {
int failures = 0;
void check(bool value, const char* label) { if (!value) { std::cerr << label << '\n'; ++failures; } }
NSData* bytes(NSString* value) { return [value dataUsingEncoding:NSUTF8StringEncoding]; }
}
int main(int argc, char** argv) {
  @autoreleasepool {
    if (argc == 4 && std::string(argv[1]) == "--crash-stage") {
      NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
      NSUInteger boundary = std::stoul(argv[3]);
      SakuraDurableReplaceDataWithGate(bytes(@"crashed-replacement"), url, nil, ^BOOL(SakuraDurableWriteStage stage) {
        if (stage == boundary) ::_exit(77);
        return YES;
      });
      return 99;
    }
    NSURL* directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    NSFileManager* fm = NSFileManager.defaultManager;
    check([fm createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil], "create isolated directory");
    NSURL* file = [directory URLByAppendingPathComponent:@"record"];
    check(SakuraDurableReplaceData(bytes(@"original"), file, nil), "durable initial write");
    check(SakuraSynchronizeSavedFile(file, nil), "sync existing file and parent");
    for (NSUInteger failed = SakuraDurableWriteFileSync; failed <= SakuraDurableWriteFinalSync; ++failed) {
      check(SakuraDurableReplaceData(bytes(@"original"), file, nil), "reset own fault fixture");
      NSError* error = nil;
      __block NSUInteger visited = 0;
      BOOL wrote = SakuraDurableReplaceDataWithGate(bytes(@"replacement"), file, &error, ^BOOL(SakuraDurableWriteStage stage) {
        ++visited; return stage != failed;
      });
      BOOL committed = failed >= SakuraDurableWriteDirectorySync;
      check(!wrote && error && visited == failed + 1, "each sync/rename failure is observable");
      check([error.userInfo[SakuraWriteCommittedKey] boolValue] == committed, "error distinguishes pre/post commit failure");
      check([[NSData dataWithContentsOfURL:file] isEqual:bytes(committed ? @"replacement" : @"original")], "failure contents match commit boundary");
      for (NSURL* entry in [fm contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil options:0 error:nil])
        check(![entry.lastPathComponent hasPrefix:@".sakura-stage-"], "ordinary failures clean only own temporary");
    }
    for (NSUInteger boundary : {static_cast<NSUInteger>(SakuraDurableWriteRename), static_cast<NSUInteger>(SakuraDurableWriteDirectorySync)}) {
      check(SakuraDurableReplaceData(bytes(@"original"), file, nil), "reset isolated interruption fixture");
      std::string boundaryText = std::to_string(boundary);
      char* arguments[] = {argv[0], const_cast<char*>("--crash-stage"), const_cast<char*>(file.fileSystemRepresentation), boundaryText.data(), nullptr};
      pid_t child = -1; int status = 0;
      check(::posix_spawn(&child, argv[0], nullptr, nullptr, arguments, environ) == 0, "spawn interruption test process");
      if (child > 0) ::waitpid(child, &status, 0);
      check(WIFEXITED(status) && WEXITSTATUS(status) == 77, "writer interrupted at actual commit boundary");
      check([[NSData dataWithContentsOfURL:file] isEqual:bytes(boundary == SakuraDurableWriteRename ? @"original" : @"crashed-replacement")], "interruption exposes complete old or complete new record");
      for (NSURL* entry in [fm contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil options:0 error:nil])
        if ([entry.lastPathComponent hasPrefix:@".sakura-stage-"]) [fm removeItemAtURL:entry error:nil];
    }
    NSDictionary* attrs = [fm attributesOfItemAtPath:file.path error:nil];
    check(([attrs[NSFilePosixPermissions] unsignedIntegerValue] & 0777) == 0600, "recovery staging stays private");
    NSURL* link = [directory URLByAppendingPathComponent:@"link"];
    check([fm createSymbolicLinkAtURL:link withDestinationURL:file error:nil], "create symlink fixture");
    NSData* retained = [NSData dataWithContentsOfURL:file];
    check(!SakuraDurableReplaceData(bytes(@"no"), link, nil) && !SakuraSynchronizeSavedFile(link, nil), "symlink destination rejected");
    check([[NSData dataWithContentsOfURL:file] isEqual:retained], "symlink target untouched");
    NSURL* directoryLink = [directory URLByAppendingPathComponent:@"directory-link"];
    [fm createSymbolicLinkAtURL:directoryLink withDestinationURL:directory error:nil];
    check(!SakuraDurableReplaceData(bytes(@"no"), [directoryLink URLByAppendingPathComponent:@"new"], nil), "symlink parent rejected");
    NSURL* fifo = [directory URLByAppendingPathComponent:@"fifo"];
    check(::mkfifo(fifo.fileSystemRepresentation, 0600) == 0, "create fifo fixture");
    check(!SakuraSynchronizeSavedFile(fifo, nil), "nonregular saved target rejected without blocking");
    check(!SakuraDurableReplaceData(bytes(@"no"), fifo, nil), "fifo target never replaced");
    check(SakuraDurableReplaceData(NSData.data, file, nil) && [NSData dataWithContentsOfURL:file].length == 0, "empty file durable replacement");
    {
      DurabilityDocument* doc = [[DurabilityDocument alloc] init]; doc.fileURL = file;
      doc.documentSession.insert(0,u"unsaved"); doc.failAt = 1;
      NSError* error = nil;
      check(![doc writeToURL:file ofType:@"public.plain-text" error:&error], "document reports sync failure");
      check(doc.isDocumentEdited && !doc.removals && [error.userInfo[SakuraWriteCommittedKey] boolValue], "sync failure preserves dirty state and recovery");
      doc.failAt = 0;
      check([doc writeToURL:file ofType:@"public.plain-text" error:&error] && !doc.isDocumentEdited && doc.removals == 1, "retry marks saved only after full sync");
      doc.documentSession.insert(0,u"export-");
      NSURL* exported = [directory URLByAppendingPathComponent:@"export.txt"];
      check([doc writeSafelyToURL:exported ofType:@"public.plain-text" forSaveOperation:NSSaveToOperation error:&error], "safe export completes");
      check(doc.isDocumentEdited && doc.removals == 1, "export never marks original document saved");
    }
    {
      DurabilityDocument* doc = [[DurabilityDocument alloc] init]; doc.fileURL = file;
      doc.documentSession.insert(0,u"safe-save"); doc.failAt = 2;
      NSError* error = nil;
      check(![doc writeSafelyToURL:file ofType:@"public.plain-text" forSaveOperation:NSSaveOperation error:&error], "final safe-save sync failure reported");
      check(doc.syncCalls >= 2 && doc.isDocumentEdited && !doc.removals, "AppKit temporary write cannot prematurely clear recovery");
      doc.failAt = 0;
      check([doc writeSafelyToURL:file ofType:@"public.plain-text" forSaveOperation:NSSaveOperation error:&error] && !doc.isDocumentEdited && doc.removals == 1, "safe-save retry completes snapshot");
    }
    {
      [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
      NSString* suite = [@"SakuraDurableSettings." stringByAppendingString:NSUUID.UUID.UUIDString];
      NSUserDefaults* defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
      [defaults setDouble:13 forKey:@"SakuraEditorFontSize"];
      DurabilityDocument* doc = [[DurabilityDocument alloc] init];
      DurableSettingsController* controller = [[DurableSettingsController alloc] initWithDocument:doc];
      controller.isolatedDefaults = defaults;
      [controller prepareCommonSettingsPanel];
      NSTextField* generations = [controller valueForKey:@"commonRecoveryGenerationsField"];
      NSTextField* budget = [controller valueForKey:@"commonRecoveryBudgetField"];
      NSTextField* status = [controller valueForKey:@"commonRecoveryStatus"];
      NSPanel* panel = [controller valueForKey:@"commonSettingsPanel"];
      check(!panel.visible && generations.integerValue == 2 && budget.integerValue == 256, "real settings panel prepared offscreen with defaults");
      NSTabView* tabs = nil;
      for (NSView* view in panel.contentView.subviews) if ([view isKindOfClass:NSTabView.class]) tabs = (NSTabView*)view;
      [tabs selectTabViewItemWithIdentifier:@"復旧"];
      check([tabs.selectedTabViewItem.identifier isEqual:@"復旧"], "recovery tab accessible in real panel");
      for (NSView* control in tabs.selectedTabViewItem.view.subviews)
        check(NSContainsRect(tabs.selectedTabViewItem.view.bounds, control.frame), "recovery controls inside actual tab bounds");
      if (argc == 3 && std::string(argv[1]) == "--render-settings") {
        [panel.contentView layoutSubtreeIfNeeded];
        NSBitmapImageRep* bitmap = [panel.contentView bitmapImageRepForCachingDisplayInRect:panel.contentView.bounds];
        [panel.contentView cacheDisplayInRect:panel.contentView.bounds toBitmapImageRep:bitmap];
        NSImage* layer = [[NSImage alloc] initWithSize:panel.contentView.bounds.size];
        [layer addRepresentation:bitmap];
        NSImage* composite = [[NSImage alloc] initWithSize:panel.contentView.bounds.size];
        [composite lockFocus];
        [NSColor.windowBackgroundColor setFill]; NSRectFill(panel.contentView.bounds);
        [layer drawInRect:panel.contentView.bounds];
        [composite unlockFocus];
        NSBitmapImageRep* flattened = [[NSBitmapImageRep alloc] initWithData:composite.TIFFRepresentation];
        NSData* png = [flattened representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        check([png writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES], "render offscreen settings artifact");
      }
      generations.stringValue = @"3garbage"; budget.stringValue = @"64";
      [controller applyCommonSettings:nil];
      check(![[controller valueForKey:@"commonSettingsApplySucceeded"] boolValue] && status.stringValue.length &&
          [defaults doubleForKey:@"SakuraEditorFontSize"] == 13 && SakuraRecoveryGenerations(defaults) == 2, "invalid recovery UI input blocks all settings writes");
      generations.stringValue = @"4"; budget.stringValue = @"64";
      [controller applyCommonSettings:nil];
      check([[controller valueForKey:@"commonSettingsApplySucceeded"] boolValue] && SakuraRecoveryGenerations(defaults) == 4 && SakuraRecoveryBudgetMiB(defaults) == 64, "recovery UI applies validated values");
      generations.stringValue = @"0"; budget.stringValue = @"15";
      [controller applyCommonSettings:nil];
      check(![[controller valueForKey:@"commonSettingsApplySucceeded"] boolValue] && SakuraRecoveryGenerations(defaults) == 4, "out of range UI value keeps earlier preferences");
      [controller.window close]; [defaults removePersistentDomainForName:suite];
    }
    [fm removeItemAtURL:directory error:nil];
  }
  return failures ? 1 : 0;
}
