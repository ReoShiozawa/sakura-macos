// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import "SakuraDurableFile.h"
#include <algorithm>
#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

NSString* const SakuraWriteCommittedKey = @"SakuraWriteCommitted";
namespace {
struct FD {
  int value;
  explicit FD(int fd) : value(fd) {}
  ~FD() { if (value >= 0) ::close(value); }
  FD(const FD&) = delete;
  FD& operator=(const FD&) = delete;
};
BOOL failure(NSError** error, NSString* operation, BOOL committed) {
  int code = errno;
  if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:@{
    NSLocalizedDescriptionKey:committed
      ? [NSString stringWithFormat:@"%@に失敗しました。書込みは反映済みの可能性がありますが、ディスク同期は完了していません。復旧データを保持します。", operation]
      : [NSString stringWithFormat:@"%@に失敗しました。", operation],
    SakuraWriteCommittedKey:@(committed)}];
  return NO;
}
bool allow(SakuraDurableWriteGate gate, SakuraDurableWriteStage stage) {
  if (!gate || gate(stage)) return true;
  errno = EIO; return false;
}
bool fullSync(int fd) {
  int result;
  do { result = ::fcntl(fd, F_FULLFSYNC); } while (result < 0 && errno == EINTR);
  return result == 0;
}
bool directorySync(int fd) {
  int result;
  do { result = ::fsync(fd); } while (result < 0 && errno == EINTR);
  return result == 0;
}
bool regular(int fd) {
  struct stat info{};
  if (::fstat(fd, &info) < 0) return false;
  if (!S_ISREG(info.st_mode)) { errno = EINVAL; return false; }
  return true;
}
}

BOOL SakuraDurableReplaceData(NSData* data, NSURL* url, NSError** error) {
  return SakuraDurableReplaceDataWithGate(data, url, error, nil);
}
BOOL SakuraDurableReplaceDataWithGate(NSData* data, NSURL* url,
    NSError** error, SakuraDurableWriteGate gate) {
  if (!url.isFileURL || !data || !url.lastPathComponent.length) {
    errno = EINVAL; return failure(error, @"保存先の検証", NO);
  }
  FD directory(::open(url.URLByDeletingLastPathComponent.fileSystemRepresentation,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
  if (directory.value < 0) return failure(error, @"保存フォルダーを開く処理", NO);
  NSString* name = url.lastPathComponent;
  struct stat original{};
  if (::fstatat(directory.value, name.fileSystemRepresentation, &original, AT_SYMLINK_NOFOLLOW) == 0) {
    if (!S_ISREG(original.st_mode)) { errno = EINVAL; return failure(error, @"既存ファイルの検証", NO); }
  } else if (errno != ENOENT) return failure(error, @"既存ファイルの検証", NO);
  NSString* temporary = [@".sakura-stage-" stringByAppendingString:NSUUID.UUID.UUIDString];
  FD file(::openat(directory.value, temporary.fileSystemRepresentation,
      O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600));
  if (file.value < 0) return failure(error, @"一時ファイルの作成", NO);
  struct Cleanup {
    int directory; const char* name; bool renamed{};
    ~Cleanup() { if (!renamed) ::unlinkat(directory, name, 0); }
  } cleanup{directory.value, temporary.fileSystemRepresentation};
  NSUInteger offset = 0;
  while (offset < data.length) {
    ssize_t count = ::write(file.value, static_cast<const char*>(data.bytes) + offset,
        std::min<NSUInteger>(data.length - offset, 1024 * 1024));
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) { if (!count) errno = EIO; return failure(error, @"一時ファイルの書込み", NO); }
    offset += count;
  }
  if (!allow(gate, SakuraDurableWriteFileSync) || !fullSync(file.value))
    return failure(error, @"ファイルのディスク同期", NO);
  if (!allow(gate, SakuraDurableWriteRename) ||
      ::renameat(directory.value, temporary.fileSystemRepresentation, directory.value, name.fileSystemRepresentation) < 0)
    return failure(error, @"保存ファイルの置換", NO);
  cleanup.renamed = true;
  if (!allow(gate, SakuraDurableWriteDirectorySync) || !directorySync(directory.value))
    return failure(error, @"保存フォルダーの同期", YES);
  // Flush the device again after the rename/directory metadata was submitted.
  if (!allow(gate, SakuraDurableWriteFinalSync) || !fullSync(file.value))
    return failure(error, @"置換後のディスク同期", YES);
  return YES;
}

BOOL SakuraSynchronizeSavedFile(NSURL* url, NSError** error) {
  if (!url.isFileURL) { errno = EINVAL; return failure(error, @"保存先の検証", YES); }
  FD file(::open(url.fileSystemRepresentation, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC));
  if (file.value < 0 || !regular(file.value)) return failure(error, @"保存済みファイルの検証", YES);
  if (!fullSync(file.value)) return failure(error, @"保存済みファイルの同期", YES);
  FD directory(::open(url.URLByDeletingLastPathComponent.fileSystemRepresentation,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
  if (directory.value < 0 || !directorySync(directory.value) || !fullSync(file.value))
    return failure(error, @"保存先メタデータの同期", YES);
  return YES;
}
