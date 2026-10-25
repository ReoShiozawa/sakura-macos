// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#ifndef SAKURA_CORE_EDIT_EDIT_ENGINE_H_
#define SAKURA_CORE_EDIT_EDIT_ENGINE_H_

#include <cstdint>
#include <vector>
#include <utility>

#include "sakura/core/text/TextBuffer.h"

namespace sakura::core {

struct EditReplacement {
  TextRange range;
  SakuraString text;
};

class EditEngine {
  struct EditAction;
  struct HistoryNode;
 public:
  explicit EditEngine(TextBuffer& buffer);
  ~EditEngine();
  EditEngine(const EditEngine&) = delete;
  EditEngine& operator=(const EditEngine&) = delete;
  EditEngine(EditEngine&&) = delete;
  EditEngine& operator=(EditEngine&&) = delete;

  void insert(TextOffset offset, SakuraStringView text);
  void erase(TextRange range);
  void replace(TextRange range, SakuraStringView text);

  // Applies replacements in the order supplied as one undoable action. Each
  // range addresses the buffer state produced by the preceding replacement.
  void replaceMany(const std::vector<EditReplacement>& replacements);

  class Snapshot {
   public:
    [[nodiscard]] const TextBuffer& buffer() const noexcept { return buffer_; }
   private:
    friend class EditEngine;
    Snapshot(const TextBuffer& buffer, std::shared_ptr<const char> owner, std::uint64_t state)
        : buffer_(buffer), owner_(std::move(owner)), state_(state) {}
    TextBuffer buffer_;
    std::shared_ptr<const char> owner_;
    std::uint64_t state_;
  };
  class PreparedEdit {
   public:
    PreparedEdit() noexcept;
    ~PreparedEdit();
    PreparedEdit(PreparedEdit&&) noexcept;
    PreparedEdit& operator=(PreparedEdit&&) noexcept;
    PreparedEdit(const PreparedEdit&) = delete;
    PreparedEdit& operator=(const PreparedEdit&) = delete;
    [[nodiscard]] bool hasChanges() const noexcept;
    [[nodiscard]] const TextBuffer& resultingBuffer() const;
   private:
    friend class EditEngine;
    struct Data;
    std::unique_ptr<Data> data_;
  };
  [[nodiscard]] Snapshot snapshot() const;
  // Worker-safe preparation against original, sorted, non-overlapping ranges.
  // Adjacent affected lines are grouped to avoid O(matches * line length).
  [[nodiscard]] static PreparedEdit prepareOriginalRanges(const Snapshot& source,
      const std::vector<EditReplacement>& replacements, const std::function<bool()>& cancelled = {});
  // One-shot, allocation-free publication; rejects edits/reloads/undo even if
  // text returns to the same value. Retired redo data remains in prepared, which
  // callers can destroy on a worker after committing on the owner thread.
  [[nodiscard]] bool commitPrepared(PreparedEdit& prepared) noexcept;

  enum class HistoryDirection { undo, redo };
  // Capture on the owner thread, then freely copy/read on workers. The pimpl
  // retains both immutable history heads and releases long chains iteratively,
  // including when the snapshot is the final owner after its engine has died.
  class HistorySnapshot {
   public:
    HistorySnapshot() noexcept = default;
    [[nodiscard]] const TextBuffer& buffer() const;
    [[nodiscard]] bool canUndo() const noexcept;
    [[nodiscard]] bool canRedo() const noexcept;
   private:
    friend class EditEngine;
    struct Data;
    std::shared_ptr<const Data> data_;
  };
  class PreparedHistory {
   public:
    PreparedHistory() noexcept;
    ~PreparedHistory();
    PreparedHistory(PreparedHistory&&) noexcept;
    PreparedHistory& operator=(PreparedHistory&&) noexcept;
    PreparedHistory(const PreparedHistory&) = delete;
    PreparedHistory& operator=(const PreparedHistory&) = delete;
    [[nodiscard]] bool hasChanges() const noexcept;
    [[nodiscard]] const TextBuffer& resultingBuffer() const;
   private:
    friend class EditEngine;
    struct Data;
    std::unique_ptr<Data> data_;
  };
  [[nodiscard]] HistorySnapshot historySnapshot() const;
  // Preparation does not modify either source stack. resultingBuffer() has
  // exactly the root AND revision that a successful owner-thread commit will
  // publish, so dependent layouts can also be prepared before publication.
  [[nodiscard]] static PreparedHistory prepareHistory(const HistorySnapshot& source,
      HistoryDirection direction, const std::function<bool()>& cancelled = {});
  // One-shot allocation-free publication. Even an empty-history no-op plan
  // authenticates owner/state/root/revision/both heads. Retained old roots and
  // history stay in the plan for callers to dispose on a worker after commit.
  [[nodiscard]] bool commitPreparedHistory(PreparedHistory& prepared) noexcept;

  [[nodiscard]] bool canUndo() const noexcept;
  [[nodiscard]] bool canRedo() const noexcept;
  bool undo();
  bool redo();
  void clearHistory() noexcept;
  [[nodiscard]] std::uint64_t stateId() const noexcept;

 private:
  static void releaseHistory(std::shared_ptr<const HistoryNode>& head) noexcept;
  [[nodiscard]] bool ownsCurrentVersion() const noexcept;
  [[nodiscard]] PreparedEdit prepareSequential(const std::vector<EditReplacement>& replacements) const;
  [[nodiscard]] static PreparedEdit makePrepared(const Snapshot& source, TextBuffer candidate, bool changed);

  TextBuffer& buffer_;
  // Direct writes through the caller-owned buffer invalidate history until an
  // explicit clearHistory; snapshot undo must never erase untracked edits.
  TextBuffer currentVersion_;
  std::shared_ptr<const HistoryNode> undoStack_, redoStack_;
  std::shared_ptr<const char> owner_;
  std::uint64_t stateId_{};
  std::uint64_t nextStateId_{1};
};

}  // namespace sakura::core

#endif  // SAKURA_CORE_EDIT_EDIT_ENGINE_H_
