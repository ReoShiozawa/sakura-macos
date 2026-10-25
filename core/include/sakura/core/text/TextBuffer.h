// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#ifndef SAKURA_CORE_TEXT_TEXT_BUFFER_H_
#define SAKURA_CORE_TEXT_TEXT_BUFFER_H_

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <span>
#include <vector>

#include "sakura/core/text/Types.h"

namespace sakura::core {

enum class LineEnding : std::uint8_t {
  none,
  lineFeed,
  carriageReturn,
  carriageReturnLineFeed,
};

struct TextLine {
  SakuraString content;
  LineEnding ending{LineEnding::none};
};

// One enclosing line interval; unchanged shared subtrees outside it are skipped.
// Offsets include line endings, so CRLF joins and structural edits are covered.
struct TextLineChange {
  std::size_t firstLine{};
  std::size_t oldLineCount{};
  std::size_t newLineCount{};
  TextRange oldText;
  TextRange newText;
  std::size_t comparedNodes{};
};

namespace detail { struct LineTreeNode; }

// Linear in-order traversal without repeated O(log N) indexed lookups. The
// cursor owns an immutable root, so editing its source cannot invalidate it.
class TextLineCursor {
 public:
  explicit operator bool() const noexcept;
  [[nodiscard]] const TextLine& line() const;
  void advance() noexcept;
 private:
  friend class TextBuffer;
  TextLineCursor(std::shared_ptr<const detail::LineTreeNode> root, std::size_t first);
  std::shared_ptr<const detail::LineTreeNode> root_;
  std::vector<const detail::LineTreeNode*> path_;
};

// A portable, UTF-16 logical-line buffer.  Line endings are retained per line
// so a document containing a mixture of CRLF, LF, and CR round-trips exactly.
// Copies are O(1) immutable-root snapshots. Independent copies may be read on
// worker threads while the original is edited; one instance is not thread-safe.
class TextBuffer {
 public:
  TextBuffer();
  explicit TextBuffer(SakuraStringView text, const std::function<bool()>& cancelled = {});
  TextBuffer(const TextBuffer&) = default;
  TextBuffer& operator=(const TextBuffer&) = default;
  // Shared roots make it cheap to leave moved-from buffers fully usable too.
  TextBuffer(TextBuffer&& other) noexcept;
  TextBuffer& operator=(TextBuffer&& other) noexcept;

  void assign(SakuraStringView text, const std::function<bool()>& cancelled = {});
  // Publish a retained root as a new live revision (undo/redo/prepared edits).
  // Unlike copy assignment this never restores an old revision number.
  void restoreSnapshot(const TextBuffer& snapshot, std::uint64_t revisionSteps = 1) noexcept;
  [[nodiscard]] bool sharesStorageWith(const TextBuffer& other) const noexcept;

  [[nodiscard]] std::size_t lineCount() const noexcept;
  [[nodiscard]] const TextLine& line(std::size_t index) const;
  [[nodiscard]] TextLineCursor lineCursor(std::size_t first = 0) const;
  [[nodiscard]] TextOffset length() const noexcept;
  [[nodiscard]] std::uint64_t revision() const noexcept;
  [[nodiscard]] SakuraString text(const std::function<bool()>& cancelled = {}) const;
  struct StorageStatistics { std::size_t nodes; unsigned height; bool valid; };
  // Expensive invariant diagnostic for stress tests; not part of the edit path.
  [[nodiscard]] StorageStatistics storageStatistics() const;
  [[nodiscard]] SakuraString slice(TextRange range, const std::function<bool()>& cancelled = {}) const;
  [[nodiscard]] TextLineChange changesFrom(const TextBuffer& previous) const;
  [[nodiscard]] SakuraChar characterAt(TextOffset offset) const;
  void copyText(TextRange range, std::span<SakuraChar> destination) const;

  // Columns address line content only; line-ending code units are not valid
  // logical columns.  An absolute offset inside CRLF maps to end-of-line.
  [[nodiscard]] TextOffset offsetAt(TextPosition position) const;
  [[nodiscard]] TextPosition positionAt(TextOffset offset) const;
  [[nodiscard]] TextOffset lineStartOffset(std::size_t index) const;

  [[nodiscard]] bool isCodePointBoundary(TextOffset offset) const;
  [[nodiscard]] bool isEditBoundary(TextOffset offset) const;
  void replace(TextRange range, SakuraStringView replacement, const std::function<bool()>& cancelled = {});

 private:
  void rebuild(SakuraStringView text, const std::function<bool()>& cancelled = {});
  [[nodiscard]] TextOffset prefixLength(std::size_t lineCount) const noexcept;
  [[nodiscard]] std::size_t lineIndexAt(TextOffset offset) const;
  [[nodiscard]] SakuraChar codeUnitAt(TextOffset offset) const;
  [[nodiscard]] static TextOffset endingLength(LineEnding ending) noexcept;

  // Persistent AVL sequence, indexed by logical-line count and UTF-16 length.
  // Both ordinary and structural edits share all unaffected text/subtrees.
  std::shared_ptr<const detail::LineTreeNode> root_;
  TextOffset length_{};
  std::uint64_t revision_{};
};

}  // namespace sakura::core

#endif  // SAKURA_CORE_TEXT_TEXT_BUFFER_H_
