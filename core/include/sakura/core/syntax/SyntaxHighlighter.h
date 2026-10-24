// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#ifndef SAKURA_CORE_SYNTAX_SYNTAX_HIGHLIGHTER_H_
#define SAKURA_CORE_SYNTAX_SYNTAX_HIGHLIGHTER_H_

#include <vector>

#include "sakura/core/text/TextBuffer.h"

namespace sakura::core {

enum class SyntaxTokenKind {
  comment,
  string,
  keyword,
  number,
  preprocessor,
};

struct SyntaxToken {
  TextRange range;
  SyntaxTokenKind kind;
};

// Small, deterministic C-family lexer for foreground coloring. It never
// changes document text and deliberately emits no overlapping ranges.
class SyntaxHighlighter {
 public:
  [[nodiscard]] std::vector<SyntaxToken> highlightCLike(
      const TextBuffer& buffer) const;
};

}  // namespace sakura::core

#endif  // SAKURA_CORE_SYNTAX_SYNTAX_HIGHLIGHTER_H_
