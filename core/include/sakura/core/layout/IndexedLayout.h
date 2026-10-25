// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#ifndef SAKURA_CORE_LAYOUT_INDEXED_LAYOUT_H_
#define SAKURA_CORE_LAYOUT_INDEXED_LAYOUT_H_

#include <memory>
#include <optional>
#include "sakura/core/layout/LayoutEngine.h"

namespace sakura::core {
namespace detail { struct LayoutTreeNode; }

struct IndexedLayoutRow { VisualLine visual; TextRange range; };
struct LayoutUpdateStatistics {
  std::size_t measuredLines{};
  std::size_t comparedTextNodes{};
  bool fullRebuild{};
};

// Immutable, shareable blocks indexed by logical rows, visual rows and UTF-16
// length. Local edits replace only their line interval; following offsets and
// logical numbers are computed from subtree sums rather than rewritten.
class IndexedLayout {
 public:
  IndexedLayout() = default;
  IndexedLayout(const IndexedLayout&) = default;
  IndexedLayout& operator=(const IndexedLayout&) = default;
  // Like TextBuffer, moved-from indexes remain valid shared snapshots.
  IndexedLayout(IndexedLayout&& other) noexcept : IndexedLayout(static_cast<const IndexedLayout&>(other)) {}
  IndexedLayout& operator=(IndexedLayout&& other) noexcept {
    return operator=(static_cast<const IndexedLayout&>(other));
  }
  // Increment metricsRevision when metrics behavior changes without a change
  // to FontStyle/options (for example a new font family or character spacing).
  // An adapter must not mutate metrics concurrently during update.
  void update(const TextBuffer& buffer, const ITextMetrics& metrics,
      const FontStyle& style, const LayoutOptions& options, std::uint64_t metricsRevision = 0,
      const std::function<bool()>& cancelled = {});
  [[nodiscard]] bool matchesText(const TextBuffer& buffer) const noexcept;
  [[nodiscard]] std::size_t size() const noexcept;
  [[nodiscard]] bool empty() const noexcept;
  [[nodiscard]] IndexedLayoutRow row(std::size_t index) const;
  [[nodiscard]] std::size_t visualLineFor(TextPosition position, std::size_t* visitedNodes = nullptr) const;
  // EOL code units belong to the preceding row; offsets past EOF clamp to EOF.
  [[nodiscard]] std::size_t visualLineForOffset(TextOffset offset, std::size_t* visitedNodes = nullptr) const;
  [[nodiscard]] float widestLine() const noexcept;
  [[nodiscard]] float lineHeight() const noexcept;
  [[nodiscard]] LayoutUpdateStatistics lastUpdate() const noexcept;
  struct StorageStatistics { std::size_t nodes; std::size_t logicalLines; unsigned height; bool valid; };
  [[nodiscard]] StorageStatistics storageStatistics() const;
 private:
  std::shared_ptr<const detail::LayoutTreeNode> root_;
  std::optional<TextBuffer> source_;
  FontStyle style_;
  LayoutOptions options_;
  std::uint64_t metricsRevision_{};
  float lineHeight_{};
  LayoutUpdateStatistics statistics_;
};
}  // namespace sakura::core
#endif
