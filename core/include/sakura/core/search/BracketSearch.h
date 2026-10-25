// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#ifndef SAKURA_CORE_SEARCH_BRACKET_SEARCH_H_
#define SAKURA_CORE_SEARCH_BRACKET_SEARCH_H_

#include <functional>
#include <optional>
#include <span>
#include <vector>
#include "sakura/core/text/TextBuffer.h"

namespace sakura::core {

struct BracketPair {
  SakuraChar opening{}, closing{};
  friend constexpr bool operator==(const BracketPair&, const BracketPair&) = default;
};

// The 18 pairs documented by upstream's "Bracket Pair" command, including
// halfwidth Japanese brackets, fullwidth forms and asymmetric curly quotes.
[[nodiscard]] std::span<const BracketPair> defaultBracketPairs() noexcept;

struct BracketSearchStatistics {
  TextOffset scannedCodeUnits{}, copiedCodeUnits{};
  std::size_t chunkLoads{}, peakChunkCodeUnits{};
};

struct BracketSearchOptions {
  // Empty uses defaultBracketPairs(). Custom pairs must be unambiguous,
  // asymmetric BMP characters, excluding surrogate code units and CR/LF.
  std::vector<BracketPair> pairs;
  bool inspectPrevious{true};
  // UTF-16 units examined after/before the source bracket, target included.
  // Zero means unlimited. Prefetch may read a bounded window beyond this cap.
  TextOffset maxScanCodeUnits{};
  std::function<bool()> cancelled;
  // Optional diagnostics. One request writes this object; do not share it
  // between concurrent calls. It is reset even when a request fails.
  BracketSearchStatistics* statistics{};
};

struct BracketMatch {
  TextRange source, target;
  bool fromPrevious{}, forward{};
  TextOffset scannedCodeUnits{};
  friend constexpr bool operator==(const BracketMatch&, const BracketMatch&) = default;
};

// Uses the character at caret first. Only when it is not a configured bracket
// may the preceding character on that logical line be used. An unmatched right
// bracket never falls back to a left bracket. Nesting counts only that pair;
// other bracket types, comments, strings and escapes are ordinary text, matching
// upstream's command (this is not a language-aware parse or automatic highlight).
// Caller must pass a valid edit boundary. Cancellation/scan limits throw before
// returning any match; not-found returns nullopt and the source is never edited.
// Concurrent users should retain independent immutable TextBuffer snapshots.
[[nodiscard]] std::optional<BracketMatch> findBracketPair(
    const TextBuffer& buffer, TextOffset caret,
    const BracketSearchOptions& options = {});

} // namespace sakura::core
#endif
