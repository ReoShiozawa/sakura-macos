// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#import "SakuraDocument.h"

#include <cstddef>
#include <exception>
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

NSURL* recoveryDirectoryURL() {
  NSURL* applicationSupport = [[NSFileManager defaultManager]
      URLsForDirectory:NSApplicationSupportDirectory
             inDomains:NSUserDomainMask].firstObject;
  return [[applicationSupport URLByAppendingPathComponent:@"SakuraEditor"
                                               isDirectory:YES]
      URLByAppendingPathComponent:@"Recovery" isDirectory:YES];
}

NSDictionary* recoveryPropertyListAtURL(NSURL* url) {
  NSData* data = [NSData dataWithContentsOfURL:url];
  if (data == nil) return nil;
  return [NSPropertyListSerialization propertyListWithData:data
                                                   options:NSPropertyListImmutable
                                                    format:nil
                                                     error:nil];
}

}  // namespace

@interface SakuraDocument ()
@property(nonatomic, strong, nullable) NSTimer* externalChangeTimer;
@property(nonatomic, strong, nullable) NSTimer* recoveryTimer;
@property(nonatomic, strong, nullable) NSDate* knownModificationDate;
@property(nonatomic, strong, nullable) NSNumber* knownFileSize;
@property(nonatomic, copy) NSString* recoveryIdentifier;
@property(nonatomic) BOOL writingDocument;
@property(nonatomic) BOOL handlingExternalChange;
@property(nonatomic) BOOL closingDocument;
@end

@implementation SakuraDocument

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
  const BOOL wrote = [super writeToURL:url ofType:typeName error:outError];
  self.writingDocument = NO;
  if (wrote && _pendingSaveToken.has_value()) {
    _session->markSaved(*_pendingSaveToken);
    [self updateKnownFileState];
    [self removeRecoveryBackup];
  }
  _pendingSaveToken.reset();
  return wrote;
}

- (BOOL)isDocumentEdited {
  return _session != nullptr ? _session->isDirty() : [super isDocumentEdited];
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
  if (!self.isDocumentEdited) {
    [self removeRecoveryBackup];
    return;
  }
  NSURL* directory = recoveryDirectoryURL();
  [[NSFileManager defaultManager] createDirectoryAtURL:directory
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
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
    @"lineEnding" : [self preferredLineEndingString],
    @"date" : [NSDate date],
    @"text" : sakura::platform::mac::stringFromSakuraString(
        _session->buffer().text()),
  };
  NSData* data = [NSPropertyListSerialization dataWithPropertyList:propertyList
                                                            format:NSPropertyListBinaryFormat_v1_0
                                                           options:0
                                                             error:nil];
  [data writeToURL:[self recoveryBackupURL] options:NSDataWritingAtomic error:nil];
}

- (void)removeRecoveryBackup {
  [[NSFileManager defaultManager] removeItemAtURL:[self recoveryBackupURL]
                                            error:nil];
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
      [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    }
    return;
  }
  if (response != NSAlertFirstButtonReturn) return;
  for (NSURL* url in files) {
    NSDictionary* propertyList = recoveryPropertyListAtURL(url);
    NSString* text = propertyList[@"text"];
    if (![text isKindOfClass:[NSString class]]) continue;
    SakuraDocument* document = [[SakuraDocument alloc] init];
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
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
  }
}

- (void)refreshEditorViews {
  for (NSWindowController* controller in self.windowControllers) {
    if ([controller isKindOfClass:[SakuraWindowController class]]) {
      for (SakuraEditorView* editor in
           [(SakuraWindowController*)controller editorViews]) {
        [editor documentContentsDidChange];
      }
    }
  }
}

@end
