// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#ifndef SAKURA_CORE_SYNTAX_SYNTAX_HIGHLIGHTER_H_
#define SAKURA_CORE_SYNTAX_SYNTAX_HIGHLIGHTER_H_

#include <vector>
#include <string_view>
#include <functional>

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
  std::uint8_t keywordGroup{1}; // 1..10; ignored for non-keyword tokens.
};

enum class SyntaxLanguage {
  plain, c, cpp, objectiveC, swift, java, csharp, javascript, typescript,
  python, json, shell, ruby, sql, html, xml, css, markdown, yaml, toml, ini, go, rust,
};

// Deterministic lexical foreground coloring. It never
// changes document text and deliberately emits no overlapping ranges.
// Cancellation is checked during serialization and scans, including inside
// long tokens. It throws std::runtime_error without publishing partial tokens.
class SyntaxHighlighter {
 public:
  [[nodiscard]] static SyntaxLanguage languageForExtension(std::string_view extension);
  [[nodiscard]] std::vector<SyntaxToken> highlight(
      const TextBuffer& buffer, SyntaxLanguage language,
      const std::function<bool()>& cancelled = {}) const;
  [[nodiscard]] std::vector<SyntaxToken> highlightCLike(
      const TextBuffer& buffer, const std::function<bool()>& cancelled = {}) const;
};

}  // namespace sakura::core

#endif  // SAKURA_CORE_SYNTAX_SYNTAX_HIGHLIGHTER_H_
