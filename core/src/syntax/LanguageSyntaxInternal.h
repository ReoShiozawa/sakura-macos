// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#pragma once
#include "sakura/core/syntax/SyntaxHighlighter.h"
#include "SyntaxScan.h"

namespace sakura::core::detail {
// Checkpoints exist only at a logical line boundary in the outer lexer, never
// inside a consumed token. All outer-lexer state must be represented here.
struct SyntaxState {
  bool lineStart{true}, tag{}, name{}, closingTag{};
  SyntaxLanguage raw{SyntaxLanguage::plain};
  bool operator==(const SyntaxState&) const = default;
};
struct SyntaxScanStopped {};
struct SyntaxDriver {
  std::size_t nextBoundary{4096};
  SyntaxState finalState;
  std::function<bool(std::size_t, SyntaxState, std::size_t, std::vector<SyntaxToken>&)> boundary;
  void at(std::size_t i, SyntaxState state, SyntaxText text, SyntaxProbe& probe, std::vector<SyntaxToken>& tokens) {
    if (i < nextBoundary || i == 0) return;
    const auto previous = text[i - 1];
    if (previous != u'\r' && previous != u'\n') return;
    if (previous == u'\r' && text[i] == u'\n') return; // never split CRLF
    if (boundary(i, state, probe.dependencyEnd, tokens)) throw SyntaxScanStopped{};
    probe.dependencyEnd = i;
  }
};
struct SyntaxScanOptions {
  std::size_t total{SakuraStringView::npos}, origin{};
  SyntaxState initial;
  SyntaxDriver* driver{};
};
std::vector<SyntaxToken> scanLanguageSyntax(SakuraStringView source, SyntaxLanguage language,
    SyntaxProbe& probe, SyntaxScanOptions options);
}  // namespace sakura::core::detail
