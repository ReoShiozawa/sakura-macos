// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#ifndef SAKURA_CORE_EDIT_EDIT_ENGINE_H_
#define SAKURA_CORE_EDIT_EDIT_ENGINE_H_

#include <cstdint>
#include <vector>

#include "sakura/core/text/TextBuffer.h"

namespace sakura::core {

struct EditReplacement {
  TextRange range;
  SakuraString text;
};

class EditEngine {
 public:
  explicit EditEngine(TextBuffer& buffer);
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

  [[nodiscard]] bool canUndo() const noexcept;
  [[nodiscard]] bool canRedo() const noexcept;
  bool undo();
  bool redo();
  void clearHistory() noexcept;
  [[nodiscard]] std::uint64_t stateId() const noexcept;

 private:
  struct EditAction {
    struct Change {
      TextOffset offset{};
      SakuraString before;
      SakuraString after;
    };

    std::vector<Change> changes;
    std::uint64_t beforeState{};
    std::uint64_t afterState{};
  };

  [[nodiscard]] static EditAction::Change prepareChange(
      const TextBuffer& buffer, TextRange range, SakuraStringView text);

  TextBuffer& buffer_;
  std::vector<EditAction> undoStack_;
  std::vector<EditAction> redoStack_;
  std::uint64_t stateId_{};
  std::uint64_t nextStateId_{1};
};

}  // namespace sakura::core

#endif  // SAKURA_CORE_EDIT_EDIT_ENGINE_H_
