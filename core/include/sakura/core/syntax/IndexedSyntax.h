// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#pragma once
#include "sakura/core/syntax/SyntaxHighlighter.h"
#include <optional>

namespace sakura::core {
namespace detail { struct SyntaxTreeNode; }
struct SyntaxUpdateStatistics {
  TextOffset parsedUnits{}, serializedUnits{}, reusedUnits{};
  std::size_t rebuiltBlocks{}, comparedTextNodes{}, attempts{};
  bool fullRebuild{};
};
// Persistent token blocks. Checkpoint state and forward-read dependencies are
// retained, so a future edit can invalidate earlier failed lookahead searches.
// Relative block offsets avoid rewriting all following tokens after an edit.
// Independent copies may be updated concurrently; one instance must not be
// mutated concurrently with reads/updates to that same instance.
class IndexedSyntax {
 public:
  IndexedSyntax() = default;
  IndexedSyntax(const IndexedSyntax&) = default;
  IndexedSyntax& operator=(const IndexedSyntax&) = default;
  IndexedSyntax(IndexedSyntax&& other) noexcept : IndexedSyntax(static_cast<const IndexedSyntax&>(other)) {}
  IndexedSyntax& operator=(IndexedSyntax&& other) noexcept { return operator=(static_cast<const IndexedSyntax&>(other)); }
  void update(const TextBuffer& source, SyntaxLanguage language,
      const std::function<bool()>& cancelled = {});
  [[nodiscard]] bool matchesText(const TextBuffer& source) const noexcept;
  [[nodiscard]] std::size_t tokenCount() const noexcept;
  // Tokens overlapping a nonempty UTF-16 range; ranges remain unclipped.
  [[nodiscard]] std::vector<SyntaxToken> tokensIn(TextRange range,
      const std::function<bool()>& cancelled = {}) const;
  [[nodiscard]] std::vector<SyntaxToken> tokens(const std::function<bool()>& cancelled = {}) const;
  [[nodiscard]] SyntaxUpdateStatistics lastUpdate() const noexcept { return statistics_; }
  struct StorageStatistics { std::size_t blocks; unsigned height; bool valid; };
  [[nodiscard]] StorageStatistics storageStatistics() const;
 private:
  std::shared_ptr<const detail::SyntaxTreeNode> root_;
  std::optional<TextBuffer> source_;
  SyntaxLanguage language_{SyntaxLanguage::plain};
  SyntaxUpdateStatistics statistics_;
};
}  // namespace sakura::core
