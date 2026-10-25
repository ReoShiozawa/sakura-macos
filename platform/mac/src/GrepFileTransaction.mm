// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include "sakura/platform/mac/GrepFileTransaction.h"

#include <algorithm>
#include <array>
#include <cerrno>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <copyfile.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

namespace sakura::platform::mac {
namespace {

class FileDescriptor {
 public:
  explicit FileDescriptor(int value = -1) : value_(value) {}
  ~FileDescriptor() { if (value_ >= 0) ::close(value_); }
  FileDescriptor(const FileDescriptor&) = delete;
  FileDescriptor& operator=(const FileDescriptor&) = delete;
  int get() const { return value_; }
  bool valid() const { return value_ >= 0; }

 private:
  int value_;
};

struct StagedFiles {
  int directory;
  std::string temporary;
  std::string backup;
  ~StagedFiles() {
    if (!temporary.empty()) ::unlinkat(directory, temporary.c_str(), 0);
    if (!backup.empty()) ::unlinkat(directory, backup.c_str(), 0);
  }
};

std::string systemError(const char* operation) {
  return std::string(operation) + ": " + std::strerror(errno);
}

GrepFileIdentity identity(const struct stat& info) {
  return {static_cast<std::uint64_t>(info.st_dev),
          static_cast<std::uint64_t>(info.st_ino),
          static_cast<std::uint32_t>(info.st_mode),
          static_cast<std::int64_t>(info.st_size),
          info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec,
          info.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec};
}

bool validFilename(const std::string& name) {
  return !name.empty() && name != "." && name != ".." &&
      name.find('\0') == std::string::npos;
}

bool readBytes(int descriptor, std::size_t maximumBytes,
               std::vector<std::byte>& result, std::string& error) {
  struct stat info {};
  if (::fstat(descriptor, &info) != 0) {
    error = systemError("fstat");
    return false;
  }
  if (!S_ISREG(info.st_mode)) {
    error = "The target is not a regular file";
    return false;
  }
  if (info.st_size < 0 || static_cast<std::uint64_t>(info.st_size) > maximumBytes) {
    error = "The file exceeds the snapshot size limit";
    return false;
  }
  result.clear();
  result.reserve(static_cast<std::size_t>(info.st_size));
  std::array<std::byte, 64U * 1024U> buffer;
  while (true) {
    const auto count = ::pread(descriptor, buffer.data(), buffer.size(),
                               static_cast<off_t>(result.size()));
    if (count < 0 && errno == EINTR) continue;
    if (count < 0) {
      error = systemError("read");
      return false;
    }
    if (count == 0) return true;
    if (static_cast<std::size_t>(count) > maximumBytes - result.size()) {
      error = "The file grew beyond the snapshot size limit";
      return false;
    }
    result.insert(result.end(), buffer.begin(), buffer.begin() + count);
  }
}

bool writeBytes(int descriptor, std::span<const std::byte> bytes,
                std::uint32_t mode, std::string& error) {
  std::size_t offset = 0;
  while (offset < bytes.size()) {
    const auto count = ::write(descriptor, bytes.data() + offset, bytes.size() - offset);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) {
      error = systemError("write");
      return false;
    }
    offset += static_cast<std::size_t>(count);
  }
  if (::fchmod(descriptor, mode & 07777U) != 0) {
    error = systemError("chmod");
    return false;
  }
  if (::fsync(descriptor) != 0) {
    error = systemError("fsync");
    return false;
  }
  return true;
}

bool preserveSecurityMetadata(int original, int destination, std::uint32_t mode,
                              std::string& error) {
  struct stat sourceInfo {}, destinationInfo {};
  if (::fstat(original, &sourceInfo) != 0 || ::fstat(destination, &destinationInfo) != 0) {
    error = systemError("read ownership");
    return false;
  }
  if ((sourceInfo.st_uid != destinationInfo.st_uid ||
       sourceInfo.st_gid != destinationInfo.st_gid) &&
      ::fchown(destination, sourceInfo.st_uid, sourceInfo.st_gid) != 0) {
    error = systemError("preserve ownership");
    return false;
  }
  if (::fcopyfile(original, destination, nullptr, COPYFILE_ACL | COPYFILE_XATTR) != 0 ||
      ::fchmod(destination, mode & 07777U) != 0 || ::fsync(destination) != 0) {
    error = systemError("preserve file metadata");
    return false;
  }
  return true;
}

bool matchesSnapshot(int directory, int descriptor, const std::string& filename,
                     const GrepFileSnapshot& snapshot) {
  struct stat fileInfo {}, pathInfo {}, directoryInfo {};
  if (::lstat(snapshot.path.parent_path().c_str(), &directoryInfo) != 0 ||
      !S_ISDIR(directoryInfo.st_mode) ||
      static_cast<std::uint64_t>(directoryInfo.st_dev) != snapshot.parentDevice ||
      static_cast<std::uint64_t>(directoryInfo.st_ino) != snapshot.parentInode) return false;
  if (::fstat(descriptor, &fileInfo) != 0 ||
      ::fstatat(directory, filename.c_str(), &pathInfo, AT_SYMLINK_NOFOLLOW) != 0 ||
      !S_ISREG(pathInfo.st_mode) || identity(fileInfo) != snapshot.identity ||
      identity(pathInfo) != snapshot.identity) return false;
  std::vector<std::byte> bytes;
  std::string error;
  if (!readBytes(descriptor, snapshot.bytes.size(), bytes, error) || bytes != snapshot.bytes)
    return false;
  // Catch changes made while reading, and link/path replacements during the read.
  return ::fstat(descriptor, &fileInfo) == 0 &&
      ::fstatat(directory, filename.c_str(), &pathInfo, AT_SYMLINK_NOFOLLOW) == 0 &&
      identity(fileInfo) == snapshot.identity && identity(pathInfo) == snapshot.identity;
}

int createTemporary(int directory, std::string& name) {
  for (unsigned int attempt = 0; attempt < 32; ++attempt) {
    std::array<char, 64> buffer;
    std::snprintf(buffer.data(), buffer.size(), ".sakura-grep-%08x%08x.tmp",
                  ::arc4random(), ::arc4random());
    const int descriptor = ::openat(directory, buffer.data(),
                                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                                    0600);
    if (descriptor >= 0) name = buffer.data();
    if (descriptor >= 0 || errno != EEXIST) return descriptor;
  }
  errno = EEXIST;
  return -1;
}

GrepCommitResult stopped(GrepCommitStatus status, std::string error = {}) {
  return {status, {}, std::move(error)};
}

}  // namespace

GrepSnapshotResult readGrepFileSnapshot(const std::filesystem::path& path,
                                       std::size_t maximumBytes) {
  const auto absolute = std::filesystem::absolute(path).lexically_normal();
  const std::string filename = absolute.filename().string();
  if (!validFilename(filename)) return {{}, "Invalid target filename"};
  FileDescriptor directory(::open(absolute.parent_path().c_str(),
                                  O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
  if (!directory.valid()) return {{}, systemError("open directory")};
  struct stat directoryInfo {};
  if (::fstat(directory.get(), &directoryInfo) != 0) return {{}, systemError("fstat directory")};
  struct stat initialPathInfo {};
  if (::fstatat(directory.get(), filename.c_str(), &initialPathInfo, AT_SYMLINK_NOFOLLOW) != 0)
    return {{}, systemError("inspect file")};
  if (!S_ISREG(initialPathInfo.st_mode)) return {{}, "The target is not a regular file"};
  FileDescriptor file(::openat(directory.get(), filename.c_str(),
                               O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC));
  if (!file.valid()) return {{}, systemError("open file")};
  struct stat before {}, after {}, pathInfo {};
  if (::fstat(file.get(), &before) != 0) return {{}, systemError("fstat file")};
  if (!S_ISREG(before.st_mode)) return {{}, "The target is not a regular file"};
  if (identity(initialPathInfo) != identity(before))
    return {{}, "The file changed before its snapshot could be read"};
  if (::flock(file.get(), LOCK_SH | LOCK_NB) != 0) return {{}, systemError("lock file")};
  GrepFileSnapshot snapshot;
  snapshot.path = absolute;
  snapshot.identity = identity(before);
  snapshot.parentDevice = static_cast<std::uint64_t>(directoryInfo.st_dev);
  snapshot.parentInode = static_cast<std::uint64_t>(directoryInfo.st_ino);
  std::string error;
  if (!readBytes(file.get(), maximumBytes, snapshot.bytes, error)) return {{}, std::move(error)};
  if (::fstat(file.get(), &after) != 0 ||
      ::fstatat(directory.get(), filename.c_str(), &pathInfo, AT_SYMLINK_NOFOLLOW) != 0 ||
      identity(before) != identity(after) || identity(before) != identity(pathInfo)) {
    return {{}, "The file changed while its snapshot was being read"};
  }
  return {std::move(snapshot), {}};
}

GrepCommitResult commitGrepReplacement(const GrepFileSnapshot& snapshot,
                                      std::span<const std::byte> replacement,
                                      const GrepCommitOptions& options) {
  const auto cancelled = [&] { return options.cancelled && options.cancelled(); };
  const auto permitted = [&] { return !options.beforeCommit || options.beforeCommit(); };
  const auto syncFile = [&](int fd, GrepSyncStage stage) {
    if (options.beforeSync && !options.beforeSync(stage)) { errno = EIO; return false; }
    int result;
    do { result = ::fcntl(fd, F_FULLFSYNC); } while (result < 0 && errno == EINTR);
    return result == 0;
  };
  if (cancelled()) return stopped(GrepCommitStatus::cancelled);
  const auto filename = snapshot.path.filename().string();
  if (!snapshot.path.is_absolute() || !validFilename(filename))
    return stopped(GrepCommitStatus::error, "Invalid snapshot path");
  FileDescriptor directory(::open(snapshot.path.parent_path().c_str(),
                                  O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
  if (!directory.valid()) return stopped(GrepCommitStatus::conflict, systemError("open directory"));
  struct stat directoryInfo {};
  if (::fstat(directory.get(), &directoryInfo) != 0 ||
      static_cast<std::uint64_t>(directoryInfo.st_dev) != snapshot.parentDevice ||
      static_cast<std::uint64_t>(directoryInfo.st_ino) != snapshot.parentInode)
    return stopped(GrepCommitStatus::conflict, "The containing directory changed");
  struct stat initialPathInfo {};
  if (::fstatat(directory.get(), filename.c_str(), &initialPathInfo, AT_SYMLINK_NOFOLLOW) != 0 ||
      identity(initialPathInfo) != snapshot.identity || !S_ISREG(initialPathInfo.st_mode))
    return stopped(GrepCommitStatus::conflict, "The file changed after preview");
  FileDescriptor original(::openat(directory.get(), filename.c_str(),
                                   O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC));
  if (!original.valid()) return stopped(errno == EACCES || errno == EPERM ?
      GrepCommitStatus::error : GrepCommitStatus::conflict, systemError("open file for replacement"));
  struct stat originalInfo {};
  if (::fstat(original.get(), &originalInfo) != 0 || !S_ISREG(originalInfo.st_mode))
    return stopped(GrepCommitStatus::conflict, "The target is no longer a regular file");
  if ((originalInfo.st_mode & 0222U) == 0)
    return stopped(GrepCommitStatus::error, "The target is read-only");
  if (::flock(original.get(), LOCK_EX | LOCK_NB) != 0)
    return stopped(GrepCommitStatus::conflict, systemError("lock file"));
  if (!matchesSnapshot(directory.get(), original.get(), filename, snapshot))
    return stopped(GrepCommitStatus::conflict, "The file changed after preview");

  StagedFiles staged{directory.get(), {}, {}};
  FileDescriptor temporary(createTemporary(directory.get(), staged.temporary));
  if (!temporary.valid()) return stopped(GrepCommitStatus::error, systemError("create temporary file"));
  std::string error;
  if (!writeBytes(temporary.get(), replacement, snapshot.identity.mode, error))
    return stopped(GrepCommitStatus::error, std::move(error));
  if (!preserveSecurityMetadata(original.get(), temporary.get(), snapshot.identity.mode, error))
    return stopped(GrepCommitStatus::error, std::move(error));
  if (!syncFile(temporary.get(), GrepSyncStage::fileBeforeRename))
    return stopped(GrepCommitStatus::error, systemError("full sync staged file"));
  if (options.afterStaging) options.afterStaging();
  if (cancelled()) return stopped(GrepCommitStatus::cancelled);
  if (!permitted()) return stopped(cancelled() ? GrepCommitStatus::cancelled :
      GrepCommitStatus::conflict, "Replacement was refused before writing");
  if (!matchesSnapshot(directory.get(), original.get(), filename, snapshot))
    return stopped(GrepCommitStatus::conflict, "The file changed while replacement was prepared");

  if (options.createBackup) {
    for (std::uint64_t suffix = 0; suffix < 1000000; ++suffix) {
      if (cancelled()) return stopped(GrepCommitStatus::cancelled);
      const auto candidate = filename + ".bak" + (suffix ? "." + std::to_string(suffix) : "");
      FileDescriptor backup(::openat(directory.get(), candidate.c_str(),
                                     O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                                     0600));
      if (!backup.valid()) {
        if (errno == EEXIST) continue;
        return stopped(GrepCommitStatus::error, systemError("create backup"));
      }
      staged.backup = candidate;
      if (!writeBytes(backup.get(), snapshot.bytes, snapshot.identity.mode, error))
        return stopped(GrepCommitStatus::error, std::move(error));
      if (!preserveSecurityMetadata(original.get(), backup.get(), snapshot.identity.mode, error))
        return stopped(GrepCommitStatus::error, std::move(error));
      if (!syncFile(backup.get(), GrepSyncStage::fileBeforeRename))
        return stopped(GrepCommitStatus::error, systemError("full sync backup"));
      break;
    }
    if (staged.backup.empty())
      return stopped(GrepCommitStatus::error, "No unused backup filename is available");
  }

  if (cancelled()) return stopped(GrepCommitStatus::cancelled);
  if (!permitted()) return stopped(cancelled() ? GrepCommitStatus::cancelled :
      GrepCommitStatus::conflict, "Replacement was refused before writing");
  if (!matchesSnapshot(directory.get(), original.get(), filename, snapshot))
    return stopped(GrepCommitStatus::conflict, "The file changed immediately before replacement");
  if (cancelled()) return stopped(GrepCommitStatus::cancelled);
  if (::renameat(directory.get(), staged.temporary.c_str(), directory.get(), filename.c_str()) != 0)
    return stopped(GrepCommitStatus::error, systemError("replace file"));
  staged.temporary.clear();
  const auto backupPath = staged.backup.empty() ? std::filesystem::path{} :
      snapshot.path.parent_path() / staged.backup;
  staged.backup.clear();
  // A rename is already committed: never report it as an unchanged/error-only
  // file if metadata/device flushing fails. Keep the backup and stop the batch.
  bool synced = !options.beforeSync || options.beforeSync(GrepSyncStage::directoryAfterRename);
  if (synced) {
    int result;
    do { result = ::fsync(directory.get()); } while (result < 0 && errno == EINTR);
    synced = result == 0;
  } else errno = EIO;
  if (!synced || !syncFile(temporary.get(), GrepSyncStage::fileAfterRename))
    return {GrepCommitStatus::writtenNotDurable, backupPath,
        systemError("Replacement is applied, but disk synchronization failed; retain/check the backup")};
  return {GrepCommitStatus::written, backupPath, {}};
}

bool isGrepBackupPath(const std::filesystem::path& path) {
  auto name = path.filename().string();
  std::transform(name.begin(), name.end(), name.begin(),
                 [](unsigned char value) { return static_cast<char>(std::tolower(value)); });
  const auto marker = name.rfind(".bak");
  if (marker == std::string::npos) return false;
  const auto suffix = name.substr(marker + 4);
  return suffix.empty() || (suffix.size() > 1 && suffix.front() == '.' &&
      std::all_of(suffix.begin() + 1, suffix.end(),
                   [](unsigned char value) { return value >= '0' && value <= '9'; }));
}

}  // namespace sakura::platform::mac
