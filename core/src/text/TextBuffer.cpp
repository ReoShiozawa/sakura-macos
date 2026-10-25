// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include "sakura/core/text/TextBuffer.h"
#include <algorithm>
#include <limits>
#include <stdexcept>
#include <utility>
#include <vector>

namespace sakura::core {
namespace detail {
struct LineTreeNode {
  std::shared_ptr<const TextLine> line;
  std::shared_ptr<const LineTreeNode> left, right;
  std::size_t rows;
  TextOffset units;
  unsigned height;
};
}
namespace {
using Node = std::shared_ptr<const detail::LineTreeNode>;
using Line = std::shared_ptr<const TextLine>;
std::size_t rows(const Node& node) noexcept { return node ? node->rows : 0; }
TextOffset units(const Node& node) noexcept { return node ? node->units : 0; }
unsigned height(const Node& node) noexcept { return node ? node->height : 0; }
TextOffset eolLength(LineEnding ending) noexcept {
  return ending == LineEnding::none ? 0 : ending == LineEnding::carriageReturnLineFeed ? 2 : 1;
}
Node makeNode(Line line, Node left = {}, Node right = {}) {
  const auto lineUnits = line->content.size() + eolLength(line->ending);
  if (rows(right) == std::numeric_limits<std::size_t>::max() ||
      rows(left) > std::numeric_limits<std::size_t>::max() - rows(right) - 1)
    throw std::length_error("logical line count overflow");
  if (lineUnits > std::numeric_limits<TextOffset>::max() - units(right) ||
      units(left) > std::numeric_limits<TextOffset>::max() - units(right) - lineUnits)
    throw std::length_error("serialized text length overflow");
  const auto totalRows = rows(left) + rows(right) + 1;
  const auto totalUnits = units(left) + lineUnits + units(right);
  const auto totalHeight = 1 + std::max(height(left), height(right));
  return std::make_shared<const detail::LineTreeNode>(detail::LineTreeNode{
      std::move(line), std::move(left), std::move(right), totalRows, totalUnits, totalHeight});
}
Node balance(Line line, Node left, Node right) {
  if (height(left) > height(right) + 1) {
    if (height(left->left) >= height(left->right))
      return makeNode(left->line, left->left, makeNode(std::move(line), left->right, std::move(right)));
    auto pivot = left->right;
    return makeNode(pivot->line, makeNode(left->line, left->left, pivot->left),
        makeNode(std::move(line), pivot->right, std::move(right)));
  }
  if (height(right) > height(left) + 1) {
    if (height(right->right) >= height(right->left))
      return makeNode(right->line, makeNode(std::move(line), std::move(left), right->left), right->right);
    auto pivot = right->left;
    return makeNode(pivot->line, makeNode(std::move(line), std::move(left), pivot->left),
        makeNode(right->line, pivot->right, right->right));
  }
  return makeNode(std::move(line), std::move(left), std::move(right));
}
Node join(Node left, Line middle, Node right) {
  if (height(left) > height(right) + 1)
    return balance(left->line, left->left, join(left->right, std::move(middle), std::move(right)));
  if (height(right) > height(left) + 1)
    return balance(right->line, join(std::move(left), std::move(middle), right->left), right->right);
  return makeNode(std::move(middle), std::move(left), std::move(right));
}
std::pair<Node, Node> split(const Node& node, std::size_t count) {
  if (!node) return {};
  if (count == 0) return {{}, node};
  if (count >= rows(node)) return {node, {}};
  const auto leftRows = rows(node->left);
  if (count <= leftRows) {
    auto [prefix, remainder] = split(node->left, count);
    return {std::move(prefix), join(std::move(remainder), node->line, node->right)};
  }
  auto [prefix, remainder] = split(node->right, count - leftRows - 1);
  return {join(node->left, node->line, std::move(prefix)), std::move(remainder)};
}
std::pair<Line, Node> takeFirst(const Node& node) {
  if (!node->left) return {node->line, node->right};
  auto [first, remainder] = takeFirst(node->left);
  return {std::move(first), balance(node->line, std::move(remainder), node->right)};
}
Node concatenate(Node left, Node right) {
  if (!left) return right;
  if (!right) return left;
  auto [first, remainder] = takeFirst(right);
  return join(std::move(left), std::move(first), std::move(remainder));
}
const TextLine& lineAt(const Node& root, std::size_t index) {
  auto* node = root.get();
  if (index >= rows(root)) throw std::out_of_range("logical line is outside the buffer");
  while (true) {
    const auto leftRows = rows(node->left);
    if (index < leftRows) node = node->left.get();
    else if (index == leftRows) return *node->line;
    else { index -= leftRows + 1; node = node->right.get(); }
  }
}
Node replaceLine(const Node& node, std::size_t index, const Line& replacement) {
  const auto leftRows = rows(node->left);
  if (index < leftRows) return makeNode(node->line, replaceLine(node->left, index, replacement), node->right);
  if (index == leftRows) return makeNode(replacement, node->left, node->right);
  return makeNode(node->line, node->left, replaceLine(node->right, index - leftRows - 1, replacement));
}
void checkCancelled(const std::function<bool()>& cancelled) {
  if (cancelled && cancelled()) throw std::runtime_error("text operation cancelled");
}
void appendPart(SakuraString& target, SakuraStringView text, const std::function<bool()>& cancelled) {
  if (!cancelled) { target.append(text); return; }
  for (std::size_t offset = 0; offset < text.size(); offset += 65536) {
    checkCancelled(cancelled); target.append(text.substr(offset, std::min<std::size_t>(65536, text.size() - offset)));
  }
}
Node build(std::vector<TextLine>& lines, std::size_t begin, std::size_t end, const std::function<bool()>& cancelled = {}) {
  if (begin == end) return {};
  checkCancelled(cancelled);
  auto middle = begin + (end - begin) / 2;
  auto left = build(lines, begin, middle, cancelled), right = build(lines, middle + 1, end, cancelled);
  return makeNode(std::make_shared<const TextLine>(std::move(lines[middle])), std::move(left), std::move(right));
}
void appendLine(SakuraString& result, const TextLine& line, const std::function<bool()>& cancelled) {
  if (!cancelled) result.append(line.content);
  else {
    for (std::size_t offset = 0; offset < line.content.size(); offset += 65536) {
      if (cancelled()) throw std::runtime_error("text serialization cancelled");
      result.append(line.content, offset, std::min<std::size_t>(65536, line.content.size() - offset));
    }
  }
  switch (line.ending) {
    case LineEnding::none: break;
    case LineEnding::lineFeed: result.push_back(u'\n'); break;
    case LineEnding::carriageReturn: result.push_back(u'\r'); break;
    case LineEnding::carriageReturnLineFeed: result.append(u"\r\n"); break;
  }
}
void appendTree(SakuraString& result, const Node& node, const std::function<bool()>& cancelled) {
  if (!node) return;
  if (cancelled && cancelled()) throw std::runtime_error("text serialization cancelled");
  appendTree(result, node->left, cancelled); appendLine(result, *node->line, cancelled); appendTree(result, node->right, cancelled);
}
TextBuffer::StorageStatistics inspect(const Node& node) {
  if (!node) return {0, 0, true};
  const auto left = inspect(node->left), right = inspect(node->right);
  auto h = 1 + std::max(left.height, right.height);
  auto count = left.nodes + right.nodes + 1;
  bool valid = left.valid && right.valid && count == node->rows && h == node->height &&
      left.height <= right.height + 1 && right.height <= left.height + 1 &&
      node->units == units(node->left) + units(node->right) + node->line->content.size() + eolLength(node->line->ending);
  return {count, h, valid};
}
constexpr bool high(SakuraChar value) noexcept { return value >= u'\xD800' && value <= u'\xDBFF'; }
constexpr bool low(SakuraChar value) noexcept { return value >= u'\xDC00' && value <= u'\xDFFF'; }
std::size_t checkedSize(TextOffset value) {
  if (value > std::numeric_limits<std::size_t>::max()) throw std::length_error("text offset exceeds addressable memory");
  return static_cast<std::size_t>(value);
}
TextOffset checkedEnd(TextRange range, TextOffset length) {
  if (range.location > length || range.length > length - range.location) throw std::out_of_range("text range is outside the buffer");
  return range.location + range.length;
}

struct Segment { const detail::LineTreeNode* node; bool lineOnly{}; };
struct CommonLines { std::size_t count{}; TextOffset units{}; std::size_t compared{}; };
CommonLines commonLines(const Node& a, const Node& b, std::size_t limit, bool reverse) {
  CommonLines result;
  if (!a || !b || !limit) return result;
  std::vector<Segment> first{{a.get()}}, second{{b.get()}};
  const auto expand = [reverse](std::vector<Segment>& stack) {
    const auto* node = stack.back().node; stack.pop_back();
    const auto* before = reverse ? node->right.get() : node->left.get();
    const auto* after = reverse ? node->left.get() : node->right.get();
    if (after) stack.push_back({after});
    stack.push_back({node, true});
    if (before) stack.push_back({before});
  };
  while (!first.empty() && !second.empty() && result.count < limit) {
    ++result.compared;
    const auto x = first.back(), y = second.back();
    const auto xRows = x.lineOnly ? 1 : x.node->rows;
    const auto yRows = y.lineOnly ? 1 : y.node->rows;
    if (!x.lineOnly && !y.lineOnly && x.node == y.node && xRows <= limit - result.count) {
      result.count += xRows; result.units += x.node->units;
      first.pop_back(); second.pop_back(); continue;
    }
    if (xRows == 1 && yRows == 1) {
      if (x.node->line != y.node->line) break;
      ++result.count; result.units += x.node->line->content.size() + eolLength(x.node->line->ending);
      first.pop_back(); second.pop_back(); continue;
    }
    if (!x.lineOnly && (y.lineOnly || xRows >= yRows)) expand(first);
    else expand(second);
  }
  return result;
}
}
TextLineCursor::TextLineCursor(std::shared_ptr<const detail::LineTreeNode> root, std::size_t first)
    : root_(std::move(root)) {
  if (first > rows(root_)) throw std::out_of_range("cursor is outside the logical line range");
  path_.reserve(height(root_));
  if (first == rows(root_)) return;
  auto* node = root_.get();
  while (node) {
    auto leftRows = rows(node->left);
    if (first < leftRows) { path_.push_back(node); node = node->left.get(); }
    else if (first == leftRows) { path_.push_back(node); break; }
    else { first -= leftRows + 1; node = node->right.get(); }
  }
}
TextLineCursor::operator bool() const noexcept { return !path_.empty(); }
const TextLine& TextLineCursor::line() const {
  if (path_.empty()) throw std::out_of_range("cursor is at the end of the buffer");
  return *path_.back()->line;
}
void TextLineCursor::advance() noexcept {
  if (path_.empty()) return;
  auto* node = path_.back()->right.get(); path_.pop_back();
  while (node) { path_.push_back(node); node = node->left.get(); }
}
TextBuffer::TextBuffer() { rebuild({}); }
TextBuffer::TextBuffer(SakuraStringView text, const std::function<bool()>& cancelled) { rebuild(text, cancelled); }
TextBuffer::TextBuffer(TextBuffer&& other) noexcept
    : root_(other.root_), length_(other.length_), revision_(other.revision_) {}
TextBuffer& TextBuffer::operator=(TextBuffer&& other) noexcept {
  root_ = other.root_; length_ = other.length_; revision_ = other.revision_; return *this;
}
void TextBuffer::assign(SakuraStringView text, const std::function<bool()>& cancelled) { rebuild(text, cancelled); ++revision_; }
void TextBuffer::restoreSnapshot(const TextBuffer& snapshot, std::uint64_t revisionSteps) noexcept {
  root_ = snapshot.root_; length_ = snapshot.length_; revision_ += std::max<std::uint64_t>(1, revisionSteps);
}
bool TextBuffer::sharesStorageWith(const TextBuffer& other) const noexcept { return root_ == other.root_; }
std::size_t TextBuffer::lineCount() const noexcept { return rows(root_); }
const TextLine& TextBuffer::line(std::size_t index) const { return lineAt(root_, index); }
TextLineCursor TextBuffer::lineCursor(std::size_t first) const { return TextLineCursor(root_, first); }
TextOffset TextBuffer::length() const noexcept { return length_; }
std::uint64_t TextBuffer::revision() const noexcept { return revision_; }
SakuraString TextBuffer::text(const std::function<bool()>& cancelled) const {
  if (cancelled && cancelled()) throw std::runtime_error("text serialization cancelled");
  SakuraString result; result.reserve(checkedSize(length_)); appendTree(result, root_, cancelled); return result;
}
TextBuffer::StorageStatistics TextBuffer::storageStatistics() const { return inspect(root_); }
TextLineChange TextBuffer::changesFrom(const TextBuffer& previous) const {
  const auto limit = std::min(lineCount(), previous.lineCount());
  const auto prefix = commonLines(root_, previous.root_, limit, false);
  const auto suffix = commonLines(root_, previous.root_, limit - prefix.count, true);
  return {prefix.count, previous.lineCount() - prefix.count - suffix.count,
      lineCount() - prefix.count - suffix.count,
      {prefix.units, previous.length_ - prefix.units - suffix.units},
      {prefix.units, length_ - prefix.units - suffix.units}, prefix.compared + suffix.compared};
}
SakuraChar TextBuffer::characterAt(TextOffset offset) const {
  if (offset >= length_) throw std::out_of_range("character is outside the buffer");
  return codeUnitAt(offset);
}
void TextBuffer::copyText(TextRange range, std::span<SakuraChar> destination) const {
  const auto end = checkedEnd(range, length_);
  if (range.length > destination.size()) throw std::out_of_range("destination is too small");
  if (!range.length) return;
  auto index = lineIndexAt(range.location);
  auto currentStart = prefixLength(index);
  auto lines = lineCursor(index);
  auto cursor = range.location;
  auto* output = destination.data();
  while (cursor < end) {
    const auto& current = lines.line();
    const auto relative = cursor - currentStart;
    const auto contentLength = static_cast<TextOffset>(current.content.size());
    const auto available = std::min(end - cursor, contentLength + endingLength(current.ending) - relative);
    if (relative < contentLength) {
      const auto size = checkedSize(std::min(available, contentLength - relative));
      output = std::copy_n(current.content.data() + checkedSize(relative), size, output);
    }
    if (relative + available > contentLength) {
      const auto start = relative > contentLength ? relative - contentLength : 0;
      const SakuraStringView ending = current.ending == LineEnding::carriageReturnLineFeed ? u"\r\n"
          : current.ending == LineEnding::carriageReturn ? u"\r" : current.ending == LineEnding::lineFeed ? u"\n" : u"";
      const auto part = ending.substr(checkedSize(start), checkedSize(relative + available - contentLength - start));
      output = std::copy(part.begin(), part.end(), output);
    }
    cursor += available; currentStart += contentLength + endingLength(current.ending); lines.advance();
  }
}
SakuraString TextBuffer::slice(TextRange range, const std::function<bool()>& cancelled) const {
  auto end = checkedEnd(range, length_);
  checkCancelled(cancelled);
  SakuraString result; result.reserve(checkedSize(range.length));
  auto cursor = range.location;
  auto index = lineIndexAt(cursor);
  auto currentStart = prefixLength(index);
  auto lines = lineCursor(index);
  while (cursor < end) {
    checkCancelled(cancelled);
    const auto& current = lines.line();
    auto relative = cursor - currentStart;
    auto available = std::min(end - cursor, current.content.size() + endingLength(current.ending) - relative);
    auto contentLength = static_cast<TextOffset>(current.content.size());
    if (relative < contentLength)
      appendPart(result, SakuraStringView(current.content).substr(checkedSize(relative), checkedSize(std::min(available, contentLength - relative))), cancelled);
    const auto requestedEnd = relative + available;
    if (requestedEnd > contentLength) {
      const auto eolStart = relative > contentLength ? relative - contentLength : 0;
      SakuraStringView eol = current.ending == LineEnding::carriageReturnLineFeed ? u"\r\n"
          : current.ending == LineEnding::carriageReturn ? u"\r" : current.ending == LineEnding::lineFeed ? u"\n" : u"";
      result.append(eol.substr(checkedSize(eolStart), checkedSize(requestedEnd - contentLength - eolStart)));
    }
    cursor += available;
    currentStart += current.content.size() + endingLength(current.ending);
    lines.advance();
  }
  return result;
}
TextOffset TextBuffer::offsetAt(TextPosition position) const {
  const auto& current = line(position.line);
  if (position.column > current.content.size()) throw std::out_of_range("text column is outside the logical line");
  return prefixLength(position.line) + position.column;
}
TextPosition TextBuffer::positionAt(TextOffset offset) const {
  if (offset > length_) throw std::out_of_range("text offset is outside the buffer");
  auto index = lineIndexAt(offset);
  return {index, std::min(offset - prefixLength(index), static_cast<TextOffset>(line(index).content.size()))};
}
TextOffset TextBuffer::lineStartOffset(std::size_t index) const {
  if (index >= lineCount()) throw std::out_of_range("logical line is outside the buffer");
  return prefixLength(index);
}
bool TextBuffer::isCodePointBoundary(TextOffset offset) const {
  if (offset > length_) return false;
  if (!offset || offset == length_) return true;
  return !(high(codeUnitAt(offset - 1)) && low(codeUnitAt(offset)));
}
bool TextBuffer::isEditBoundary(TextOffset offset) const {
  const bool codePointBoundary = isCodePointBoundary(offset);
  if (!codePointBoundary || !offset || offset == length_) return codePointBoundary;
  return !(codeUnitAt(offset - 1) == u'\r' && codeUnitAt(offset) == u'\n');
}
void TextBuffer::replace(TextRange range, SakuraStringView replacement, const std::function<bool()>& cancelled) {
  checkCancelled(cancelled);
  const auto end = checkedEnd(range, length_);
  if (!isEditBoundary(range.location) || !isEditBoundary(end))
    throw std::invalid_argument("edit would split an indivisible text sequence");
  if (replacement.size() > std::numeric_limits<TextOffset>::max() - (length_ - range.length))
    throw std::length_error("replacement would exceed the text offset range");
  const auto start = positionAt(range.location), finish = positionAt(end);
  const auto& first = line(start.line);
  const auto& last = line(finish.line);
  const auto newLength = length_ - range.length + replacement.size();
  if (start.line == finish.line && replacement.find_first_of(u"\r\n") == SakuraStringView::npos) {
    const auto newContentLength = first.content.size() - checkedSize(range.length) + replacement.size();
    const bool joinsCrLf = newContentLength == 0 && start.line && line(start.line - 1).ending == LineEnding::carriageReturn &&
        first.ending == LineEnding::lineFeed;
    if (!joinsCrLf) {
      SakuraString changed; changed.reserve(newContentLength);
      appendPart(changed, SakuraStringView(first.content).substr(0, checkedSize(start.column)), cancelled);
      appendPart(changed, replacement, cancelled);
      appendPart(changed, SakuraStringView(last.content).substr(checkedSize(finish.column)), cancelled);
      auto payload = std::make_shared<const TextLine>(TextLine{std::move(changed), first.ending});
      auto updated = replaceLine(root_, start.line, payload);
      checkCancelled(cancelled);
      root_ = std::move(updated); length_ = newLength; ++revision_; return;
    }
  }
  // Parse the edited region and its two boundary neighbors only. Persistent
  // split/join shares the unaffected prefix/suffix, even for newline edits.
  const auto firstLine = start.line ? start.line - 1 : 0;
  const auto lastLine = std::min(finish.line + 1, lineCount() - 1);
  const auto regionStart = prefixLength(firstLine);
  const auto regionEnd = lastLine + 1 < lineCount() ? prefixLength(lastLine + 1) : length_;
  SakuraString changed = slice({regionStart, range.location - regionStart}, cancelled);
  appendPart(changed, replacement, cancelled);
  changed.append(slice({end, regionEnd - end}, cancelled));
  TextBuffer parsed(changed, cancelled);
  Node inserted = parsed.root_;
  if (lastLine + 1 < lineCount()) inserted = split(inserted, rows(inserted) - 1).first;
  auto [prefix, rest] = split(root_, firstLine);
  auto [removed, suffix] = split(rest, lastLine - firstLine + 1);
  auto updated = concatenate(concatenate(std::move(prefix), std::move(inserted)), std::move(suffix));
  if (!updated || units(updated) != newLength) throw std::logic_error("replacement produced an inconsistent line index");
  // All allocations and validation finish before committing the new root.
  checkCancelled(cancelled);
  root_ = std::move(updated); length_ = newLength; ++revision_;
}
void TextBuffer::rebuild(SakuraStringView text, const std::function<bool()>& cancelled) {
  checkCancelled(cancelled);
  std::vector<TextLine> lines;
  std::size_t cursor = 0;
  while (cursor < text.size()) {
    checkCancelled(cancelled);
    auto start = cursor;
    while (cursor < text.size() && text[cursor] != u'\r' && text[cursor] != u'\n') {
      if ((cursor - start) % 65536 == 0) checkCancelled(cancelled);
      ++cursor;
    }
    LineEnding ending = LineEnding::none;
    if (cursor < text.size()) ending = text[cursor] == u'\r'
        ? cursor + 1 < text.size() && text[cursor + 1] == u'\n' ? LineEnding::carriageReturnLineFeed : LineEnding::carriageReturn
        : LineEnding::lineFeed;
    SakuraString content; content.reserve(cursor - start);
    appendPart(content, text.substr(start, cursor - start), cancelled);
    lines.push_back({std::move(content), ending});
    cursor += checkedSize(endingLength(ending));
    if (cursor == text.size() && ending != LineEnding::none) lines.push_back({});
  }
  if (lines.empty()) lines.push_back({});
  auto updated = build(lines, 0, lines.size(), cancelled);
  checkCancelled(cancelled);
  root_ = std::move(updated); length_ = text.size();
}
TextOffset TextBuffer::prefixLength(std::size_t count) const noexcept {
  TextOffset result = 0;
  auto* node = root_.get();
  while (node && count) {
    auto leftRows = rows(node->left);
    if (count <= leftRows) node = node->left.get();
    else {
      result += units(node->left) + node->line->content.size() + endingLength(node->line->ending);
      count -= leftRows + 1; node = node->right.get();
    }
  }
  return result;
}
std::size_t TextBuffer::lineIndexAt(TextOffset offset) const {
  if (offset == length_) return lineCount() - 1;
  std::size_t result = 0;
  auto* node = root_.get();
  while (node) {
    auto leftUnits = units(node->left);
    auto currentUnits = node->line->content.size() + endingLength(node->line->ending);
    if (offset < leftUnits) node = node->left.get();
    else if (offset < leftUnits + currentUnits) return result + rows(node->left);
    else { offset -= leftUnits + currentUnits; result += rows(node->left) + 1; node = node->right.get(); }
  }
  throw std::logic_error("text index does not cover offset");
}
SakuraChar TextBuffer::codeUnitAt(TextOffset offset) const {
  if (offset >= length_) throw std::out_of_range("text offset does not identify a code unit");
  auto index = lineIndexAt(offset);
  const auto& current = line(index);
  auto relative = offset - prefixLength(index);
  if (relative < current.content.size()) return current.content[checkedSize(relative)];
  switch (current.ending) {
    case LineEnding::lineFeed: return u'\n';
    case LineEnding::carriageReturn: return u'\r';
    case LineEnding::carriageReturnLineFeed: return relative == current.content.size() ? u'\r' : u'\n';
    case LineEnding::none: break;
  }
  throw std::out_of_range("text offset is outside the serialized line");
}
TextOffset TextBuffer::endingLength(LineEnding ending) noexcept { return eolLength(ending); }
}  // namespace sakura::core
