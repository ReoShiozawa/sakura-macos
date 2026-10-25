// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#import "SakuraDocument.h"
#import "SakuraRecoveryStore.h"
#import "SakuraRecoveryWriter.h"
#import "SakuraDurableFile.h"

#include <cstddef>
#include <algorithm>
#include <array>
#include <exception>
#include <limits>
#include <span>
#include <string>

#import "SakuraWindowController.h"
#import "SakuraEditorView.h"
#import "SakuraColorTheme.h"
#include "sakura/platform/mac/MacEncodingService.h"
#include "sakura/platform/mac/StringBridge.h"
#include "sakura/core/encoding/Utf8Codec.h"

namespace {

constexpr NSString* kCodecErrorDomain = @"org.sakura-editor.SakuraEditor.UTF8";

void assignError(NSError** output, NSInteger code, NSString* description,
                 NSString* reason) {
  if (output == nullptr) {
    return;
  }
  NSMutableDictionary* info = [NSMutableDictionary dictionary];
  info[NSLocalizedDescriptionKey] = description;
  if (reason.length != 0) {
    info[NSLocalizedFailureReasonErrorKey] = reason;
  }
  *output = [NSError errorWithDomain:kCodecErrorDomain code:code userInfo:info];
}

NSString* stringFromException(const std::exception& exception) {
  NSString* reason = [NSString stringWithUTF8String:exception.what()];
  return reason != nil ? reason : @"Unknown C++ exception";
}

NSError* recoveryPreparationError(const std::exception& exception) {
  return [NSError errorWithDomain:@"SakuraRecovery" code:2 userInfo:@{
    NSLocalizedDescriptionKey:@"復旧処理を準備できませんでした。以前のバックアップを保持します。",
    NSLocalizedFailureReasonErrorKey:stringFromException(exception)}];
}

NSURL* recoveryDirectoryURL() {
  NSURL* applicationSupport = [[NSFileManager defaultManager]
      URLsForDirectory:NSApplicationSupportDirectory
             inDomains:NSUserDomainMask].firstObject;
  return [[applicationSupport URLByAppendingPathComponent:@"SakuraEditor"
                                               isDirectory:YES]
      URLByAppendingPathComponent:@"Recovery" isDirectory:YES];
}

NSDictionary* recoveryPropertyListAtURL(NSURL* url) {
  return SakuraReadRecovery(url);
}

struct BookmarkSynchronizationStatistics {
  sakura::core::TextOffset comparedUnits{}, copiedUnits{};
  std::size_t comparedTextNodes{}, peakWindowUnits{}, mappedAnchors{};
};
struct BookmarkDifference {
  sakura::core::TextOffset prefix{}, suffix{};
  bool unchangedNonEndAnchors{};
};

// A snapshot's final unique tree can be large after a reload. Pass ownership
// directly to libdispatch, with no allocating C++ block capture or document
// reference. Disposing bookmark storage must not become a new main-thread walk.
void retireBookmarkSnapshot(std::unique_ptr<sakura::core::TextBuffer> source) noexcept {
  if (!source) return;
  dispatch_async_f(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), source.release(),
      [](void* context) { delete static_cast<sakura::core::TextBuffer*>(context); });
}

void addBookmarkUnits(sakura::core::TextOffset& total, sakura::core::TextOffset count) {
  total += std::min(count, std::numeric_limits<sakura::core::TextOffset>::max()-total);
}

BookmarkDifference bookmarkDifference(const sakura::core::TextBuffer& old,
    const sakura::core::TextBuffer& current, std::optional<sakura::core::TextOffset> lastNonEndAnchor,
    BookmarkSynchronizationStatistics& statistics) {
  using sakura::core::TextOffset;
  if (!lastNonEndAnchor || old.sharesStorageWith(current)) return {0,0,true};
  const auto change=current.changesFrom(old);
  statistics.comparedTextNodes=change.comparedNodes;
  TextOffset prefix=change.oldText.location;
  if (*lastNonEndAnchor<prefix) return {prefix,0,true};
  const auto oldLength=old.length(), newLength=current.length();
  const auto oldChangedEnd=change.oldText.location+change.oldText.length;
  auto prefixLimit=std::min(oldLength,newLength);
  prefixLimit=std::min(prefixLimit,*lastNonEndAnchor+1);
  if (oldLength==newLength) prefixLimit=std::min(prefixLimit,oldChangedEnd);
  constexpr std::size_t window=4096;
  std::array<sakura::core::SakuraChar,window> before{},after{};
  const auto copyWindows=[&](TextOffset oldStart,TextOffset newStart,std::size_t count) {
    old.copyText({oldStart,count},{before.data(),count});
    current.copyText({newStart,count},{after.data(),count});
    addBookmarkUnits(statistics.copiedUnits,static_cast<TextOffset>(count)*2);
    statistics.peakWindowUnits=std::max(statistics.peakWindowUnits,count);
  };
  // Shared line subtrees give a guaranteed prefix, not necessarily the maximal
  // character prefix. Repeated inserted lines can extend it into the shared
  // suffix, so only stop on an actual mismatch, EOF or beyond every anchor.
  while (prefix<prefixLimit) {
    const auto count=static_cast<std::size_t>(std::min<TextOffset>(window,prefixLimit-prefix));
    copyWindows(prefix,prefix,count);
    std::size_t equal=0;
    while (equal<count && before[equal]==after[equal]) ++equal;
    addBookmarkUnits(statistics.comparedUnits,equal+(equal<count));
    prefix+=equal;
    if (equal<count) break;
  }
  if (prefix>*lastNonEndAnchor || (oldLength==newLength && prefix==oldChangedEnd))
    return {prefix,0,true};
  const auto remaining=std::min(oldLength-prefix,newLength-prefix);
  TextOffset suffix=std::min(oldLength-oldChangedEnd,remaining);
  while (suffix<remaining) {
    const auto count=static_cast<std::size_t>(std::min<TextOffset>(window,remaining-suffix));
    copyWindows(oldLength-suffix-count,newLength-suffix-count,count);
    std::size_t equal=0;
    while (equal<count && before[count-1-equal]==after[count-1-equal]) ++equal;
    addBookmarkUnits(statistics.comparedUnits,equal+(equal<count));
    suffix+=equal;
    if (equal<count) break;
  }
  return {prefix,suffix,false};
}

}  // namespace

@interface SakuraDocument ()
@property(nonatomic, strong, nullable) NSTimer* externalChangeTimer;
@property(nonatomic, strong, nullable) NSTimer* recoveryTimer;
@property(nonatomic, strong, nullable) NSDate* knownModificationDate;
@property(nonatomic, strong, nullable) NSNumber* knownFileSize;
@property(nonatomic, copy) NSString* recoveryIdentifier;
@property(nonatomic) BOOL writingDocument;
@property(nonatomic) BOOL safelyWritingDocument;
@property(nonatomic) BOOL handlingExternalChange;
@property(nonatomic) BOOL closingDocument;
@property(nonatomic) BOOL recoveryFailureReported;
@property(nonatomic, strong) SakuraRecoveryWriter* recoveryWriter;
@property(nonatomic, strong) NSMutableIndexSet* bookmarkAnchors;
@property(nonatomic) BOOL savingToClose;
@end

@implementation SakuraDocument {
  std::unique_ptr<sakura::core::TextBuffer> _bookmarkSnapshot;
  BookmarkSynchronizationStatistics _bookmarkStatistics;
}

- (void)dealloc {
  retireBookmarkSnapshot(std::move(_bookmarkSnapshot));
}

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _session = std::make_unique<sakura::app::DocumentSession>(
        sakura::platform::mac::macEncodingService());
    _preferredLineEnding = sakura::core::LineEnding::lineFeed;
    _recoveryIdentifier = NSUUID.UUID.UUIDString;
  }
  return self;
}

+ (BOOL)autosavesInPlace {
  return NO;
}

- (sakura::app::DocumentSession&)documentSession {
  return *_session;
}

- (void)setFileURL:(NSURL*)url {
  NSString* previousType = SakuraTypeIdentifierForExtension(
      self.fileURL.pathExtension);
  [super setFileURL:url];
  // NSDocument may assign its URL during initialization or teardown, before
  // there is a usable session or after its editor windows have been closed.
  if (_session == nullptr || self.closingDocument ||
      self.windowControllers.count == 0) return;
  NSString* currentType = SakuraTypeIdentifierForExtension(
      self.fileURL.pathExtension);
  if (![previousType isEqualToString:currentType]) {
    [self refreshEditorViews];
  }
}

- (void)makeWindowControllers {
  SakuraWindowController* controller =
      [[SakuraWindowController alloc] initWithDocument:self];
  [self addWindowController:controller];
  [self startDocumentServices];
}

- (void)updatePreferredLineEndingFromBuffer {
  const auto& buffer = _session->buffer();
  for (std::size_t index = 0; index < buffer.lineCount(); ++index) {
    const auto ending = buffer.line(index).ending;
    if (ending != sakura::core::LineEnding::none) {
      _preferredLineEnding = ending;
      return;
    }
  }
}

- (BOOL)readFromData:(NSData*)data
              ofType:(NSString*)typeName
               error:(NSError**)outError {
  (void)typeName;
  try {
    const auto* bytes = static_cast<const std::byte*>(data.bytes);
    const auto result = _session->load(std::span<const std::byte>(bytes, data.length));
    if (!result.ok()) {
      const auto& codecError = *result.error;
      NSString* reason = [NSString
          stringWithFormat:@"Byte %llu: %s",
                           static_cast<unsigned long long>(codecError.offset),
                           codecError.message.c_str()];
      assignError(outError, 1, @"The file could not be decoded.", reason);
      return NO;
    }
    if (self.recoveryWriter) [self removeRecoveryBackup];
    [self updatePreferredLineEndingFromBuffer];
    [self refreshEditorViews];
    return YES;
  } catch (const std::exception& exception) {
    assignError(outError, 2, @"The document could not be read.",
                stringFromException(exception));
    return NO;
  }
}

- (NSData*)dataOfType:(NSString*)typeName error:(NSError**)outError {
  (void)typeName;
  try {
    [self commitPendingInput];
    const auto snapshot = _session->makeSaveSnapshot();
    if (!snapshot.encoded.ok()) {
      _pendingSaveToken.reset();
      const auto& codecError = *snapshot.encoded.error;
      NSString* reason = [NSString
          stringWithFormat:@"UTF-16 offset %llu: %s",
                           static_cast<unsigned long long>(codecError.offset),
                           codecError.message.c_str()];
      assignError(outError, 3, @"The document could not be encoded.",
                  reason);
      return nil;
    }
    _pendingSaveToken = snapshot.token;
    if (snapshot.encoded.bytes.empty()) {
      return [NSData data];
    }
    return [NSData dataWithBytes:snapshot.encoded.bytes.data()
                          length:snapshot.encoded.bytes.size()];
  } catch (const std::exception& exception) {
    _pendingSaveToken.reset();
    assignError(outError, 4, @"The document could not be saved.",
                stringFromException(exception));
    return nil;
  }
}

- (BOOL)writeToURL:(NSURL*)url
             ofType:(NSString*)typeName
              error:(NSError**)outError {
  self.writingDocument = YES;
  BOOL wrote = [super writeToURL:url ofType:typeName error:outError];
  if (wrote) wrote = [self synchronizeSavedFileAtURL:url error:outError];
  self.writingDocument = self.safelyWritingDocument;
  if (self.safelyWritingDocument) return wrote;
  [self finishSaveSnapshot:wrote];
  return wrote;
}

- (BOOL)synchronizeSavedFileAtURL:(NSURL*)url error:(NSError**)error {
  return SakuraSynchronizeSavedFile(url, error);
}

- (void)finishSaveSnapshot:(BOOL)wrote {
  if (wrote && _pendingSaveToken.has_value()) {
    _session->markSaved(*_pendingSaveToken);
    [self updateKnownFileState];
    if (self.isDocumentEdited) [self scheduleRecoveryBackup];
    else [self removeRecoveryBackup];
  }
  _pendingSaveToken.reset();
}

- (BOOL)writeSafelyToURL:(NSURL*)url ofType:(NSString*)typeName
      forSaveOperation:(NSSaveOperationType)operation error:(NSError**)error {
  self.safelyWritingDocument = YES;
  self.writingDocument = YES;
  BOOL wrote = [super writeSafelyToURL:url ofType:typeName forSaveOperation:operation error:error];
  // AppKit may have written to a temporary sibling before its final rename.
  // Do not clear dirty state or recovery until the final destination is synced.
  if (wrote) wrote = [self synchronizeSavedFileAtURL:url error:error];
  self.safelyWritingDocument = NO;
  self.writingDocument = NO;
  [self finishSaveSnapshot:wrote && operation != NSSaveToOperation];
  return wrote;
}

- (BOOL)isDocumentEdited {
  return _session != nullptr ? _session->isDirty() : [super isDocumentEdited];
}

- (void)saveAndClose:(id)sender {
  (void)sender;
  if (self.savingToClose) return;
  [self commitPendingInput];
  self.savingToClose = YES;
  [self saveDocumentWithDelegate:self
                didSaveSelector:@selector(document:didSaveToClose:contextInfo:)
                    contextInfo:nullptr];
}

- (void)commitPendingInput {
  // AppKit document saves in this implementation run on the main thread.
  if (!NSThread.isMainThread) return;
  for (NSWindowController* controller in self.windowControllers) {
    if (![controller isKindOfClass:SakuraWindowController.class]) continue;
    for (SakuraEditorView* editor in [(SakuraWindowController*)controller editorViews])
      if (editor.hasMarkedText) [editor unmarkText];
  }
}

- (void)document:(NSDocument*)document didSaveToClose:(BOOL)didSave contextInfo:(void*)context {
  (void)document; (void)context;
  self.savingToClose = NO;
  if (didSave && !self.isDocumentEdited) [self close];
}

- (void)noteEditorChange:(NSDocumentChangeType)changeType {
  [self updateChangeCount:changeType];
  [self scheduleRecoveryBackup];
}

- (void)setOutputEncoding:(sakura::core::TextEncoding)encoding
                  writeBom:(BOOL)writeBom {
  _session->setEncodingState({encoding, writeBom == YES});
  [self updateChangeCount:NSChangeDone];
  [self scheduleRecoveryBackup];
  [self refreshEditorViews];
}

- (BOOL)reloadUsingEncoding:(sakura::core::TextEncoding)encoding
                       error:(NSError**)error {
  if (self.fileURL == nil) {
    assignError(error, 20, @"The document has no file to reload.", @"");
    return NO;
  }
  NSData* data = [NSData dataWithContentsOfURL:self.fileURL
                                      options:NSDataReadingMappedIfSafe
                                        error:error];
  if (data == nil) return NO;
  const auto* bytes = static_cast<const std::byte*>(data.bytes);
  const auto result = _session->load(
      std::span<const std::byte>(bytes, data.length), encoding);
  if (!result.ok()) {
    const auto& codecError = *result.error;
    assignError(error, 21, @"The file could not be decoded.",
                [NSString stringWithFormat:@"Byte %llu: %s",
                    static_cast<unsigned long long>(codecError.offset),
                    codecError.message.c_str()]);
    return NO;
  }
  [self updatePreferredLineEndingFromBuffer];
  [self updateChangeCount:NSChangeCleared];
  [self updateKnownFileState];
  [self removeRecoveryBackup];
  [self refreshEditorViews];
  return YES;
}

- (NSString*)preferredLineEndingString {
  switch (_preferredLineEnding) {
    case sakura::core::LineEnding::carriageReturnLineFeed: return @"CRLF";
    case sakura::core::LineEnding::carriageReturn: return @"CR";
    case sakura::core::LineEnding::lineFeed: return @"LF";
    case sakura::core::LineEnding::none: return @"LF";
  }
}

- (void)setPreferredLineEndingString:(NSString*)lineEnding {
  if ([lineEnding isEqualToString:@"CRLF"]) {
    _preferredLineEnding = sakura::core::LineEnding::carriageReturnLineFeed;
  } else if ([lineEnding isEqualToString:@"CR"]) {
    _preferredLineEnding = sakura::core::LineEnding::carriageReturn;
  } else {
    _preferredLineEnding = sakura::core::LineEnding::lineFeed;
  }
}

- (NSString*)newlineInsertionString {
  switch (_preferredLineEnding) {
    case sakura::core::LineEnding::carriageReturnLineFeed: return @"\r\n";
    case sakura::core::LineEnding::carriageReturn: return @"\r";
    case sakura::core::LineEnding::lineFeed:
    case sakura::core::LineEnding::none: return @"\n";
  }
}

- (void)startDocumentServices {
  if (self.externalChangeTimer == nil) {
    __weak SakuraDocument* weakSelf = self;
    self.externalChangeTimer = [NSTimer timerWithTimeInterval:2.0
                                                     repeats:YES
                                                       block:^(NSTimer* timer) {
      (void)timer;
      [weakSelf checkForExternalChanges];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.externalChangeTimer
                              forMode:NSRunLoopCommonModes];
  }
  [self updateKnownFileState];
}

- (void)scheduleRecoveryBackup {
  [self.recoveryTimer invalidate];
  if (self.closingDocument) return;
  __weak SakuraDocument* weakSelf = self;
  self.recoveryTimer = [NSTimer timerWithTimeInterval:2.0
                                             repeats:NO
                                               block:^(NSTimer* timer) {
    (void)timer;
    SakuraDocument* document = weakSelf;
    document.recoveryTimer = nil;
    [document writeRecoveryBackupIfNeeded];
  }];
  [[NSRunLoop mainRunLoop] addTimer:self.recoveryTimer
                            forMode:NSRunLoopCommonModes];
}

- (void)updateKnownFileState {
  if (self.fileURL == nil) return;
  NSDictionary* attributes = [[NSFileManager defaultManager]
      attributesOfItemAtPath:self.fileURL.path error:nil];
  self.knownModificationDate = attributes[NSFileModificationDate];
  self.knownFileSize = attributes[NSFileSize];
}

- (void)reloadAfterExternalChange {
  NSError* error = nil;
  const auto sourceEncoding = _session->encodingState().encoding;
  if (![self reloadUsingEncoding:sourceEncoding error:&error] && error != nil) {
    [NSApp presentError:error];
  }
}

- (void)checkForExternalChanges {
  if (self.fileURL == nil || self.writingDocument ||
      self.handlingExternalChange) return;
  NSDictionary* attributes = [[NSFileManager defaultManager]
      attributesOfItemAtPath:self.fileURL.path error:nil];
  if (attributes == nil) {
    if (self.knownModificationDate == nil) return;
    self.knownModificationDate = nil;
    self.knownFileSize = nil;
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"ファイルが外部で削除または移動されました";
    alert.informativeText = self.fileURL.path;
    [alert addButtonWithTitle:@"名前を付けて保存…"];
    [alert addButtonWithTitle:@"現在の内容を保持"];
    NSWindow* window = self.windowControllers.firstObject.window;
    if (window != nil) {
      [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) [self saveDocumentAs:nil];
      }];
    }
    return;
  }
  NSDate* modificationDate = attributes[NSFileModificationDate];
  NSNumber* fileSize = attributes[NSFileSize];
  if (self.knownModificationDate == nil) {
    self.knownModificationDate = modificationDate;
    self.knownFileSize = fileSize;
    return;
  }
  if ([modificationDate isEqualToDate:self.knownModificationDate] &&
      [fileSize isEqualToNumber:self.knownFileSize]) return;
  self.knownModificationDate = modificationDate;
  self.knownFileSize = fileSize;
  if (!self.isDocumentEdited) {
    [self reloadAfterExternalChange];
    return;
  }
  self.handlingExternalChange = YES;
  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = @"ファイルが外部で変更されました";
  alert.informativeText = @"編集中の内容とディスク上の内容が異なります。";
  [alert addButtonWithTitle:@"ディスクから再読込"];
  [alert addButtonWithTitle:@"名前を付けて保存…"];
  [alert addButtonWithTitle:@"現在の内容を保持"];
  NSWindow* window = self.windowControllers.firstObject.window;
  if (window != nil) {
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
      self.handlingExternalChange = NO;
      if (response == NSAlertFirstButtonReturn) {
        [self reloadAfterExternalChange];
      } else if (response == NSAlertSecondButtonReturn) {
        [self saveDocumentAs:nil];
      }
    }];
  } else {
    self.handlingExternalChange = NO;
  }
}

- (NSURL*)recoveryBackupURL {
  return [[recoveryDirectoryURL()
      URLByAppendingPathComponent:self.recoveryIdentifier]
      URLByAppendingPathExtension:@"sakura-recovery"];
}

- (void)writeRecoveryBackupIfNeeded {
  if (self.closingDocument) return;
  try {
    if (!self.isDocumentEdited) {
      [self removeRecoveryBackup];
      return;
    }
    const auto encoding = _session->encodingState();
    NSString* displayName = self.displayName;
    if (displayName == nil) displayName = @"名称未設定";
    NSString* originalPath = self.fileURL.path;
    if (originalPath == nil) originalPath = @"";
    NSDictionary* propertyList = @{
      @"version" : @1,
      @"displayName" : displayName,
      @"originalPath" : originalPath,
      @"encoding" : @(static_cast<NSInteger>(encoding.encoding)),
      @"bom" : @(encoding.hadBom),
      @"sourceEncodingAmbiguous" : @(_session->sourceEncodingDetection().ambiguous),
      @"lineEnding" : [self preferredLineEndingString],
      @"date" : [NSDate date],
    };
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    if (!self.recoveryWriter) self.recoveryWriter = [[SakuraRecoveryWriter alloc] init];
    __weak SakuraDocument* weakSelf = self;
    [self.recoveryWriter writeSnapshot:_session->buffer() metadata:propertyList
        toURL:[self recoveryBackupURL]
        budget:SakuraRecoveryBudgetMiB(defaults) * 1024ULL * 1024
        generations:SakuraRecoveryGenerations(defaults) completion:^(NSError* error) {
      SakuraDocument* document = weakSelf;
      if (!document || document.closingDocument) return;
      [document reportRecoveryError:error removing:NO];
    }];
  } catch (const std::exception& exception) {
    [self reportRecoveryError:recoveryPreparationError(exception) removing:NO];
  }
}

- (void)reportRecoveryError:(NSError*)error removing:(BOOL)removing {
  if (!error) {
    self.recoveryFailureReported = NO;
    return;
  }
  if (!self.recoveryFailureReported) {
    self.recoveryFailureReported = YES;
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = removing ? @"古い復旧バックアップを削除できませんでした"
                                : @"復旧バックアップを保存できませんでした";
    alert.informativeText = [NSString stringWithFormat:
        @"%@\n%@", error.localizedDescription, removing
          ? @"保存した文書は変更しません。次回起動時に古い復旧候補が表示される可能性があります。"
          : @"文書を別の場所へ明示的に保存してください。"];
    NSWindow* window = self.windowControllers.firstObject.window;
    if (window) [alert beginSheetModalForWindow:window completionHandler:nil];
    else NSLog(@"%@", alert.messageText);
  }
}

- (void)removeRecoveryBackup {
  try {
    if (!self.recoveryWriter) self.recoveryWriter = [[SakuraRecoveryWriter alloc] init];
    __weak SakuraDocument* weakSelf = self;
    [self.recoveryWriter removeAtURL:[self recoveryBackupURL] completion:^(NSError* error) {
      SakuraDocument* document = weakSelf;
      if (document && !document.closingDocument) [document reportRecoveryError:error removing:YES];
      else if (error) NSLog(@"復旧バックアップの終了時削除に失敗しました: %@", error.localizedDescription);
    }];
  } catch (const std::exception& exception) {
    NSError* error = recoveryPreparationError(exception);
    if (!self.closingDocument) [self reportRecoveryError:error removing:YES];
    else NSLog(@"復旧バックアップの終了時削除を準備できませんでした: %@", error);
  }
}

- (void)close {
  self.closingDocument = YES;
  [self.externalChangeTimer invalidate];
  [self.recoveryTimer invalidate];
  self.externalChangeTimer = nil;
  self.recoveryTimer = nil;
  [self removeRecoveryBackup];
  [super close];
}

+ (void)offerRecoveryIfNeeded {
  NSArray<NSURL*>* files = [[NSFileManager defaultManager]
      contentsOfDirectoryAtURL:recoveryDirectoryURL()
    includingPropertiesForKeys:nil options:0 error:nil];
  NSPredicate* recoveryFiles = [NSPredicate predicateWithBlock:
      ^BOOL(NSURL* url, NSDictionary* bindings) {
    (void)bindings;
    return [url.pathExtension isEqualToString:@"sakura-recovery"];
  }];
  files = [files filteredArrayUsingPredicate:recoveryFiles];
  if (files.count == 0) return;
  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = [NSString stringWithFormat:
      @"%lu件の未保存文書を復元できます", (unsigned long)files.count];
  alert.informativeText = @"前回終了時に残った自動バックアップが見つかりました。";
  [alert addButtonWithTitle:@"復元"];
  [alert addButtonWithTitle:@"後で"];
  [alert addButtonWithTitle:@"すべて破棄"];
  NSModalResponse response = [alert runModal];
  if (response == NSAlertThirdButtonReturn) {
    for (NSURL* url in files) {
      SakuraRecoveryWriter* writer = [[SakuraRecoveryWriter alloc] init];
      [writer removeAtURL:url completion:^(NSError* error) {
        if (error) [NSApp presentError:error];
      }];
    }
    return;
  }
  if (response != NSAlertFirstButtonReturn) return;
  for (NSURL* url in files) {
    NSDictionary* propertyList = recoveryPropertyListAtURL(url);
    NSString* text = propertyList[@"text"];
    if (![text isKindOfClass:[NSString class]]) continue;
    SakuraDocument* document = [[SakuraDocument alloc] init];
    // Keep the same backup identity until an explicit save/close. Never delete
    // the only durable copy merely because its contents were opened in memory.
    document.recoveryIdentifier = url.lastPathComponent.stringByDeletingPathExtension;
    const auto recovered = sakura::platform::mac::sakuraStringFromString(text);
    const auto utf8 = sakura::core::Utf8Codec::encode(recovered);
    if (!utf8.ok()) continue;
    const auto loaded = document->_session->load(
        utf8.bytes, sakura::core::TextEncoding::utf8);
    if (!loaded.ok()) continue;
    auto encoding = static_cast<sakura::core::TextEncoding>(
        [propertyList[@"encoding"] integerValue]);
    document->_session->setEncodingState(
        {encoding, static_cast<bool>([propertyList[@"bom"] boolValue])});
    if ([propertyList[@"sourceEncodingAmbiguous"] boolValue])
      document->_session->restoreSourceEncodingAmbiguity();
    document->_session->markMetadataChanged();
    [document setPreferredLineEndingString:propertyList[@"lineEnding"]];
    NSString* recoveredName = propertyList[@"displayName"];
    if (recoveredName == nil) recoveredName = @"名称未設定";
    [document setDisplayName:[@"復元 - " stringByAppendingString:recoveredName]];
    [[NSDocumentController sharedDocumentController] addDocument:document];
    [document makeWindowControllers];
    [document showWindows];
    [document updateChangeCount:NSChangeDone];
    [document scheduleRecoveryBackup];
  }
}

- (void)refreshEditorViews {
  [self synchronizeBookmarks];
  for (NSWindowController* controller in self.windowControllers) {
    if ([controller isKindOfClass:[SakuraWindowController class]]) {
      for (SakuraEditorView* editor in
           [(SakuraWindowController*)controller editorViews]) {
        [editor documentContentsDidChange];
      }
      // Read/reload and encoding changes can happen while the window is hidden.
      // Do not leave read-time warnings (or their cleared state) waiting for a
      // drawRect call, and do not take the status away from the active pane.
      SakuraWindowController* editorController = (SakuraWindowController*)controller;
      NSResponder* responder = editorController.window.firstResponder;
      SakuraEditorView* active = [responder isKindOfClass:SakuraEditorView.class] &&
          [editorController.editorViews containsObject:(SakuraEditorView*)responder]
          ? (SakuraEditorView*)responder : editorController.editorView;
      [editorController updateStatusForEditor:active];
    }
  }
}

- (void)synchronizeBookmarks {
  if (self.bookmarkAnchors.count == 0) {
    retireBookmarkSnapshot(std::move(_bookmarkSnapshot)); _bookmarkStatistics={}; return;
  }
  const auto& current=_session->buffer();
  if (_bookmarkSnapshot && _bookmarkSnapshot->revision()==current.revision() &&
      _bookmarkSnapshot->sharesStorageWith(current)) return;
  // Allocate everything before publishing either anchors or the snapshot. A
  // failed comparison/allocation must not map already-updated anchors twice.
  auto next=std::make_unique<sakura::core::TextBuffer>(current);
  BookmarkSynchronizationStatistics statistics;
  NSMutableIndexSet* mapped=self.bookmarkAnchors;
  if (_bookmarkSnapshot) {
    const auto& old=*_bookmarkSnapshot;
    const auto oldLength=old.length(), newLength=current.length();
    const auto last=self.bookmarkAnchors.lastIndex;
    const auto lastNonEnd=last==oldLength ? [self.bookmarkAnchors indexLessThanIndex:last] : last;
    const auto difference=bookmarkDifference(old,current,
        lastNonEnd==NSNotFound ? std::nullopt : std::optional<sakura::core::TextOffset>{lastNonEnd},statistics);
    const bool hasEndAnchor=[self.bookmarkAnchors containsIndex:oldLength];
    if (!difference.unchangedNonEndAnchors || (hasEndAnchor && oldLength!=newLength)) {
      mapped=[NSMutableIndexSet indexSet];
      [self.bookmarkAnchors enumerateIndexesUsingBlock:^(NSUInteger anchor, BOOL* stop) {
        (void)stop;
        const NSUInteger position=anchor==oldLength ? newLength :
            difference.unchangedNonEndAnchors || anchor<difference.prefix ? anchor :
            anchor>=oldLength-difference.suffix ? newLength-(oldLength-anchor) : difference.prefix;
        [mapped addIndex:position];
      }];
      statistics.mappedAnchors=self.bookmarkAnchors.count;
    }
  }
  auto retired=std::move(_bookmarkSnapshot);
  _bookmarkAnchors=mapped;
  _bookmarkSnapshot=std::move(next); _bookmarkStatistics=statistics;
  retireBookmarkSnapshot(std::move(retired));
}

- (NSDictionary*)bookmarkSynchronizationStatistics {
  const auto& current=_session->buffer();
  return @{@"comparedCodeUnits":@(_bookmarkStatistics.comparedUnits),
      @"copiedCodeUnits":@(_bookmarkStatistics.copiedUnits),
      @"comparedTextNodes":@(_bookmarkStatistics.comparedTextNodes),
      @"peakWindowCodeUnits":@(_bookmarkStatistics.peakWindowUnits),
      @"mappedAnchors":@(_bookmarkStatistics.mappedAnchors),
      @"snapshotCodeUnits":@(_bookmarkSnapshot ? _bookmarkSnapshot->length() : 0),
      @"hasSnapshot":@(_bookmarkSnapshot!=nullptr),
      @"snapshotMatchesCurrent":@(_bookmarkSnapshot && _bookmarkSnapshot->revision()==current.revision() &&
          _bookmarkSnapshot->sharesStorageWith(current))};
}

- (NSIndexSet*)bookmarkLines {
  [self synchronizeBookmarks];
  NSMutableIndexSet* lines = [NSMutableIndexSet indexSet];
  [self.bookmarkAnchors enumerateIndexesUsingBlock:^(NSUInteger offset, BOOL* stop) {
    (void)stop;
    [lines addIndex:self->_session->buffer().positionAt(offset).line];
  }];
  return lines;
}

- (void)toggleBookmarkAtLine:(NSUInteger)line {
  [self synchronizeBookmarks];
  if (line >= _session->buffer().lineCount()) return;
  if (!self.bookmarkAnchors) self.bookmarkAnchors = [NSMutableIndexSet indexSet];
  NSMutableIndexSet* remove = [NSMutableIndexSet indexSet];
  [self.bookmarkAnchors enumerateIndexesUsingBlock:^(NSUInteger offset, BOOL* stop) {
    (void)stop;
    if (self->_session->buffer().positionAt(offset).line == line) [remove addIndex:offset];
  }];
  if (remove.count) [self.bookmarkAnchors removeIndexes:remove];
  else [self.bookmarkAnchors addIndex:_session->buffer().lineStartOffset(line)];
  auto next=self.bookmarkAnchors.count ? std::make_unique<sakura::core::TextBuffer>(_session->buffer()) : nullptr;
  auto retired=std::move(_bookmarkSnapshot);
  _bookmarkSnapshot=std::move(next); _bookmarkStatistics={};
  retireBookmarkSnapshot(std::move(retired));
  [self refreshEditorViews];
}

- (void)clearBookmarks {
  self.bookmarkAnchors = nil;
  retireBookmarkSnapshot(std::move(_bookmarkSnapshot)); _bookmarkStatistics={};
  [self refreshEditorViews];
}

@end
