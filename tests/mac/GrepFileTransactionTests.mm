// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <span>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

#include "sakura/platform/mac/GrepFileTransaction.h"

namespace {
namespace fs = std::filesystem;
using namespace sakura::platform::mac;

int failures = 0;
#define EXPECT(test, expression) \
  do { if (!(expression)) { \
    std::cerr << test << ':' << __LINE__ << ": " << #expression << '\n'; \
    ++failures; \
  } } while (false)

struct TemporaryDirectory {
  fs::path path;
  TemporaryDirectory() {
    std::string name = (fs::temp_directory_path() / "sakura-grep-test-XXXXXX").string();
    char* created = ::mkdtemp(name.data());
    if (!created) throw std::runtime_error("Cannot create test directory");
    path = created;
  }
  ~TemporaryDirectory() { fs::remove_all(path); }
};

void write(const fs::path& path, std::string_view text) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  output.write(text.data(), static_cast<std::streamsize>(text.size()));
  if (!output) throw std::runtime_error("Cannot write fixture");
}

std::string read(const fs::path& path) {
  std::ifstream input(path, std::ios::binary);
  return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}

std::span<const std::byte> bytes(std::string_view text) {
  return std::as_bytes(std::span(text.data(), text.size()));
}

std::size_t entries(const fs::path& directory) {
  return static_cast<std::size_t>(std::distance(fs::directory_iterator(directory),
                                                fs::directory_iterator{}));
}

void writesSnapshotBackupAndPreservesMode() {
  constexpr auto test = "writesSnapshotBackupAndPreservesMode";
  TemporaryDirectory directory;
  const auto path = directory.path / "document.txt";
  const std::string original("a\0b\n", 4);
  write(path, original);
  ::chmod(path.c_str(), 0640);
  const std::string attribute = "retained metadata";
  EXPECT(test, ::setxattr(path.c_str(), "com.sakura.grep-test", attribute.data(),
                         attribute.size(), 0, 0) == 0);
  write(directory.path / "document.txt.bak", "previous backup");
  write(directory.path / "document.txt.bak.1", "older backup");
  fs::create_symlink("document.txt.bak", directory.path / "document.txt.bak.2");
  const auto preview = readGrepFileSnapshot(path);
  EXPECT(test, preview.snapshot.has_value());
  if (!preview.snapshot) return;
  const auto result = commitGrepReplacement(*preview.snapshot, bytes("changed"));
  EXPECT(test, result.status == GrepCommitStatus::written);
  EXPECT(test, read(path) == "changed");
  EXPECT(test, result.backupPath == directory.path / "document.txt.bak.3");
  EXPECT(test, read(result.backupPath) == original);
  EXPECT(test, read(directory.path / "document.txt.bak") == "previous backup");
  EXPECT(test, read(directory.path / "document.txt.bak.1") == "older backup");
  struct stat info {};
  ::stat(path.c_str(), &info);
  EXPECT(test, (info.st_mode & 07777) == 0640);
  ::stat(result.backupPath.c_str(), &info);
  EXPECT(test, (info.st_mode & 07777) == 0640);
  for (const auto& preserved : {path, result.backupPath}) {
    std::string copiedAttribute(attribute.size(), '\0');
    EXPECT(test, ::getxattr(preserved.c_str(), "com.sakura.grep-test", copiedAttribute.data(),
                           copiedAttribute.size(), 0, 0) == static_cast<ssize_t>(attribute.size()));
    EXPECT(test, copiedAttribute == attribute);
  }
  EXPECT(test, fs::is_symlink(directory.path / "document.txt.bak.2"));
  EXPECT(test, entries(directory.path) == 5);
}

void rejectsChangedContentAndReplacedIdentity() {
  constexpr auto test = "rejectsChangedContentAndReplacedIdentity";
  TemporaryDirectory directory;
  const auto path = directory.path / "document.txt";
  write(path, "original");
  const auto preview = readGrepFileSnapshot(path);
  if (!preview.snapshot) { EXPECT(test, false); return; }
  write(path, "external");
  auto result = commitGrepReplacement(*preview.snapshot, bytes("changed"));
  EXPECT(test, result.status == GrepCommitStatus::conflict);
  EXPECT(test, read(path) == "external");
  EXPECT(test, entries(directory.path) == 1);
  write(path, "original");
  const auto secondPreview = readGrepFileSnapshot(path);
  if (!secondPreview.snapshot) { EXPECT(test, false); return; }
  const auto replacement = directory.path / "new-file";
  write(replacement, "original");
  fs::rename(replacement, path);
  result = commitGrepReplacement(*secondPreview.snapshot, bytes("changed"));
  EXPECT(test, result.status == GrepCommitStatus::conflict);
  EXPECT(test, read(path) == "original");
  EXPECT(test, entries(directory.path) == 1);
}

void rejectsChangesDuringStagingAndImmediatelyBeforeRename() {
  constexpr auto test = "rejectsChangesDuringStagingAndImmediatelyBeforeRename";
  TemporaryDirectory directory;
  const auto path = directory.path / "document.txt";
  write(path, "original");
  auto preview = readGrepFileSnapshot(path);
  if (!preview.snapshot) { EXPECT(test, false); return; }
  GrepCommitOptions options;
  options.afterStaging = [&] { write(path, "external staging update"); };
  auto result = commitGrepReplacement(*preview.snapshot, bytes("changed"), options);
  EXPECT(test, result.status == GrepCommitStatus::conflict);
  EXPECT(test, read(path) == "external staging update");
  EXPECT(test, entries(directory.path) == 1);

  preview = readGrepFileSnapshot(path);
  if (!preview.snapshot) { EXPECT(test, false); return; }
  int checks = 0;
  options.afterStaging = {};
  options.beforeCommit = [&] {
    if (++checks == 2) write(path, "external last-moment update");
    return true;
  };
  result = commitGrepReplacement(*preview.snapshot, bytes("changed"), options);
  EXPECT(test, checks == 2);
  EXPECT(test, result.status == GrepCommitStatus::conflict);
  EXPECT(test, read(path) == "external last-moment update");
  EXPECT(test, entries(directory.path) == 1);
}

void cancellationAndGateLeaveOriginalUntouched() {
  constexpr auto test = "cancellationAndGateLeaveOriginalUntouched";
  TemporaryDirectory directory;
  const auto path = directory.path / "document.txt";
  write(path, "original");
  const auto preview = readGrepFileSnapshot(path);
  if (!preview.snapshot) { EXPECT(test, false); return; }
  bool cancel = true;
  GrepCommitOptions options;
  options.cancelled = [&] { return cancel; };
  EXPECT(test, commitGrepReplacement(*preview.snapshot, bytes("changed"), options).status ==
                   GrepCommitStatus::cancelled);
  cancel = false;
  options.afterStaging = [&] { cancel = true; };
  EXPECT(test, commitGrepReplacement(*preview.snapshot, bytes("changed"), options).status ==
                   GrepCommitStatus::cancelled);
  cancel = false;
  options.afterStaging = {};
  int checks = 0;
  options.beforeCommit = [&] { if (++checks == 2) cancel = true; return true; };
  EXPECT(test, commitGrepReplacement(*preview.snapshot, bytes("changed"), options).status ==
                   GrepCommitStatus::cancelled);
  cancel = false;
  options.beforeCommit = [] { return false; };
  EXPECT(test, commitGrepReplacement(*preview.snapshot, bytes("changed"), options).status ==
                   GrepCommitStatus::conflict);
  EXPECT(test, read(path) == "original");
  EXPECT(test, entries(directory.path) == 1);
}

void refusesSymlinksSpecialFilesAndLinkSubstitution() {
  constexpr auto test = "refusesSymlinksSpecialFilesAndLinkSubstitution";
  TemporaryDirectory directory;
  const auto path = directory.path / "document.txt";
  const auto other = directory.path / "other.txt";
  write(other, "do not touch");
  fs::create_symlink(other, path);
  EXPECT(test, !readGrepFileSnapshot(path).snapshot.has_value());
  fs::remove(path);
  ::mkfifo(path.c_str(), 0600);
  EXPECT(test, !readGrepFileSnapshot(path).snapshot.has_value());
  fs::remove(path);
  write(path, "original");
  const auto preview = readGrepFileSnapshot(path);
  if (!preview.snapshot) { EXPECT(test, false); return; }
  GrepCommitOptions options;
  options.afterStaging = [&] { fs::remove(path); fs::create_symlink(other, path); };
  const auto result = commitGrepReplacement(*preview.snapshot, bytes("changed"), options);
  EXPECT(test, result.status == GrepCommitStatus::conflict);
  EXPECT(test, fs::is_symlink(path));
  EXPECT(test, read(other) == "do not touch");
  EXPECT(test, entries(directory.path) == 2);
}

void limitsSnapshotsAndRecognizesNumberedBackups() {
  constexpr auto test = "limitsSnapshotsAndRecognizesNumberedBackups";
  TemporaryDirectory directory;
  const auto path = directory.path / "document.txt";
  write(path, "original");
  EXPECT(test, !readGrepFileSnapshot(path, 3).snapshot.has_value());
  EXPECT(test, isGrepBackupPath("file.txt.bak"));
  EXPECT(test, isGrepBackupPath("file.txt.bak.1"));
  EXPECT(test, isGrepBackupPath("file.txt.BAK.123"));
  EXPECT(test, !isGrepBackupPath("file.txt.bakup"));
  EXPECT(test, !isGrepBackupPath("file.txt.bak."));
  EXPECT(test, !isGrepBackupPath("file.txt.bak.notes"));
  EXPECT(test, !isGrepBackupPath("document.txt"));
}

void refusesReadOnlyReplacementWithoutCreatingArtifacts() {
  constexpr auto test = "refusesReadOnlyReplacementWithoutCreatingArtifacts";
  TemporaryDirectory directory;
  const auto path = directory.path / "document.txt";
  write(path, "original");
  ::chmod(path.c_str(), 0444);
  const auto preview = readGrepFileSnapshot(path);
  if (!preview.snapshot) { EXPECT(test, false); return; }
  const auto result = commitGrepReplacement(*preview.snapshot, bytes("changed"));
  EXPECT(test, result.status == GrepCommitStatus::error);
  EXPECT(test, read(path) == "original");
  EXPECT(test, entries(directory.path) == 1);
  ::chmod(path.c_str(), 0600);
}

void supportsExplicitlyDisabledBackups() {
  constexpr auto test = "supportsExplicitlyDisabledBackups";
  TemporaryDirectory directory;
  const auto path = directory.path / "document.txt";
  write(path, "original");
  const auto preview = readGrepFileSnapshot(path);
  if (!preview.snapshot) { EXPECT(test, false); return; }
  GrepCommitOptions options;
  options.createBackup = false;
  const auto result = commitGrepReplacement(*preview.snapshot, bytes("changed"), options);
  EXPECT(test, result.status == GrepCommitStatus::written);
  EXPECT(test, result.backupPath.empty());
  EXPECT(test, read(path) == "changed");
  EXPECT(test, entries(directory.path) == 1);
}
void reportsSynchronizationFailuresAtTheirCommitBoundary() {
  constexpr auto test = "reportsSynchronizationFailuresAtTheirCommitBoundary";
  for (auto stage : {GrepSyncStage::fileBeforeRename, GrepSyncStage::directoryAfterRename, GrepSyncStage::fileAfterRename}) {
    TemporaryDirectory directory;
    const auto path = directory.path / "document.txt";
    write(path, "original");
    auto preview = readGrepFileSnapshot(path);
    if (!preview.snapshot) { EXPECT(test, false); continue; }
    GrepCommitOptions options;
    options.beforeSync = [stage](GrepSyncStage current) { return current != stage; };
    const auto result = commitGrepReplacement(*preview.snapshot, bytes("changed"), options);
    const bool committed = stage != GrepSyncStage::fileBeforeRename;
    EXPECT(test, result.status == (committed ? GrepCommitStatus::writtenNotDurable : GrepCommitStatus::error));
    EXPECT(test, !result.error.empty());
    EXPECT(test, read(path) == (committed ? "changed" : "original"));
    EXPECT(test, entries(directory.path) == (committed ? 2 : 1));
    if (committed) {
      EXPECT(test, read(result.backupPath) == "original");
      EXPECT(test, result.error.find("applied") != std::string::npos);
    }
  }
}
}  // namespace

int main() {
  writesSnapshotBackupAndPreservesMode();
  rejectsChangedContentAndReplacedIdentity();
  rejectsChangesDuringStagingAndImmediatelyBeforeRename();
  cancellationAndGateLeaveOriginalUntouched();
  refusesSymlinksSpecialFilesAndLinkSubstitution();
  limitsSnapshotsAndRecognizesNumberedBackups();
  refusesReadOnlyReplacementWithoutCreatingArtifacts();
  supportsExplicitlyDisabledBackups();
  reportsSynchronizationFailuresAtTheirCommitBoundary();
  if (failures) {
    std::cerr << failures << " Grep transaction assertion(s) failed\n";
    return 1;
  }
  std::cout << "All Grep file transaction tests passed\n";
  return 0;
}
