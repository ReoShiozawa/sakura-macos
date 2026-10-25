// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#ifndef SAKURA_PLATFORM_MAC_GREP_FILE_TRANSACTION_H_
#define SAKURA_PLATFORM_MAC_GREP_FILE_TRANSACTION_H_

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace sakura::platform::mac {

struct GrepFileIdentity {
  std::uint64_t device = 0;
  std::uint64_t inode = 0;
  std::uint32_t mode = 0;
  std::int64_t size = 0;
  std::int64_t modificationSeconds = 0;
  std::int64_t modificationNanoseconds = 0;
  std::int64_t changeSeconds = 0;
  std::int64_t changeNanoseconds = 0;

  bool operator==(const GrepFileIdentity&) const = default;
};

struct GrepFileSnapshot {
  std::filesystem::path path;
  std::vector<std::byte> bytes;
  GrepFileIdentity identity;
  std::uint64_t parentDevice = 0;
  std::uint64_t parentInode = 0;
};

struct GrepSnapshotResult {
  std::optional<GrepFileSnapshot> snapshot;
  std::string error;
};

enum class GrepCommitStatus { written, writtenNotDurable, conflict, cancelled, error };
enum class GrepSyncStage { fileBeforeRename, directoryAfterRename, fileAfterRename };

struct GrepCommitOptions {
  bool createBackup = true;
  std::function<bool()> cancelled;
  // Rechecked after staging and immediately before the last file validation.
  // A false result prevents replacement (for example, a newly opened document).
  std::function<bool()> beforeCommit;
  // Deterministic race simulation for integration tests; normally left empty.
  std::function<void()> afterStaging;
  // Fault gate for deterministic synchronization-failure tests.
  std::function<bool(GrepSyncStage)> beforeSync;
};

struct GrepCommitResult {
  GrepCommitStatus status = GrepCommitStatus::error;
  std::filesystem::path backupPath;
  std::string error;
};

[[nodiscard]] GrepSnapshotResult readGrepFileSnapshot(
    const std::filesystem::path& path,
    std::size_t maximumBytes = 128U * 1024U * 1024U);

// Advisory locking and repeated identity/content validation protect cooperating
// writers and detect intervening changes. Noncooperating writers still have a
// narrow race between the final validation and atomic rename.
[[nodiscard]] GrepCommitResult commitGrepReplacement(
    const GrepFileSnapshot& snapshot, std::span<const std::byte> replacement,
    const GrepCommitOptions& options = {});

[[nodiscard]] bool isGrepBackupPath(const std::filesystem::path& path);

}  // namespace sakura::platform::mac

#endif  // SAKURA_PLATFORM_MAC_GREP_FILE_TRANSACTION_H_
