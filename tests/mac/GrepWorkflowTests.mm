// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#import <AppKit/AppKit.h>
#import <objc/runtime.h>

#include <iostream>
#include <functional>
#include <cmath>

#import "SakuraDocument.h"
#import "SakuraWindowController.h"

@interface SakuraWindowController (GrepWorkflowTests)
- (void)startGrep:(id)sender;
- (void)executeGrepReplace:(id)sender;
- (void)prepareGrepPanel;
- (NSUserDefaults*)grepDefaults;
- (BOOL)grepResultIsCurrent:(NSDictionary*)result;
- (NSString*)grepResultText;
@end

static NSUserDefaults* testGrepDefaults;
@interface GrepTestController : SakuraWindowController
@end
@implementation GrepTestController
- (NSUserDefaults*)grepDefaults { return testGrepDefaults; }
@end

namespace {
int failures = 0;
void expect(bool value, const char* message) {
  if (!value) { std::cerr << message << '\n'; ++failures; }
}

bool pumpUntil(const std::function<bool()>& complete) {
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:10];
  while (!complete() && deadline.timeIntervalSinceNow > 0) {
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                         beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  }
  return complete();
}

void write(NSString* path, NSString* text) {
  expect([text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding
                    error:nil], "write fixture");
}

NSString* read(NSString* path) {
  return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding
                                      error:nil];
}

void confirmTestAlert(id, SEL, NSWindow*,
                      void (^completion)(NSModalResponse)) {
  completion(NSAlertFirstButtonReturn);
}

SakuraWindowController* makeController(NSString* directory) {
  SakuraDocument* document = [[SakuraDocument alloc] init];
  [NSDocumentController.sharedDocumentController addDocument:document];
  auto* controller = [[GrepTestController alloc] initWithDocument:document];
  [document addWindowController:controller];
  for (NSString* key in @[@"grepFolderField", @"grepPatternField",
                          @"grepReplacementField", @"grepStatusLabel",
                          @"grepExcludedFolderField"]) {
    [controller setValue:[[NSTextField alloc] init] forKey:key];
  }
  [controller setValue:[[NSSearchField alloc] init] forKey:@"grepQueryField"];
  for (NSString* key in @[@"grepCaseSensitiveButton", @"grepRegexButton",
                          @"grepRecursiveButton", @"grepBackupButton",
                          @"grepRunButton", @"grepReplaceButton", @"grepWholeWordButton"]) {
    [controller setValue:[[NSButton alloc] init] forKey:key];
  }
  NSPopUpButton* encoding = [[NSPopUpButton alloc] init];
  for (NSUInteger i = 0; i <= 6; ++i) {
    [encoding addItemWithTitle:[NSString stringWithFormat:@"%lu", (unsigned long)i]];
    encoding.lastItem.representedObject = @(i);
  }
  [controller setValue:encoding forKey:@"grepEncodingPopup"];
  [controller setValue:[[NSTableView alloc] init] forKey:@"grepTableView"];
  [controller setValue:[[NSPanel alloc] init] forKey:@"grepPanel"];
  [controller setValue:@YES forKey:@"grepReplaceMode"];
  ((NSTextField*)[controller valueForKey:@"grepFolderField"]).stringValue = directory;
  ((NSTextField*)[controller valueForKey:@"grepPatternField"]).stringValue = @"*";
  ((NSTextField*)[controller valueForKey:@"grepQueryField"]).stringValue = @"item-([0-9]+)";
  ((NSTextField*)[controller valueForKey:@"grepReplacementField"]).stringValue = @"[$1]";
  ((NSButton*)[controller valueForKey:@"grepRegexButton"]).state = NSControlStateValueOn;
  ((NSButton*)[controller valueForKey:@"grepBackupButton"]).state = NSControlStateValueOn;
  return controller;
}

void waitForSearch(SakuraWindowController* controller) {
  expect(pumpUntil([&] {
    NSString* status = ((NSTextField*)[controller valueForKey:@"grepStatusLabel"]).stringValue;
    return ![status hasPrefix:@"検索中"];
  }), "preview completed");
}

void preview(SakuraWindowController* controller);
void unicodeEncodingAndFilters(NSString* directory) {
  NSString* first = [directory stringByAppendingPathComponent:@"a.txt"];
  write(first, @"Straße STRASSE strassex");
  write([directory stringByAppendingPathComponent:@"skip.txt"], @"STRASSE");
  SakuraWindowController* controller = makeController(directory);
  [controller setValue:@NO forKey:@"grepReplaceMode"];
  ((NSButton*)[controller valueForKey:@"grepRegexButton"]).state = NSControlStateValueOff;
  ((NSButton*)[controller valueForKey:@"grepWholeWordButton"]).state = NSControlStateValueOn;
  ((NSTextField*)[controller valueForKey:@"grepQueryField"]).stringValue = @"STRASSE";
  ((NSTextField*)[controller valueForKey:@"grepPatternField"]).stringValue = @"*.txt;!skip*";
  [controller startGrep:nil]; waitForSearch(controller);
  expect([[controller valueForKey:@"grepResults"] count] == 2,
         "Grep uses Unicode folding, whole words and exclusion patterns");
  expect([[controller grepResultText] containsString:@"a.txt:1:1:"], "export includes source location");
  NSDictionary* original = [[controller valueForKey:@"grepResults"] firstObject];
  expect([controller grepResultIsCurrent:original], "unchanged result is current");
  write(first, @"changed file content");
  expect(![controller grepResultIsCurrent:original], "changed result cannot jump to stale offset");
  NSString* utf16 = [directory stringByAppendingPathComponent:@"utf16.txt"];
  NSData* data = [@"日本語STRASSE\r\n" dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
  expect([data writeToFile:utf16 atomically:YES], "write UTF16 without BOM fixture");
  ((NSTextField*)[controller valueForKey:@"grepPatternField"]).stringValue = @"utf16.txt";
  NSPopUpButton* encoding = [controller valueForKey:@"grepEncodingPopup"];
  [encoding selectItemAtIndex:2];
  ((NSButton*)[controller valueForKey:@"grepWholeWordButton"]).state = NSControlStateValueOff;
  [controller startGrep:nil]; waitForSearch(controller);
  NSArray* results = [controller valueForKey:@"grepResults"];
  expect(results.count == 1 && [results.firstObject[@"encoding"] integerValue] == 2,
         "explicit UTF16 without BOM bypasses raw-NUL binary heuristic");
  expect([testGrepDefaults integerForKey:@"SakuraGrepEncoding"] == 2, "encoding choice persists in isolated defaults");
  [encoding selectItemAtIndex:0];
  [controller startGrep:nil]; waitForSearch(controller);
  expect([[controller valueForKey:@"grepResults"] count] == 0, "automatic mode skips raw binary");
  expect([((NSTextField*)[controller valueForKey:@"grepStatusLabel"]).stringValue containsString:@"バイナリ1"],
         "skipped binary file is reported");
  write(first, @"STRASSE");
  ((NSTextField*)[controller valueForKey:@"grepPatternField"]).stringValue = @"a.txt";
  ((NSTextField*)[controller valueForKey:@"grepReplacementField"]).stringValue = @"changed";
  [controller setValue:@YES forKey:@"grepReplaceMode"];
  preview(controller);
  [encoding selectItemAtIndex:4];
  [controller executeGrepReplace:nil];
  expect([read(first) isEqual:@"STRASSE"], "encoding change invalidates frozen replacement candidates");
  NSString* large = [directory stringByAppendingPathComponent:@"large.txt"];
  expect([NSFileManager.defaultManager createFileAtPath:large contents:NSData.data attributes:nil], "create large fixture");
  NSFileHandle* handle = [NSFileHandle fileHandleForWritingAtPath:large];
  [handle truncateFileAtOffset:32ULL * 1024 * 1024 + 1]; [handle closeFile];
  [encoding selectItemAtIndex:0];
  ((NSTextField*)[controller valueForKey:@"grepPatternField"]).stringValue = @"a.txt;large.txt";
  [controller startGrep:nil]; waitForSearch(controller);
  expect(![[controller valueForKey:@"grepPreviewReady"] boolValue], "oversized file prevents incomplete replacement execution");
  expect([((NSTextField*)[controller valueForKey:@"grepStatusLabel"]).stringValue containsString:@"大容量除外1"], "oversized exclusion is visible");
}

void preview(SakuraWindowController* controller) {
  [controller startGrep:nil];
  waitForSearch(controller);
  expect([[controller valueForKey:@"grepPreviewReady"] boolValue],
         "replacement preview is ready");
}

void execute(SakuraWindowController* controller);

NSSet<NSString*>* resultPaths(SakuraWindowController* controller,
                              NSString* directory) {
  NSMutableSet<NSString*>* paths = [NSMutableSet set];
  NSString* prefix = [directory stringByAppendingString:@"/"];
  for (NSDictionary* result in [controller valueForKey:@"grepResults"]) {
    NSString* path = ((NSURL*)result[@"url"]).path;
    expect([path hasPrefix:prefix], "result remains inside selected folder");
    if ([path hasPrefix:prefix]) [paths addObject:[path substringFromIndex:prefix.length]];
  }
  return paths;
}

void writeRelative(NSString* directory, NSString* relative, NSString* text) {
  NSString* path = [directory stringByAppendingPathComponent:relative];
  expect([[NSFileManager defaultManager] createDirectoryAtPath:
      path.stringByDeletingLastPathComponent withIntermediateDirectories:YES
      attributes:nil error:nil], "create nested fixture folder");
  write(path, text);
}

void excludesDirectoriesWithOneFrozenFilter(NSString* directory,
                                            NSString* externalDirectory) {
  NSArray<NSString*>* kept = @[@"keep.txt", @"building/keep.txt",
      @"vendor/keep/keep.txt", @"other/vendor/generated-v1/keep.txt", @"plain/build",
      @"temporary12/keep.txt"];
  NSArray<NSString*>* skipped = @[@"build/deeper/skip.txt", @"nested/build/skip.txt",
      @"vendor/generated-v1/deep/skip.txt", @"space dir/skip.txt",
      @"CaseBuild/skip.txt", @"temporary1/skip.txt", @".secret/skip.txt", @"Demo.app/skip.txt"];
  for (NSString* relative in [kept arrayByAddingObjectsFromArray:skipped]) {
    writeRelative(directory, relative, @"item-42");
  }
  writeRelative(externalDirectory, @"external.txt", @"item-42");
  expect([[NSFileManager defaultManager] createSymbolicLinkAtPath:
      [directory stringByAppendingPathComponent:@"linked-directory"]
      withDestinationPath:externalDirectory error:nil], "create directory symlink");
  expect([[NSFileManager defaultManager] createSymbolicLinkAtPath:
      [directory stringByAppendingPathComponent:@"linked-file.txt"]
      withDestinationPath:[externalDirectory stringByAppendingPathComponent:@"external.txt"]
      error:nil], "create file symlink");

  auto* controller = makeController(directory);
  auto* exclusions = (NSTextField*)[controller valueForKey:@"grepExcludedFolderField"];
  exclusions.stringValue = @"build; vendor\\generated*; space dir; casebuild; temporary?";
  ((NSButton*)[controller valueForKey:@"grepRecursiveButton"]).state = NSControlStateValueOn;
  [controller setValue:@NO forKey:@"grepReplaceMode"];
  [controller startGrep:nil];
  waitForSearch(controller);
  NSSet<NSString*>* expected = [NSSet setWithArray:kept];
  expect([resultPaths(controller, directory) isEqualToSet:expected],
         "basename, rooted path, final glob, spaces and case exclusions apply to search");

  [controller setValue:@YES forKey:@"grepReplaceMode"];
  [controller startGrep:nil];
  // Do not pump the main loop first: this changes the controls while the worker
  // owns its captured filter, independent of thread scheduling or traversal order.
  exclusions.stringValue = @"building";
  waitForSearch(controller);
  expect([resultPaths(controller, directory) isEqualToSet:expected],
         "asynchronous preview keeps the filter captured at search start");
  expect([[controller valueForKey:@"grepPreviewReady"] boolValue],
         "captured replacement candidates are complete");
  expect(!((NSButton*)[controller valueForKey:@"grepReplaceButton"]).enabled,
         "changed exclusions disable executing the old preview");
  execute(controller);
  expect([read([directory stringByAppendingPathComponent:@"keep.txt"])
      isEqualToString:@"item-42"], "changed exclusions cannot execute old candidates");
  exclusions.stringValue = @"build; vendor\\generated*; space dir; casebuild; temporary?";
  execute(controller);
  for (NSString* relative in kept) {
    NSString* path = [directory stringByAppendingPathComponent:relative];
    expect([read(path) isEqualToString:@"[42]"], "only included preview files replaced");
    expect([read([path stringByAppendingString:@".bak"]) isEqualToString:@"item-42"],
           "included file has original-content backup");
  }
  for (NSString* relative in skipped) {
    expect([read([directory stringByAppendingPathComponent:relative])
        isEqualToString:@"item-42"], "excluded directory descendants untouched");
  }
  expect([read([externalDirectory stringByAppendingPathComponent:@"external.txt"])
      isEqualToString:@"item-42"], "symlink targets outside root untouched");
}

void validatesAndPersistsExclusions(NSString* directory) {
  writeRelative(directory, @"keep.txt", @"item-3");
  writeRelative(directory, @"child/build/skip.txt", @"item-3");
  auto* controller = makeController(directory);
  auto* field = (NSTextField*)[controller valueForKey:@"grepExcludedFolderField"];
  ((NSButton*)[controller valueForKey:@"grepRecursiveButton"]).state = NSControlStateValueOn;
  field.stringValue = @"build/";
  preview(controller);
  expect([[testGrepDefaults stringForKey:@"SakuraGrepExcludedFolders"]
      isEqualToString:@"build/"], "accepted folder exclusions persisted in injected defaults");
  for (NSString* invalid in @[@"../build", @"/tmp/build", @"*/build",
                             @"vendor//build", @"vendor/./build", @"vendor/../build",
                             @"C:\\temp", @"\"build\"", @"~/build"]) {
    field.stringValue = invalid;
    [controller startGrep:nil];
    expect(![[controller valueForKey:@"grepPreviewReady"] boolValue] &&
           [controller valueForKey:@"grepProgress"] == nil,
           "invalid exclusion rejects execution before creating a worker");
    expect(!((NSButton*)[controller valueForKey:@"grepReplaceButton"]).enabled,
           "invalid exclusion invalidates previous replacement candidates");
    expect([((NSTextField*)[controller valueForKey:@"grepStatusLabel"]).stringValue
        containsString:@"除外フォルダー"], "invalid exclusion explains supported syntax");
    execute(controller);
    expect([read([directory stringByAppendingPathComponent:@"keep.txt"])
        isEqualToString:@"item-3"], "invalid exclusion does not write files");
  }
  expect([[testGrepDefaults stringForKey:@"SakuraGrepExcludedFolders"]
      isEqualToString:@"build/"], "invalid exclusions do not replace saved valid settings");

  // Construct the actual panel offscreen to verify the saved input is restored.
  SakuraDocument* document = [[SakuraDocument alloc] init];
  auto* restored = [[GrepTestController alloc] initWithDocument:document];
  [document addWindowController:restored];
  [restored prepareGrepPanel];
  expect([((NSTextField*)[restored valueForKey:@"grepExcludedFolderField"]).stringValue
      isEqualToString:@"build/"], "new panel restores saved exclusion text");
  NSPanel* panel = [restored valueForKey:@"grepPanel"];
  NSTextField* restoredField = [restored valueForKey:@"grepExcludedFolderField"];
  const CGFloat oldTopGap = NSHeight(panel.contentView.bounds) - NSMaxY(restoredField.frame);
  [panel setContentSize:NSMakeSize(840, 700)];
  expect(std::abs(NSHeight(panel.contentView.bounds) - NSMaxY(restoredField.frame) -
                  oldTopGap) < 0.5, "resizing panel keeps exclusion controls above results");
  [restored close];

  field.stringValue = @"";
  preview(controller);
  expect([[controller valueForKey:@"grepResults"] count] == 2,
         "blank exclusions preserve recursive search behavior");
  expect([[testGrepDefaults stringForKey:@"SakuraGrepExcludedFolders"] length] == 0,
         "blank exclusions can clear saved exclusions");
  ((NSButton*)[controller valueForKey:@"grepRecursiveButton"]).state = NSControlStateValueOff;
  preview(controller);
  expect([[controller valueForKey:@"grepResults"] count] == 1,
         "nonrecursive search remains limited to selected folder");
  ((NSButton*)[controller valueForKey:@"grepRecursiveButton"]).state = NSControlStateValueOn;
  field.stringValue = @"unused,build/\n";
  preview(controller);
  expect([[controller valueForKey:@"grepResults"] count] == 1,
         "comma and newline separators retain folder exclusion rules");
  // Excluding a root's own basename never excludes the root or its ancestors.
  field.stringValue = directory.lastPathComponent;
  preview(controller);
  expect([[controller valueForKey:@"grepResults"] count] == 2,
         "basename patterns inspect descendants rather than selected root ancestors");
}

void execute(SakuraWindowController* controller) {
  Method method = class_getInstanceMethod(NSAlert.class,
      @selector(beginSheetModalForWindow:completionHandler:));
  IMP original = method_setImplementation(method, (IMP)confirmTestAlert);
  [controller executeGrepReplace:nil];
  method_setImplementation(method, original);
  expect(pumpUntil([&] {
    return ![[controller valueForKey:@"grepReplacing"] boolValue];
  }), "replacement completed");
}

void freezesPreviewAndPreservesChangedFiles(NSString* directory) {
  NSString* first = [directory stringByAppendingPathComponent:@"first.txt"];
  NSString* changed = [directory stringByAppendingPathComponent:@"changed.txt"];
  NSString* late = [directory stringByAppendingPathComponent:@"late.txt"];
  NSString* backup = [directory stringByAppendingPathComponent:@"old.txt.bak.1"];
  write(first, @"item-12 item-34");
  write(changed, @"item-5");
  write(backup, @"item-99");
  auto* controller = makeController(directory);
  preview(controller);
  expect([[controller valueForKey:@"grepResults"] count] == 3,
         "numbered backup excluded from preview");
  write(changed, @"item-6 external edit");
  write(late, @"item-7");
  execute(controller);
  expect([read(first) isEqualToString:@"[12] [34]"], "confirmed matches replaced");
  expect([read([first stringByAppendingString:@".bak"]) isEqualToString:@"item-12 item-34"],
         "backup contains preview original");
  expect([read(changed) isEqualToString:@"item-6 external edit"],
         "external edit preserved");
  expect([read(late) isEqualToString:@"item-7"], "file created after preview untouched");
  expect([read(backup) isEqualToString:@"item-99"], "numbered backup untouched");
  expect(![[controller valueForKey:@"grepPreviewReady"] boolValue],
         "preview cannot be reused after execution");
}

void skipsDocumentOpenedAfterPreview(NSString* directory) {
  NSString* path = [directory stringByAppendingPathComponent:@"opened.txt"];
  write(path, @"item-8");
  auto* controller = makeController(directory);
  preview(controller);
  SakuraDocument* opened = [[SakuraDocument alloc] init];
  opened.fileURL = [NSURL fileURLWithPath:path];
  [NSDocumentController.sharedDocumentController addDocument:opened];
  execute(controller);
  expect([read(path) isEqualToString:@"item-8"], "newly opened document untouched");
  [NSDocumentController.sharedDocumentController removeDocument:opened];
}

void refusesIncompleteAndFailedPreviews(NSString* directory) {
  NSString* path = [directory stringByAppendingPathComponent:@"many.txt"];
  NSString* text = [@"" stringByPaddingToLength:21000 withString:@"a"
                              startingAtIndex:0];
  write(path, text);
  auto* controller = makeController(directory);
  ((NSTextField*)[controller valueForKey:@"grepQueryField"]).stringValue = @"a";
  [controller startGrep:nil];
  expect(pumpUntil([&] {
    return [((NSTextField*)[controller valueForKey:@"grepStatusLabel"]).stringValue
        containsString:@"20,000"];
  }), "preview hit limit reported");
  expect(![[controller valueForKey:@"grepPreviewReady"] boolValue],
         "truncated preview cannot be executed");
  expect(!((NSButton*)[controller valueForKey:@"grepReplaceButton"]).enabled,
         "truncated preview disables replace button");
  expect([read(path) isEqualToString:text], "preview leaves source unchanged");

  // A pathological expression must fail without escaping the async worker.
  write(path, [text stringByAppendingString:@"b"]);
  ((NSTextField*)[controller valueForKey:@"grepQueryField"]).stringValue = @"(a+)+$";
  [controller startGrep:nil];
  expect(pumpUntil([&] {
    return [((NSTextField*)[controller valueForKey:@"grepStatusLabel"]).stringValue
        containsString:@"エラー1"];
  }), "regex timeout reported as preview error");
  expect(![[controller valueForKey:@"grepPreviewReady"] boolValue],
         "failed preview cannot be executed");
  expect([read(path) isEqualToString:[text stringByAppendingString:@"b"]],
         "failed preview leaves source unchanged");
}

void ambiguousJapaneseRequiresExplicitEncodingForBulkWrite(NSString* directory) {
  NSString* path = [directory stringByAppendingPathComponent:@"euc.txt"];
  NSString* plain = [directory stringByAppendingPathComponent:@"plain.txt"];
  const unsigned char original[] = {0xa4, 0xa2, ' ', 'i', 't', 'e', 'm', '-', '4', '2', '\r', '\n'};
  NSData* data = [NSData dataWithBytes:original length:sizeof(original)];
  expect([data writeToFile:path atomically:YES], "write independent ambiguous EUC fixture");
  write(plain, @"item-42");
  auto* controller = makeController(directory);
  [controller startGrep:nil]; waitForSearch(controller);
  NSArray* results = [controller valueForKey:@"grepResults"];
  expect(results.count == 2, "ambiguous input remains searchable");
  NSDictionary* inferred = nil;
  for (NSDictionary* result in results) if ([((NSURL*)result[@"url"]).path isEqual:path]) inferred = result;
  expect(inferred && [inferred[@"encoding"] integerValue] == 5 &&
         [inferred[@"requestedEncoding"] integerValue] == 0 && [inferred[@"ambiguousEncoding"] boolValue] &&
         [inferred[@"title"] containsString:@"文字コード要確認"],
         "Grep result preserves inferred encoding, original auto request and warning");
  expect(![[controller valueForKey:@"grepPreviewReady"] boolValue] &&
         !((NSButton*)[controller valueForKey:@"grepReplaceButton"]).enabled,
         "an ambiguous matching file disables the entire bulk write");
  expect([((NSTextField*)[controller valueForKey:@"grepStatusLabel"]).stringValue containsString:@"文字コードを指定"],
         "ambiguous preview explains how to proceed");
  [controller executeGrepReplace:nil];
  expect([[NSData dataWithContentsOfFile:path] isEqual:data] && [read(plain) isEqual:@"item-42"],
         "no partial write of otherwise unambiguous candidates");
  NSPopUpButton* encoding = [controller valueForKey:@"grepEncodingPopup"];
  [encoding selectItemAtIndex:5];
  preview(controller);
  for (NSDictionary* result in [controller valueForKey:@"grepResults"])
    expect(![result[@"ambiguousEncoding"] boolValue] && [result[@"requestedEncoding"] integerValue] == 5,
           "explicit EUC preview records user's encoding choice");
  execute(controller);
  const unsigned char replaced[] = {0xa4, 0xa2, ' ', '[', '4', '2', ']', '\r', '\n'};
  expect([[NSData dataWithContentsOfFile:path] isEqual:[NSData dataWithBytes:replaced length:sizeof(replaced)]],
         "explicit EUC replacement preserves original legacy characters and CRLF");
  expect([[NSData dataWithContentsOfFile:[path stringByAppendingString:@".bak"]] isEqual:data],
         "explicit replacement backs up exact ambiguous source bytes");
}
}  // namespace

int main() {
  @autoreleasepool {
    [NSApplication sharedApplication];
    NSString* defaultsSuite = [@"SakuraGrepWorkflowTests."
        stringByAppendingString:NSUUID.UUID.UUIDString];
    testGrepDefaults = [[NSUserDefaults alloc] initWithSuiteName:defaultsSuite];
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
      @"SakuraEditorFontSize": @13, @"SakuraEditorTabWidth": @4}];
    NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"sakura-grep-workflow-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    for (NSString* part in @[@"frozen", @"opened", @"limits", @"directories",
                             @"outside", @"validation", @"features", @"encoding"]) {
      [[NSFileManager defaultManager] createDirectoryAtPath:
          [root stringByAppendingPathComponent:part]
          withIntermediateDirectories:YES attributes:nil error:nil];
    }
    freezesPreviewAndPreservesChangedFiles([root stringByAppendingPathComponent:@"frozen"]);
    skipsDocumentOpenedAfterPreview([root stringByAppendingPathComponent:@"opened"]);
    refusesIncompleteAndFailedPreviews([root stringByAppendingPathComponent:@"limits"]);
    excludesDirectoriesWithOneFrozenFilter(
        [root stringByAppendingPathComponent:@"directories"],
        [root stringByAppendingPathComponent:@"outside"]);
    validatesAndPersistsExclusions([root stringByAppendingPathComponent:@"validation"]);
    unicodeEncodingAndFilters([root stringByAppendingPathComponent:@"features"]);
    ambiguousJapaneseRequiresExplicitEncodingForBulkWrite([root stringByAppendingPathComponent:@"encoding"]);
    for (NSDocument* document in [NSDocumentController.sharedDocumentController.documents copy]) {
      [document close];
      [NSDocumentController.sharedDocumentController removeDocument:document];
    }
    [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
    [testGrepDefaults removePersistentDomainForName:defaultsSuite];
    testGrepDefaults = nil;
    if (failures) return 1;
    std::cout << "Grep workflow integration tests passed\n";
  }
  return 0;
}
