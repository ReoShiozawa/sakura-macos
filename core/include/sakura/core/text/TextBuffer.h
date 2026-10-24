// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#ifndef SAKURA_CORE_TEXT_TEXT_BUFFER_H_
#define SAKURA_CORE_TEXT_TEXT_BUFFER_H_

#include <cstddef>
#include <cstdint>
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

// A portable, UTF-16 logical-line buffer.  Line endings are retained per line
// so a document containing a mixture of CRLF, LF, and CR round-trips exactly.
class TextBuffer {
 public:
  TextBuffer();
  explicit TextBuffer(SakuraStringView text);

  void assign(SakuraStringView text);

  [[nodiscard]] std::size_t lineCount() const noexcept;
  [[nodiscard]] const TextLine& line(std::size_t index) const;
  [[nodiscard]] TextOffset length() const noexcept;
  [[nodiscard]] std::uint64_t revision() const noexcept;
  [[nodiscard]] SakuraString text() const;
  [[nodiscard]] SakuraString slice(TextRange range) const;

  // Columns address line content only; line-ending code units are not valid
  // logical columns.  An absolute offset inside CRLF maps to end-of-line.
  [[nodiscard]] TextOffset offsetAt(TextPosition position) const;
  [[nodiscard]] TextPosition positionAt(TextOffset offset) const;
  [[nodiscard]] TextOffset lineStartOffset(std::size_t index) const;

  [[nodiscard]] bool isCodePointBoundary(TextOffset offset) const;
  [[nodiscard]] bool isEditBoundary(TextOffset offset) const;
  void replace(TextRange range, SakuraStringView replacement);

 private:
  void rebuild(SakuraStringView text);
  [[nodiscard]] TextOffset prefixLength(std::size_t lineCount) const noexcept;
  void adjustLineLength(std::size_t line, TextOffset before,
                        TextOffset after) noexcept;
  [[nodiscard]] std::size_t lineIndexAt(TextOffset offset) const;
  [[nodiscard]] SakuraChar codeUnitAt(TextOffset offset) const;
  [[nodiscard]] static TextOffset endingLength(LineEnding ending) noexcept;

  std::vector<TextLine> lines_;
  // A one-based Fenwick index of serialized line lengths. Ordinary character
  // edits update one entry instead of rewriting every following line offset.
  std::vector<TextOffset> lineLengthIndex_;
  TextOffset length_{};
  std::uint64_t revision_{};
};

}  // namespace sakura::core

#endif  // SAKURA_CORE_TEXT_TEXT_BUFFER_H_
