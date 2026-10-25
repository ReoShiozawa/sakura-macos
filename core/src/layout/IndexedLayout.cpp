// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include "sakura/core/layout/IndexedLayout.h"
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>

namespace sakura::core {
namespace detail {
struct Fragment { TextOffset end; float width; };
// The common one-fragment case has no per-line heap allocation. Wrapped
// continuations are separate, shared vectors, copied only when that line changes.
struct LayoutLineSummary { TextOffset units; TextOffset firstEnd; float firstWidth; };
struct WrappedLine { std::size_t line; std::shared_ptr<const std::vector<Fragment>> tails; float widest; };
struct LayoutBlock {
  std::vector<LayoutLineSummary> lines;
  std::vector<WrappedLine> wrapped;
  std::size_t visualRows{};
  TextOffset units{};
  float widest{};
};
struct LayoutTreeNode {
  std::shared_ptr<const LayoutBlock> block;
  std::shared_ptr<const LayoutTreeNode> left, right;
  std::size_t logicalRows, visualRows;
  TextOffset units;
  float widest;
  unsigned height;
};
}
namespace {
using Node = std::shared_ptr<const detail::LayoutTreeNode>;
using Block = std::shared_ptr<const detail::LayoutBlock>;
constexpr std::size_t blockLimit = 64;
std::size_t logical(const Node& n) { return n ? n->logicalRows : 0; }
std::size_t visual(const Node& n) { return n ? n->visualRows : 0; }
TextOffset units(const Node& n) { return n ? n->units : 0; }
float widest(const Node& n) { return n ? n->widest : 0; }
unsigned height(const Node& n) { return n ? n->height : 0; }
template<class T> T checkedAdd(T a, T b) {
  if (a > std::numeric_limits<T>::max() - b) throw std::length_error("layout index size overflow");
  return a + b;
}
const std::vector<detail::Fragment>* tails(const detail::LayoutBlock& block, std::size_t line) {
  const auto found = std::lower_bound(block.wrapped.begin(), block.wrapped.end(), line,
      [](const detail::WrappedLine& value, std::size_t target) { return value.line < target; });
  return found != block.wrapped.end() && found->line == line ? found->tails.get() : nullptr;
}
void summarize(detail::LayoutBlock& block) {
  block.units = 0; block.visualRows = block.lines.size(); block.widest = 0;
  for (const auto& line : block.lines) {
    block.units = checkedAdd(block.units, line.units);
    block.widest = std::max(block.widest, line.firstWidth);
  }
  for (const auto& wrapped : block.wrapped) {
    block.visualRows = checkedAdd(block.visualRows, wrapped.tails->size());
    block.widest = std::max(block.widest, wrapped.widest);
  }
}
Node makeNode(Block block, Node left = {}, Node right = {}) {
  const auto logicalRows = checkedAdd(checkedAdd(logical(left), block->lines.size()), logical(right));
  const auto visualRows = checkedAdd(checkedAdd(visual(left), block->visualRows), visual(right));
  const auto count = checkedAdd(checkedAdd(units(left), block->units), units(right));
  const auto width = std::max({widest(left), block->widest, widest(right)});
  const auto h = 1 + std::max(height(left), height(right));
  return std::make_shared<const detail::LayoutTreeNode>(detail::LayoutTreeNode{
      std::move(block), std::move(left), std::move(right), logicalRows, visualRows, count, width, h});
}
Node balance(Block block, Node left, Node right) {
  if (height(left) > height(right) + 1) {
    if (height(left->left) >= height(left->right))
      return makeNode(left->block, left->left, makeNode(std::move(block), left->right, std::move(right)));
    const auto pivot = left->right;
    return makeNode(pivot->block, makeNode(left->block, left->left, pivot->left),
        makeNode(std::move(block), pivot->right, std::move(right)));
  }
  if (height(right) > height(left) + 1) {
    if (height(right->right) >= height(right->left))
      return makeNode(right->block, makeNode(std::move(block), std::move(left), right->left), right->right);
    const auto pivot = right->left;
    return makeNode(pivot->block, makeNode(std::move(block), std::move(left), pivot->left),
        makeNode(right->block, pivot->right, right->right));
  }
  return makeNode(std::move(block), std::move(left), std::move(right));
}
Node join(Node left, Block block, Node right) {
  if (height(left) > height(right) + 1)
    return balance(left->block, left->left, join(left->right, std::move(block), std::move(right)));
  if (height(right) > height(left) + 1)
    return balance(right->block, join(std::move(left), std::move(block), right->left), right->right);
  return makeNode(std::move(block), std::move(left), std::move(right));
}
Block part(const Block& source, std::size_t first, std::size_t count) {
  auto result = std::make_shared<detail::LayoutBlock>();
  result->lines.assign(source->lines.begin() + first, source->lines.begin() + first + count);
  for (const auto& wrapped : source->wrapped)
    if (wrapped.line >= first && wrapped.line - first < count)
      result->wrapped.push_back({wrapped.line - first, wrapped.tails, wrapped.widest});
  summarize(*result); return result;
}
std::pair<Node, Node> split(const Node& node, std::size_t count) {
  if (!node) return {};
  if (!count) return {{}, node};
  if (count >= logical(node)) return {node, {}};
  const auto before = logical(node->left), blockSize = node->block->lines.size();
  if (count < before) {
    auto [left, right] = split(node->left, count);
    return {std::move(left), join(std::move(right), node->block, node->right)};
  }
  if (count > before + blockSize) {
    auto [left, right] = split(node->right, count - before - blockSize);
    return {join(node->left, node->block, std::move(left)), std::move(right)};
  }
  const auto local = count - before;
  Node left = local ? join(node->left, part(node->block, 0, local), {}) : node->left;
  Node right = local < blockSize ? join({}, part(node->block, local, blockSize - local), node->right) : node->right;
  return {std::move(left), std::move(right)};
}
std::pair<Block, Node> takeFirst(const Node& n) {
  if (!n->left) return {n->block, n->right};
  auto [block, remainder] = takeFirst(n->left);
  return {std::move(block), balance(n->block, std::move(remainder), n->right)};
}
std::pair<Node, Block> takeLast(const Node& n) {
  if (!n->right) return {n->left, n->block};
  auto [remainder, block] = takeLast(n->right);
  return {balance(n->block, n->left, std::move(remainder)), std::move(block)};
}
Node concatenate(Node left, Node right) {
  if (!left) return right;
  if (!right) return left;
  auto* last = left.get(); while (last->right) last = last->right.get();
  auto* first = right.get(); while (first->left) first = first->left.get();
  if (last->block->lines.size() + first->block->lines.size() <= blockLimit) {
    auto [prefix, a] = takeLast(left);
    auto [b, suffix] = takeFirst(right);
    auto merged = std::make_shared<detail::LayoutBlock>(*a);
    const auto offset = merged->lines.size();
    merged->lines.insert(merged->lines.end(), b->lines.begin(), b->lines.end());
    for (const auto& wrapped : b->wrapped) merged->wrapped.push_back({offset + wrapped.line, wrapped.tails, wrapped.widest});
    summarize(*merged);
    return join(std::move(prefix), std::move(merged), std::move(suffix));
  }
  auto [middle, remainder] = takeFirst(right);
  return join(std::move(left), std::move(middle), std::move(remainder));
}
Node build(const std::vector<Block>& blocks, std::size_t first, std::size_t end) {
  if (first == end) return {};
  const auto middle = first + (end - first) / 2;
  return makeNode(blocks[middle], build(blocks, first, middle), build(blocks, middle + 1, end));
}
Node measure(const TextBuffer& buffer, std::size_t first, std::size_t count,
    const ITextMetrics& metrics, const FontStyle& style, const LayoutOptions& options,
    const std::function<bool()>& cancelled) {
  std::vector<Block> blocks;
  blocks.reserve(count / blockLimit + (count % blockLimit != 0));
  for (std::size_t offset = 0; offset < count;) {
    const auto size = std::min(blockLimit, count - offset);
    const auto layout = LayoutEngine{}.layoutLines(buffer, first + offset, size, metrics, style, options, cancelled);
    auto block = std::make_shared<detail::LayoutBlock>();
    block->lines.reserve(size);
    auto cursor = buffer.lineCursor(first + offset);
    std::size_t row = 0;
    for (std::size_t line = 0; line < size; ++line, cursor.advance()) {
      const auto& text = cursor.line();
      const auto firstRow = layout.visualLines[row++];
      const TextOffset ending = text.ending == LineEnding::none ? 0 : text.ending == LineEnding::carriageReturnLineFeed ? 2 : 1;
      block->lines.push_back({text.content.size() + ending, firstRow.endColumn, firstRow.width});
      if (row < layout.visualLines.size() && layout.visualLines[row].logicalLine == first + offset + line) {
        auto extra = std::make_shared<std::vector<detail::Fragment>>();
        float widest = 0;
        do {
          extra->push_back({layout.visualLines[row].endColumn, layout.visualLines[row].width});
          widest = std::max(widest, layout.visualLines[row].width);
          ++row;
        } while (row < layout.visualLines.size() && layout.visualLines[row].logicalLine == first + offset + line);
        block->wrapped.push_back({line, std::move(extra), widest});
      }
    }
    summarize(*block); blocks.push_back(std::move(block)); offset += size;
  }
  return build(blocks, 0, blocks.size());
}
IndexedLayout::StorageStatistics inspect(const Node& node) {
  if (!node) return {0, 0, 0, true};
  const auto left = inspect(node->left), right = inspect(node->right);
  const auto h = 1 + std::max(left.height, right.height);
  auto block = *node->block; summarize(block);
  const bool valid = left.valid && right.valid && !block.lines.empty() && block.lines.size() <= blockLimit &&
      h == node->height && left.height <= right.height + 1 && right.height <= left.height + 1 &&
      node->logicalRows == left.logicalLines + block.lines.size() + right.logicalLines &&
      node->visualRows == visual(node->left) + block.visualRows + visual(node->right) &&
      node->units == units(node->left) + block.units + units(node->right) &&
      node->widest == std::max({widest(node->left), block.widest, widest(node->right)});
  return {left.nodes + right.nodes + 1, node->logicalRows, h, valid};
}
}  // namespace

void IndexedLayout::update(const TextBuffer& buffer, const ITextMetrics& metrics,
    const FontStyle& style, const LayoutOptions& options, std::uint64_t metricsRevision,
    const std::function<bool()>& cancelled) {
  if (cancelled && cancelled()) throw std::runtime_error("layout cancelled");
  const auto lineHeight = std::max(0.0F, metrics.lineHeight(style));
  const bool full = !source_ || style != style_ || options != options_ ||
      metricsRevision != metricsRevision_ || lineHeight != lineHeight_;
  const TextBuffer snapshot = buffer;
  const auto change = full ? TextLineChange{0, source_ ? source_->lineCount() : 0, snapshot.lineCount()}
                          : snapshot.changesFrom(*source_);
  auto root = root_;
  if (change.oldLineCount || change.newLineCount) {
    auto replacement = measure(snapshot, change.firstLine, change.newLineCount, metrics, style, options, cancelled);
    if (full) root = std::move(replacement);
    else {
      auto [prefix, rest] = split(root_, change.firstLine);
      auto [removed, suffix] = split(rest, change.oldLineCount);
      root = concatenate(concatenate(std::move(prefix), std::move(replacement)), std::move(suffix));
    }
  }
  // Publish only after all allocation/metrics calls have succeeded.
  if (cancelled && cancelled()) throw std::runtime_error("layout cancelled");
  root_ = std::move(root); source_ = snapshot; style_ = style; options_ = options;
  metricsRevision_ = metricsRevision; lineHeight_ = lineHeight;
  statistics_ = {change.newLineCount, change.comparedNodes, full};
}
bool IndexedLayout::matchesText(const TextBuffer& buffer) const noexcept {
  return source_ && source_->revision() == buffer.revision() && source_->sharesStorageWith(buffer);
}
std::size_t IndexedLayout::size() const noexcept { return visual(root_); }
bool IndexedLayout::empty() const noexcept { return !root_; }
float IndexedLayout::widestLine() const noexcept { return widest(root_); }
float IndexedLayout::lineHeight() const noexcept { return lineHeight_; }
LayoutUpdateStatistics IndexedLayout::lastUpdate() const noexcept { return statistics_; }
IndexedLayout::StorageStatistics IndexedLayout::storageStatistics() const { return inspect(root_); }
IndexedLayoutRow IndexedLayout::row(std::size_t index) const {
  if (index >= size()) throw std::out_of_range("visual row is outside the layout");
  const auto* node = root_.get();
  std::size_t logicalStart = 0; TextOffset textStart = 0;
  while (node) {
    if (index < visual(node->left)) { node = node->left.get(); continue; }
    index -= visual(node->left); logicalStart += logical(node->left); textStart += units(node->left);
    if (index >= node->block->visualRows) {
      index -= node->block->visualRows; logicalStart += node->block->lines.size(); textStart += node->block->units;
      node = node->right.get(); continue;
    }
    const auto& block = *node->block;
    for (std::size_t line = 0; line < block.lines.size(); ++line) {
      const auto& summary = block.lines[line];
      const auto* extra = tails(block, line);
      const auto count = 1 + (extra ? extra->size() : 0);
      if (index < count) {
        const auto start = index == 0 ? 0 : index == 1 ? summary.firstEnd : (*extra)[index - 2].end;
        const auto end = index == 0 ? summary.firstEnd : (*extra)[index - 1].end;
        const auto width = index == 0 ? summary.firstWidth : (*extra)[index - 1].width;
        return {{logicalStart + line, start, end, width, lineHeight_}, {textStart + start, end - start}};
      }
      index -= count; textStart += summary.units;
    }
  }
  throw std::logic_error("invalid layout row index");
}
std::size_t IndexedLayout::visualLineForOffset(TextOffset offset, std::size_t* visitedNodes) const {
  if (!source_) throw std::out_of_range("layout is empty");
  return visualLineFor(source_->positionAt(std::min(offset, source_->length())), visitedNodes);
}
std::size_t IndexedLayout::visualLineFor(TextPosition position, std::size_t* visitedNodes) const {
  if (!source_) throw std::out_of_range("layout is empty");
  // Validate logical columns, including the distinction between content and EOL.
  (void)source_->offsetAt(position);
  const auto* node = root_.get();
  auto line = position.line; std::size_t preceding = 0;
  while (node) {
    if (visitedNodes) ++*visitedNodes;
    if (line < logical(node->left)) { node = node->left.get(); continue; }
    line -= logical(node->left); preceding += visual(node->left);
    if (line >= node->block->lines.size()) {
      line -= node->block->lines.size(); preceding += node->block->visualRows; node = node->right.get(); continue;
    }
    const auto& block = *node->block;
    for (std::size_t i = 0; i < line; ++i) {
      const auto* extra = tails(block, i); preceding += 1 + (extra ? extra->size() : 0);
    }
    if (position.column <= block.lines[line].firstEnd) return preceding;
    const auto* extra = tails(block, line);
    if (extra) {
      const auto found = std::lower_bound(extra->begin(), extra->end(), position.column,
          [](const detail::Fragment& fragment, TextOffset column) { return fragment.end < column; });
      if (found != extra->end()) return preceding + 1 + static_cast<std::size_t>(found - extra->begin());
    }
    break;
  }
  throw std::out_of_range("text position is not present in layout");
}
}  // namespace sakura::core
