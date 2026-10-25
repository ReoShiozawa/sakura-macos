// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import "SakuraRecoveryStore.h"
#import "SakuraDurableFile.h"
#include "sakura/core/encoding/EncodingService.h"
#include <cerrno>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

NSString* const SakuraRecoveryGenerationsKey = @"SakuraRecoveryGenerations";
NSString* const SakuraRecoveryBudgetMiBKey = @"SakuraRecoveryBudgetMiB";

namespace {
constexpr NSUInteger maximumGenerations = 20;
// The lock inode is permanent. Unlinking it would let new writers lock a
// different inode while an older process is still inside the critical section.
class DirectoryLock {
 public:
  explicit DirectoryLock(NSURL* directory) {
    directory_ = ::open(directory.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory_ < 0) return;
    lock_ = ::openat(directory_, ".sakura-recovery.lock",
        O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    struct stat info{};
    valid_ = lock_ >= 0 && ::fstat(lock_, &info) == 0 &&
        S_ISREG(info.st_mode) && info.st_nlink == 1 &&
        ::flock(lock_, LOCK_EX | LOCK_NB) == 0;
  }
  ~DirectoryLock() {
    if (lock_ >= 0) ::close(lock_);
    if (directory_ >= 0) ::close(directory_);
  }
  bool valid() const { return valid_; }
  bool removeRegular(NSString* name) const {
    struct stat info{};
    if (::fstatat(directory_, name.fileSystemRepresentation, &info, AT_SYMLINK_NOFOLLOW) < 0)
      return errno == ENOENT;
    if (!S_ISREG(info.st_mode)) return false;
    return ::unlinkat(directory_, name.fileSystemRepresentation, 0) == 0;
  }
  bool syncDeletion() const {
    if (!valid_) return false;
    int result;
    do { result = ::fsync(directory_); } while (result < 0 && errno == EINTR);
    if (result < 0) return false;
    do { result = ::fcntl(lock_, F_FULLFSYNC); } while (result < 0 && errno == EINTR);
    return result == 0;
  }
 private:
  int directory_{-1}, lock_{-1}; bool valid_{};
};
NSURL* previous(NSURL* url, NSUInteger generation) {
  return [NSURL fileURLWithPath:[url.path stringByAppendingFormat:@".previous-%lu",
                                      (unsigned long)generation]];
}
NSDictionary* validateRecord(id value) {
  if (![value isKindOfClass:NSDictionary.class]) return nil;
  NSDictionary* record = value;
  if (![record[@"version"] isKindOfClass:NSNumber.class] ||
      [record[@"version"] doubleValue] != 1 ||
      ![record[@"text"] isKindOfClass:NSString.class] ||
      ![record[@"displayName"] isKindOfClass:NSString.class] ||
      ![record[@"originalPath"] isKindOfClass:NSString.class] ||
      ![record[@"encoding"] isKindOfClass:NSNumber.class] ||
      ![record[@"bom"] isKindOfClass:NSNumber.class] ||
      ![record[@"date"] isKindOfClass:NSDate.class] ||
      ![record[@"lineEnding"] isKindOfClass:NSString.class] ||
      ![@[@"LF", @"CR", @"CRLF"] containsObject:record[@"lineEnding"]]) return nil;
  using sakura::core::TextEncoding;
  // Optional for old v1 records. New records retain input-encoding uncertainty
  // even though their recovery payload is already Unicode.
  id ambiguous = record[@"sourceEncodingAmbiguous"];
  if (ambiguous && (![ambiguous isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)ambiguous) != CFBooleanGetTypeID())) return nil;
  long long encoding = [record[@"encoding"] longLongValue];
  if (encoding < 1 || encoding > 6 || [record[@"encoding"] doubleValue] != encoding) return nil;
  switch (static_cast<TextEncoding>([record[@"encoding"] integerValue])) {
    case TextEncoding::utf8:
    case TextEncoding::utf16LittleEndian:
    case TextEncoding::utf16BigEndian:
    case TextEncoding::shiftJis:
    case TextEncoding::eucJp:
    case TextEncoding::iso2022Jp: return record;
    default: return nil;
  }
}
NSData* readData(NSURL* url) {
  if (!url.isFileURL) return nil;
  int fd = ::open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) return nil;
  struct Close { int fd; ~Close() { ::close(fd); } } close{fd};
  struct stat info{};
  if (::fstat(fd, &info) < 0 || !S_ISREG(info.st_mode) || info.st_size < 0 ||
      info.st_size > 256LL * 1024 * 1024) return nil;
  NSMutableData* data = [NSMutableData dataWithLength:static_cast<NSUInteger>(info.st_size)];
  NSUInteger offset = 0;
  while (offset < data.length) {
    ssize_t count = ::read(fd, static_cast<char*>(data.mutableBytes) + offset, data.length - offset);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) return nil;
    offset += count;
  }
  return data;
}
NSDictionary* recordFromData(NSData* data) {
  if (!data) return nil;
  return validateRecord([NSPropertyListSerialization propertyListWithData:data
      options:NSPropertyListImmutable format:nil error:nil]);
}
NSDictionary* readOne(NSURL* url) {
  return recordFromData(readData(url));
}
BOOL fail(NSError** error, NSString* message) {
  if (error) *error = [NSError errorWithDomain:@"SakuraRecovery" code:1
      userInfo:@{NSLocalizedDescriptionKey:message}];
  return NO;
}
}

NSUInteger SakuraRecoveryGenerations(NSUserDefaults* defaults) {
  id value = [defaults objectForKey:SakuraRecoveryGenerationsKey];
  if (![value isKindOfClass:NSNumber.class] || [value doubleValue] != [value integerValue] ||
      [value integerValue] < 0 || [value integerValue] > static_cast<NSInteger>(maximumGenerations)) return 2;
  return [value unsignedIntegerValue];
}
NSUInteger SakuraRecoveryBudgetMiB(NSUserDefaults* defaults) {
  id value = [defaults objectForKey:SakuraRecoveryBudgetMiBKey];
  if (![value isKindOfClass:NSNumber.class] || [value doubleValue] != [value integerValue] ||
      [value integerValue] < 16 || [value integerValue] > 4096) return 256;
  return [value unsignedIntegerValue];
}
BOOL SakuraSetRecoverySettings(NSUserDefaults* defaults, NSInteger generations,
                              NSInteger budgetMiB, NSError** error) {
  if (generations < 0 || generations > static_cast<NSInteger>(maximumGenerations) || budgetMiB < 16 || budgetMiB > 4096)
    return fail(error, @"復旧世代数は0〜20、容量は16〜4,096 MiBで指定してください。");
  [defaults setInteger:generations forKey:SakuraRecoveryGenerationsKey];
  [defaults setInteger:budgetMiB forKey:SakuraRecoveryBudgetMiBKey];
  return YES;
}
NSDictionary* SakuraReadRecovery(NSURL* url) {
  if (!url.isFileURL) return nil;
  for (NSUInteger generation = 0; generation <= maximumGenerations; ++generation) {
    @autoreleasepool {
      NSDictionary* record = readOne(generation ? previous(url, generation) : url);
      if (record) return record;
    }
  }
  return nil;
}

BOOL SakuraWriteRecovery(NSURL* url, NSDictionary* record,
                         unsigned long long budget, NSError** error) {
  return SakuraWriteRecoveryWithGenerations(url, record, budget, 2, error);
}
BOOL SakuraWriteRecoveryWithGenerations(NSURL* url, NSDictionary* record,
    unsigned long long budget, NSUInteger generations, NSError** error) {
  if (!url.isFileURL || !url.lastPathComponent.length || generations > maximumGenerations || !validateRecord(record))
    return fail(error, @"復旧データまたは保存世代数が不正です。以前のバックアップを保持します。");
  // Even ASCII needs at least one stored byte per UTF-16 unit. Reject plainly
  // impossible records before asking Foundation to allocate a full binary plist.
  // Exact size, metadata overhead and all generations are still checked below.
  if ([record[@"text"] length] > 256ULL * 1024 * 1024 ||
      [record[@"text"] length] > budget)
    return fail(error, @"復旧本文だけで容量上限を超えています。以前のバックアップを保持します。");
  NSFileManager* fm = NSFileManager.defaultManager;
  NSURL* directory = url.URLByDeletingLastPathComponent;
  NSDictionary* directoryAttributes = [fm attributesOfItemAtPath:directory.path error:nil];
  if (directoryAttributes &&
      ![directoryAttributes[NSFileType] isEqual:NSFileTypeDirectory])
    return fail(error, @"復旧先が通常のフォルダーではありません。保存を停止しました。");
  NSMutableArray<NSURL*>* newParents = [NSMutableArray array];
  NSURL* missing = directory;
  while (missing.path.length > 1 && ![fm fileExistsAtPath:missing.path]) {
    [newParents addObject:missing.URLByDeletingLastPathComponent];
    missing = missing.URLByDeletingLastPathComponent;
  }
  if (![fm createDirectoryAtURL:directory withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:error]) return NO;
  // A newly created Recovery/ entry must itself be submitted to the parent
  // directory before the later F_FULLFSYNC flushes the volume's metadata.
  for (NSURL* parent in newParents) {
    int fd = ::open(parent.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return fail(error, @"新しい復旧フォルダーの親を開けません。保存を停止しました。");
    int synced;
    do { synced = ::fsync(fd); } while (synced < 0 && errno == EINTR);
    ::close(fd);
    if (synced < 0) return fail(error, @"新しい復旧フォルダーの同期に失敗しました。保存を停止しました。");
  }
  DirectoryLock lock(directory);
  if (!lock.valid()) return fail(error, @"他のプロセスが復旧データを保存中か、復旧先の排他制御に失敗しました。既存データを保持します。");
  NSData* data = [NSPropertyListSerialization dataWithPropertyList:record
      format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
  if (!data) return NO;
  if (data.length > 256ULL * 1024 * 1024)
    return fail(error, @"1件の復旧データは256MiBまでです。以前のバックアップを保持します。");
  // Count all files, including unknown/corrupt/legacy records. Reserve space
  // conservatively for atomic writes; reaching the cap must never evict data.
  NSArray<NSURL*>* entries = [fm contentsOfDirectoryAtURL:directory
      includingPropertiesForKeys:nil options:0 error:error];
  if (!entries) return NO;
  unsigned long long used = 0;
  for (NSURL* entry in entries) {
    NSDictionary* attrs = [fm attributesOfItemAtPath:entry.path error:error];
    if (!attrs) return NO;
    if (![attrs[NSFileType] isEqual:NSFileTypeRegular])
      return fail(error, @"復旧フォルダーに通常のファイル以外があります。既存データを保持して保存を停止しました。");
    const auto size = [attrs[NSFileSize] unsignedLongLongValue];
    if (size > budget || used > budget - size)
      return fail(error, @"復旧データの容量上限を超えています。文書を別の場所へ保存してください。");
    used += size;
  }
  BOOL validCurrent = readOne(url) != nil;
  NSMutableArray<NSDictionary*>* archive = [NSMutableArray array];
  if (validCurrent) {
    for (NSUInteger generation = generations; generation > 0; --generation) {
      @autoreleasepool {
        NSURL* source = generation == 1 ? url : previous(url, generation - 1);
        NSData* bytes = readData(source);
        if (!recordFromData(bytes)) continue;
        [archive addObject:@{@"url":previous(url, generation), @"source":source, @"size":@(bytes.length)}];
      }
    }
  }
  NSMutableArray<NSNumber*>* pendingSizes = [NSMutableArray arrayWithObject:@(data.length)];
  for (NSDictionary* item in archive) [pendingSizes addObject:item[@"size"]];
  for (NSNumber* pending in pendingSizes) {
    const auto length = pending.unsignedLongLongValue;
    if (length > budget || used > budget - length)
      return fail(error, @"復旧データの容量上限に達しました。以前のバックアップは保持されています。文書を別の場所へ保存してください。");
    used += length;
  }
  // Lock covers quota, rotation, commit and pruning across all processes.
  // Keep at most one old generation's data in memory, not all twenty.
  for (NSDictionary* item in archive) {
    @autoreleasepool {
      NSData* bytes = readData(item[@"source"]);
      if (bytes.length != [item[@"size"] unsignedLongLongValue] || !recordFromData(bytes))
        return fail(error, @"保存中に復旧世代が変更されました。以前のバックアップを保持します。");
      if (!SakuraDurableReplaceData(bytes, item[@"url"], error)) return NO;
    }
  }
  if (!SakuraDurableReplaceData(data, url, error)) return NO;
  // Only prune this document's excess generations after the new primary has
  // reached the full-sync boundary. Corrupt primary repair retains fallbacks.
  if (validCurrent) {
    bool removed = true;
    for (NSUInteger generation = generations + 1; generation <= maximumGenerations; ++generation)
      if (!lock.removeRegular(previous(url, generation).lastPathComponent)) removed = false;
    if (!lock.syncDeletion() || !removed)
      return fail(error, @"新しい復旧バックアップは反映済みですが、旧世代の削除または同期に失敗しました。");
  }
  return YES;
}

void SakuraRemoveRecovery(NSURL* url) {
  (void)SakuraRemoveRecoveryChecked(url, nil);
}

BOOL SakuraRemoveRecoveryChecked(NSURL* url, NSError** error) {
  if (!url.isFileURL || ![url.pathExtension isEqualToString:@"sakura-recovery"])
    return fail(error, @"復旧バックアップ以外の削除を拒否しました。");
  NSURL* directory = url.URLByDeletingLastPathComponent;
  struct stat info{};
  if (::lstat(directory.fileSystemRepresentation, &info) < 0) {
    if (errno == ENOENT) return YES;
    return fail(error, @"復旧フォルダーの状態を確認できず、削除を中止しました。");
  }
  DirectoryLock lock(directory);
  if (!lock.valid())
    return fail(error, @"復旧フォルダーが使用中か、安全に排他できません。バックアップを保持します。");
  bool removed = true;
  for (NSUInteger generation = 0; generation <= maximumGenerations; ++generation)
    if (!lock.removeRegular((generation ? previous(url, generation) : url).lastPathComponent)) removed = false;
  if (!lock.syncDeletion() || !removed)
    return fail(error, @"復旧バックアップの削除または削除後の同期に失敗しました。次回起動時に古いバックアップが表示される可能性があります。");
  return YES;
}
