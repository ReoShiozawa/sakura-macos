// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include "sakura/core/text/TextBuffer.h"

#include <algorithm>
#include <iterator>
#include <limits>
#include <stdexcept>
#include <type_traits>

namespace sakura::core {
namespace {

constexpr bool isHighSurrogate(SakuraChar value) noexcept {
  return value >= u'\xD800' && value <= u'\xDBFF';
}

constexpr bool isLowSurrogate(SakuraChar value) noexcept {
  return value >= u'\xDC00' && value <= u'\xDFFF';
}

std::size_t checkedSize(TextOffset value) {
  if (value > std::numeric_limits<std::size_t>::max()) {
    throw std::length_error("text offset exceeds addressable memory");
  }
  return static_cast<std::size_t>(value);
}

TextOffset checkedEnd(TextRange range, TextOffset textLength) {
  if (range.location > textLength || range.length > textLength - range.location) {
    throw std::out_of_range("text range is outside the buffer");
  }
  return range.location + range.length;
}

constexpr std::size_t lowBit(std::size_t value) noexcept {
  return value & (~value + 1);
}

// Entries are supplied in line order, which builds a Fenwick index in O(n).
void appendLineLength(std::vector<TextOffset>& index, std::size_t line,
                      TextOffset length) noexcept {
  const auto node = line + 1;
  index[node] += length;
  const auto step = lowBit(node);
  if (step < index.size() - node) {
    index[node + step] += index[node];
  }
}

}  // namespace

TextBuffer::TextBuffer() {
  rebuild({});
}

TextBuffer::TextBuffer(SakuraStringView text) {
  rebuild(text);
}

void TextBuffer::assign(SakuraStringView text) {
  rebuild(text);
  ++revision_;
}

std::size_t TextBuffer::lineCount() const noexcept {
  return lines_.size();
}

const TextLine& TextBuffer::line(std::size_t index) const {
  return lines_.at(index);
}

TextOffset TextBuffer::length() const noexcept {
  return length_;
}

std::uint64_t TextBuffer::revision() const noexcept {
  return revision_;
}

SakuraString TextBuffer::text() const {
  SakuraString result;
  result.reserve(checkedSize(length_));
  for (const auto& current : lines_) {
    result.append(current.content);
    switch (current.ending) {
      case LineEnding::none:
        break;
      case LineEnding::lineFeed:
        result.push_back(u'\n');
        break;
      case LineEnding::carriageReturn:
        result.push_back(u'\r');
        break;
      case LineEnding::carriageReturnLineFeed:
        result.append(u"\r\n");
        break;
    }
  }
  return result;
}

SakuraString TextBuffer::slice(TextRange range) const {
  const auto rangeEnd = checkedEnd(range, length_);
  SakuraString result;
  result.reserve(checkedSize(range.length));

  auto cursor = range.location;
  while (cursor < rangeEnd) {
    const auto lineIndex = lineIndexAt(cursor);
    const auto& current = lines_[lineIndex];
    const auto relative = cursor - prefixLength(lineIndex);
    const auto serializedLength = current.content.size() + endingLength(current.ending);
    const auto available = std::min(rangeEnd - cursor, serializedLength - relative);

    const auto contentLength = static_cast<TextOffset>(current.content.size());
    if (relative < contentLength) {
      const auto contentCount = std::min(available, contentLength - relative);
      result.append(current.content, checkedSize(relative), checkedSize(contentCount));
    }

    const auto requestedEnd = relative + available;
    if (requestedEnd > contentLength) {
      const auto eolStart = relative > contentLength ? relative - contentLength : 0;
      const auto eolEnd = requestedEnd - contentLength;
      SakuraStringView eol;
      switch (current.ending) {
        case LineEnding::none:
          break;
        case LineEnding::lineFeed:
          eol = u"\n";
          break;
        case LineEnding::carriageReturn:
          eol = u"\r";
          break;
        case LineEnding::carriageReturnLineFeed:
          eol = u"\r\n";
          break;
      }
      result.append(eol.substr(checkedSize(eolStart), checkedSize(eolEnd - eolStart)));
    }
    cursor += available;
  }
  return result;
}

TextOffset TextBuffer::offsetAt(TextPosition position) const {
  const auto& current = line(position.line);
  if (position.column > current.content.size()) {
    throw std::out_of_range("text column is outside the logical line");
  }
  return prefixLength(position.line) + position.column;
}

TextPosition TextBuffer::positionAt(TextOffset offset) const {
  if (offset > length_) {
    throw std::out_of_range("text offset is outside the buffer");
  }
  const auto index = lineIndexAt(offset);
  const auto relative = offset - prefixLength(index);
  return {index, std::min(relative, static_cast<TextOffset>(lines_[index].content.size()))};
}

TextOffset TextBuffer::lineStartOffset(std::size_t index) const {
  if (index >= lines_.size()) {
    throw std::out_of_range("logical line is outside the buffer");
  }
  return prefixLength(index);
}

bool TextBuffer::isCodePointBoundary(TextOffset offset) const {
  if (offset > length_) {
    return false;
  }
  if (offset == 0 || offset == length_) {
    return true;
  }
  return !(isHighSurrogate(codeUnitAt(offset - 1)) && isLowSurrogate(codeUnitAt(offset)));
}

bool TextBuffer::isEditBoundary(TextOffset offset) const {
  const bool codePointBoundary = isCodePointBoundary(offset);
  if (!codePointBoundary || offset == 0 || offset == length_) {
    return codePointBoundary;
  }
  return !(codeUnitAt(offset - 1) == u'\r' && codeUnitAt(offset) == u'\n');
}

void TextBuffer::replace(TextRange range, SakuraStringView replacement) {
  const auto end = checkedEnd(range, length_);
  if (!isEditBoundary(range.location) || !isEditBoundary(end)) {
    throw std::invalid_argument("edit would split an indivisible text sequence");
  }

  if (replacement.size() > std::numeric_limits<TextOffset>::max() -
                               (length_ - range.length)) {
    throw std::length_error("replacement would exceed the text offset range");
  }

  const auto startPosition = positionAt(range.location);
  const auto endPosition = positionAt(end);
  const auto prefixLength = checkedSize(startPosition.column);
  const auto suffixStart = checkedSize(endPosition.column);
  const auto& startLine = lines_[startPosition.line];
  const auto& endLine = lines_[endPosition.line];
  const auto newLength = length_ - range.length + replacement.size();

  if (startPosition.line == endPosition.line &&
      replacement.find_first_of(u"\r\n") == SakuraStringView::npos) {
    const auto newContentLength = startLine.content.size() -
                                  checkedSize(range.length) + replacement.size();
    // Removing all content between a preceding CR and this line's LF creates
    // a CRLF pair. Such edits need the boundary-aware structural path below.
    const bool joinsCrLf = newContentLength == 0 && startPosition.line != 0 &&
        lines_[startPosition.line - 1].ending == LineEnding::carriageReturn &&
        startLine.ending == LineEnding::lineFeed;
    if (!joinsCrLf) {
      SakuraString changed;
      changed.reserve(newContentLength);
      changed.append(startLine.content, 0, prefixLength);
      changed.append(replacement);
      changed.append(endLine.content, suffixStart, SakuraString::npos);
      const auto before = startLine.content.size() + endingLength(startLine.ending);
      const auto after = changed.size() + endingLength(startLine.ending);
      lines_[startPosition.line].content.swap(changed);
      adjustLineLength(startPosition.line, before, after);
      length_ = newLength;
      ++revision_;
      return;
    }
  }

  // Include neighboring lines so newly adjacent CR + LF code units are
  // parsed as one ending, even when the edit itself does not contain a newline.
  const auto firstLine = startPosition.line == 0 ? 0 : startPosition.line - 1;
  const auto lastLine = std::min(endPosition.line + 1, lines_.size() - 1);
  const auto regionStart = this->prefixLength(firstLine);
  const auto regionEnd = lastLine + 1 < lines_.size()
      ? this->prefixLength(lastLine + 1) : length_;
  SakuraString changedText = slice({regionStart, range.location - regionStart});
  changedText.append(replacement);
  changedText.append(slice({end, regionEnd - end}));
  TextBuffer parsedReplacement(changedText);
  auto replacementLines = std::move(parsedReplacement.lines_);
  if (lastLine + 1 < lines_.size()) {
    // Parsing an ending creates a synthetic final empty line; the original
    // line following this region already supplies that logical line.
    replacementLines.pop_back();
  }

  const auto erasedLineCount = lastLine - firstLine + 1;
  const auto retainedLineCount = lines_.size() - erasedLineCount;
  if (replacementLines.size() > lines_.max_size() - retainedLineCount) {
    throw std::length_error("replacement would exceed the logical line range");
  }
  const auto finalLineCount = retainedLineCount + replacementLines.size();
  std::vector<TextOffset> newIndex(finalLineCount + 1, 0);
  TextOffset indexedLength = 0;
  for (std::size_t index = 0; index < finalLineCount; ++index) {
    const auto& current = index < firstLine ? lines_[index]
        : index < firstLine + replacementLines.size()
            ? replacementLines[index - firstLine]
            : lines_[index - replacementLines.size() + erasedLineCount];
    const auto size = current.content.size() + endingLength(current.ending);
    appendLineLength(newIndex, index, size);
    indexedLength += size;
  }
  if (indexedLength != newLength) {
    throw std::logic_error("replacement produced an inconsistent line index");
  }
  // All potentially throwing allocations finish before mutating line storage.
  lines_.reserve(finalLineCount);
  static_assert(std::is_nothrow_move_constructible_v<TextLine>);
  static_assert(std::is_nothrow_move_assignable_v<TextLine>);

  const auto insertionPoint = lines_.begin() + static_cast<std::ptrdiff_t>(firstLine);
  const auto afterErased = insertionPoint + static_cast<std::ptrdiff_t>(erasedLineCount);
  const auto next = lines_.erase(insertionPoint, afterErased);
  lines_.insert(next, std::make_move_iterator(replacementLines.begin()),
                std::make_move_iterator(replacementLines.end()));
  lineLengthIndex_.swap(newIndex);
  length_ = newLength;
  ++revision_;
}

void TextBuffer::rebuild(SakuraStringView text) {
  // Build into temporaries both for the strong exception guarantee and to
  // support views that alias the buffer's current line storage.
  std::vector<TextLine> newLines;

  std::size_t cursor = 0;
  while (cursor < text.size()) {
    const auto lineStart = cursor;
    while (cursor < text.size() && text[cursor] != u'\r' && text[cursor] != u'\n') {
      ++cursor;
    }

    LineEnding ending = LineEnding::none;
    if (cursor < text.size()) {
      if (text[cursor] == u'\r' && cursor + 1 < text.size() && text[cursor + 1] == u'\n') {
        ending = LineEnding::carriageReturnLineFeed;
      } else if (text[cursor] == u'\r') {
        ending = LineEnding::carriageReturn;
      } else {
        ending = LineEnding::lineFeed;
      }
    }

    newLines.push_back({SakuraString{text.substr(lineStart, cursor - lineStart)}, ending});
    cursor += checkedSize(endingLength(ending));

    if (cursor == text.size() && ending != LineEnding::none) {
      newLines.push_back({});
    }
  }

  if (newLines.empty()) {
    newLines.push_back({});
  }

  std::vector<TextOffset> newIndex(newLines.size() + 1, 0);
  for (std::size_t index = 0; index < newLines.size(); ++index) {
    appendLineLength(newIndex, index, newLines[index].content.size() +
                                      endingLength(newLines[index].ending));
  }

  lines_.swap(newLines);
  lineLengthIndex_.swap(newIndex);
  length_ = text.size();
}

TextOffset TextBuffer::prefixLength(std::size_t lineCount) const noexcept {
  TextOffset result = 0;
  for (auto node = lineCount; node != 0; node -= lowBit(node)) {
    result += lineLengthIndex_[node];
  }
  return result;
}

void TextBuffer::adjustLineLength(std::size_t line, TextOffset before,
                                  TextOffset after) noexcept {
  for (auto node = line + 1; node < lineLengthIndex_.size();) {
    if (after >= before) lineLengthIndex_[node] += after - before;
    else lineLengthIndex_[node] -= before - after;
    const auto step = lowBit(node);
    if (step >= lineLengthIndex_.size() - node) break;
    node += step;
  }
}

std::size_t TextBuffer::lineIndexAt(TextOffset offset) const {
  // Find the greatest prefix whose length is <= offset by binary lifting.
  // The final line can be empty; clamp the complete prefix to that final line.
  std::size_t line = 0;
  TextOffset consumed = 0;
  std::size_t step = 1;
  while (step <= lines_.size() / 2) step *= 2;
  for (; step != 0; step /= 2) {
    const auto next = line + step;
    if (next <= lines_.size() && lineLengthIndex_[next] <= offset - consumed) {
      consumed += lineLengthIndex_[next];
      line = next;
    }
  }
  return std::min(line, lines_.size() - 1);
}

SakuraChar TextBuffer::codeUnitAt(TextOffset offset) const {
  if (offset >= length_) {
    throw std::out_of_range("text offset does not identify a code unit");
  }
  const auto index = lineIndexAt(offset);
  const auto& current = lines_[index];
  const auto relative = offset - prefixLength(index);
  if (relative < current.content.size()) {
    return current.content[checkedSize(relative)];
  }

  const auto eolIndex = relative - current.content.size();
  switch (current.ending) {
    case LineEnding::lineFeed:
      return u'\n';
    case LineEnding::carriageReturn:
      return u'\r';
    case LineEnding::carriageReturnLineFeed:
      return eolIndex == 0 ? u'\r' : u'\n';
    case LineEnding::none:
      break;
  }
  throw std::out_of_range("text offset is outside the serialized line");
}

TextOffset TextBuffer::endingLength(LineEnding ending) noexcept {
  switch (ending) {
    case LineEnding::none:
      return 0;
    case LineEnding::lineFeed:
    case LineEnding::carriageReturn:
      return 1;
    case LineEnding::carriageReturnLineFeed:
      return 2;
  }
  return 0;
}

}  // namespace sakura::core
