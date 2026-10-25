// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#include "sakura/core/syntax/IndexedSyntax.h"
#include "LanguageSyntaxInternal.h"
#include <algorithm>
#include <limits>
#include <stdexcept>

namespace sakura::core {
namespace detail {
struct SyntaxBlock {
  TextOffset units{}, dependencyEnd{};
  SyntaxState before, after;
  std::vector<SyntaxToken> tokens;
};
struct SyntaxTreeNode {
  std::shared_ptr<const SyntaxBlock> block;
  std::shared_ptr<const SyntaxTreeNode> left, right;
  TextOffset units{}, dependencyEnd{};
  std::size_t blocks{}, tokens{};
  unsigned height{};
};
}
namespace {
using Node = std::shared_ptr<const detail::SyntaxTreeNode>;
using Block = std::shared_ptr<const detail::SyntaxBlock>;
using State = detail::SyntaxState;
TextOffset units(const Node& n) { return n ? n->units : 0; }
TextOffset dependency(const Node& n) { return n ? n->dependencyEnd : 0; }
std::size_t blocks(const Node& n) { return n ? n->blocks : 0; }
std::size_t tokens(const Node& n) { return n ? n->tokens : 0; }
unsigned height(const Node& n) { return n ? n->height : 0; }
template<class T> T sum(T a, T b) {
  if (a > std::numeric_limits<T>::max() - b) throw std::length_error("syntax index overflow");
  return a + b;
}
void check(const std::function<bool()>& cancelled) {
  if (cancelled && cancelled()) throw std::runtime_error("syntax index cancelled");
}
Node makeNode(Block b, Node l = {}, Node r = {}) {
  auto offset = sum(units(l), b->units);
  return std::make_shared<const detail::SyntaxTreeNode>(detail::SyntaxTreeNode{b, l, r,
      sum(offset, units(r)), std::max({dependency(l), sum(units(l), b->dependencyEnd), sum(offset, dependency(r))}),
      sum(sum(blocks(l), std::size_t{1}), blocks(r)), sum(sum(tokens(l), b->tokens.size()), tokens(r)),
      1 + std::max(height(l), height(r))});
}
Node balance(Block b, Node l, Node r) {
  if (height(l) > height(r) + 1) {
    if (height(l->left) >= height(l->right)) return makeNode(l->block, l->left, makeNode(b, l->right, r));
    auto p = l->right; return makeNode(p->block, makeNode(l->block, l->left, p->left), makeNode(b, p->right, r));
  }
  if (height(r) > height(l) + 1) {
    if (height(r->right) >= height(r->left)) return makeNode(r->block, makeNode(b, l, r->left), r->right);
    auto p = r->left; return makeNode(p->block, makeNode(b, l, p->left), makeNode(r->block, p->right, r->right));
  }
  return makeNode(b, l, r);
}
Node join(Node l, Block b, Node r) {
  if (height(l) > height(r) + 1) return balance(l->block, l->left, join(l->right, b, r));
  if (height(r) > height(l) + 1) return balance(r->block, join(l, b, r->left), r->right);
  return makeNode(b, l, r);
}
std::pair<Node, Node> split(const Node& n, std::size_t count) {
  if (!n) return {};
  if (!count) return {{}, n};
  if (count >= blocks(n)) return {n, {}};
  if (count <= blocks(n->left)) {
    auto [a,b] = split(n->left, count); return {a, join(b, n->block, n->right)};
  }
  auto [a,b] = split(n->right, count - blocks(n->left) - 1); return {join(n->left, n->block, a), b};
}
std::pair<Block, Node> takeFirst(const Node& n) {
  if (!n->left) return {n->block, n->right};
  auto [b,r] = takeFirst(n->left); return {b, balance(n->block, r, n->right)};
}
Node concatenate(Node l, Node r) {
  if (!l) return r;
  if (!r) return l;
  auto [b,rest] = takeFirst(r); return join(l, b, rest);
}
Node build(const std::vector<Block>& b, std::size_t first, std::size_t end) {
  if (first == end) return {};
  auto mid = first + (end-first)/2;
  return makeNode(b[mid], build(b,first,mid), build(b,mid+1,end));
}
struct Location { std::size_t index{}; TextOffset start{}; Block block; };
Location atIndex(const Node& n, std::size_t target) {
  auto p = n.get(); Location result;
  while (p) {
    const auto left = blocks(p->left);
    if (target < left) p = p->left.get();
    else if (target == left) { result.index += left; result.start += units(p->left); result.block = p->block; return result; }
    else { target -= left+1; result.index += left+1; result.start += units(p->left)+p->block->units; p = p->right.get(); }
  }
  throw std::out_of_range("syntax block index");
}
Location atOffset(const Node& n, TextOffset offset) {
  if (offset >= units(n)) return atIndex(n, blocks(n)-1);
  auto p = n.get(); Location result;
  while (p) {
    auto start = result.start + units(p->left);
    if (offset < start) p = p->left.get();
    else if (offset < start + p->block->units) { result.index += blocks(p->left); result.start = start; result.block = p->block; return result; }
    else { result.index += blocks(p->left)+1; result.start = start+p->block->units; p = p->right.get(); }
  }
  throw std::out_of_range("syntax source offset");
}
std::optional<std::size_t> firstDependency(const Node& n, TextOffset dirty,
    TextOffset base = 0, std::size_t index = 0) {
  if (!n || sum(base, dependency(n)) <= dirty) return {};
  if (auto found = firstDependency(n->left, dirty, base, index)) return found;
  base += units(n->left); index += blocks(n->left);
  if (sum(base, n->block->dependencyEnd) > dirty) return index;
  return firstDependency(n->right, dirty, base+n->block->units, index+1);
}
void collect(const Node& n, TextOffset base, TextRange range, std::vector<SyntaxToken>& out,
    const std::function<bool()>& cancelled) {
  if (!n || base >= range.location+range.length || base+units(n) <= range.location) return;
  check(cancelled);
  collect(n->left, base, range, out, cancelled);
  base += units(n->left);
  if (base < range.location+range.length && base+n->block->units > range.location) {
    const auto& values = n->block->tokens;
    auto it = std::lower_bound(values.begin(), values.end(), range.location > base ? range.location-base : 0,
        [](const SyntaxToken& t, TextOffset at) { return t.range.location+t.range.length <= at; });
    for (; it != values.end() && base+it->range.location < range.location+range.length; ++it) {
      if ((out.size() & 2047) == 0) check(cancelled);
      auto token = *it; token.range.location += base; out.push_back(token);
    }
  }
  collect(n->right, base+n->block->units, range, out, cancelled);
}
IndexedSyntax::StorageStatistics inspect(const Node& n) {
  if (!n) return {0,0,true};
  auto l = inspect(n->left), r = inspect(n->right);
  auto rebuilt = makeNode(n->block,n->left,n->right);
  bool valid = l.valid && r.valid && n->height == rebuilt->height && n->units == rebuilt->units &&
      n->dependencyEnd == rebuilt->dependencyEnd && n->blocks == rebuilt->blocks && n->tokens == rebuilt->tokens &&
      l.height <= r.height+1 && r.height <= l.height+1;
  TextOffset end = 0;
  for (auto t : n->block->tokens) {
    valid = valid && t.range.length && t.range.location >= end && t.range.location+t.range.length <= n->block->units;
    end = t.range.location+t.range.length;
  }
  return {l.blocks+r.blocks+1, rebuilt->height, valid};
}
}

void IndexedSyntax::update(const TextBuffer& source, SyntaxLanguage language, const std::function<bool()>& cancelled) {
  check(cancelled);
  const TextBuffer snapshot = source;
  if (snapshot.length() >= std::numeric_limits<std::size_t>::max())
    throw std::length_error("syntax source exceeds addressable range");
  SyntaxUpdateStatistics stats;
  stats.fullRebuild = !root_ || !source_ || language != language_;
  if (!stats.fullRebuild && source_->sharesStorageWith(snapshot)) {
    stats.reusedUnits = snapshot.length(); source_ = snapshot; statistics_ = stats; return;
  }
  Node next;
  if (language == SyntaxLanguage::plain) {
    auto b = std::make_shared<detail::SyntaxBlock>(); b->units = snapshot.length(); b->dependencyEnd = sum(b->units, TextOffset{1});
    next = makeNode(std::move(b)); stats.rebuiltBlocks = 1;
  } else {
    TextLineChange change;
    if (stats.fullRebuild) { change.oldText = {0,source_ ? source_->length() : 0}; change.newText = {0,snapshot.length()}; }
    else change = snapshot.changesFrom(*source_);
    stats.comparedTextNodes = change.comparedNodes;
    Location restart;
    if (!stats.fullRebuild) {
      auto containing = atOffset(root_,change.oldText.location);
      auto dependent = firstDependency(root_,change.oldText.location);
      restart = dependent && *dependent < containing.index ? atIndex(root_,*dependent) : containing;
    }
    const TextOffset remaining = snapshot.length()-restart.start;
    TextOffset window = stats.fullRebuild ? remaining : std::min(remaining,
        std::max<TextOffset>(65536, change.newText.location+change.newText.length-restart.start+4096));
    const TextOffset oldSuffix = change.oldText.location+change.oldText.length;
    const TextOffset newSuffix = change.newText.location+change.newText.length;
    for (;;) {
      check(cancelled); ++stats.attempts;
      auto input = snapshot.slice({restart.start,window}, cancelled);
      stats.serializedUnits = sum(stats.serializedUnits, window);
      detail::SyntaxProbe probe(cancelled,true);
      detail::SyntaxDriver driver;
      std::vector<Block> replacement;
      State before = restart.block ? restart.block->before : State{};
      TextOffset chunkStart = 0, parsed = 0;
      std::size_t reuseIndex = blocks(root_);
      TextOffset nextCandidate = newSuffix;
      auto emit = [&](TextOffset at, State after, TextOffset dependencyEnd, std::vector<SyntaxToken>& values) {
        if (at == chunkStart && values.empty()) return;
        auto b = std::make_shared<detail::SyntaxBlock>(); b->units = at-chunkStart;
        b->dependencyEnd = std::max(at,dependencyEnd)-chunkStart; b->before = before; b->after = after;
        for (auto& t : values) { probe.tick(); t.range.location -= chunkStart; }
        b->tokens = std::move(values); values.clear(); replacement.push_back(std::move(b));
        before = after; chunkStart = at;
      };
      driver.boundary = [&](std::size_t at, State state, std::size_t readEnd, std::vector<SyntaxToken>& values) {
        const TextOffset absolute = restart.start+at;
        bool converged = false;
        if (!stats.fullRebuild && absolute >= nextCandidate && absolute >= newSuffix) {
          const TextOffset old = oldSuffix+(absolute-newSuffix);
          if (old < units(root_)) {
            auto candidate = atOffset(root_,old);
            converged = candidate.start == old && candidate.block->before == state;
            if (converged) reuseIndex = candidate.index;
            else nextCandidate = newSuffix+(candidate.start+candidate.block->units-oldSuffix);
          }
        }
        emit(at,state,readEnd,values); parsed = at;
        const auto nextRegular = sum(static_cast<TextOffset>(at),TextOffset{4096});
        driver.nextBoundary = static_cast<std::size_t>(!stats.fullRebuild && nextCandidate > absolute
            ? std::min(nextRegular,nextCandidate-restart.start) : nextRegular);
        return converged;
      };
      detail::SyntaxScanOptions options;
      options.total = remaining; options.initial = before; options.driver = &driver;
      try {
        try {
          auto tail = detail::scanLanguageSyntax(input,language,probe,options);
          if (window < remaining) throw detail::SyntaxNeedsMoreInput{};
          emit(remaining,driver.finalState,std::max<TextOffset>(probe.dependencyEnd,remaining+1),tail);
          parsed = remaining;
        } catch (const detail::SyntaxScanStopped&) {}
      } catch (const detail::SyntaxNeedsMoreInput&) {
        if (window == remaining) throw std::logic_error("lexer read beyond complete source");
        window = std::min(remaining, sum(window, std::max<TextOffset>(window,1))); continue;
      }
      if (replacement.empty()) {
        auto b = std::make_shared<detail::SyntaxBlock>(); b->before = b->after = before; b->dependencyEnd = 1;
        replacement.push_back(std::move(b));
      }
      Node prefix, suffix;
      if (!stats.fullRebuild) {
        prefix = split(root_,restart.index).first;
        suffix = split(root_,reuseIndex).second;
      }
      next = concatenate(concatenate(prefix,build(replacement,0,replacement.size())),suffix);
      stats.parsedUnits = parsed; stats.reusedUnits = units(prefix)+units(suffix); stats.rebuiltBlocks = replacement.size();
      break;
    }
  }
  if (units(next) != snapshot.length()) throw std::logic_error("syntax index length mismatch");
  check(cancelled);
  root_ = std::move(next); source_ = snapshot; language_ = language; statistics_ = stats;
}
bool IndexedSyntax::matchesText(const TextBuffer& source) const noexcept {
  return source_ && source_->revision() == source.revision() && source_->sharesStorageWith(source);
}
std::size_t IndexedSyntax::tokenCount() const noexcept { return ::sakura::core::tokens(root_); }
std::vector<SyntaxToken> IndexedSyntax::tokensIn(TextRange range, const std::function<bool()>& cancelled) const {
  if (range.location > units(root_) || range.length > units(root_)-range.location) throw std::out_of_range("syntax query range");
  check(cancelled); std::vector<SyntaxToken> result;
  if (range.location == 0 && range.length == units(root_)) result.reserve(root_ ? root_->tokens : 0);
  if (range.length) collect(root_,0,range,result,cancelled);
  check(cancelled); return result;
}
std::vector<SyntaxToken> IndexedSyntax::tokens(const std::function<bool()>& cancelled) const {
  return tokensIn({0,units(root_)},cancelled);
}
IndexedSyntax::StorageStatistics IndexedSyntax::storageStatistics() const { return inspect(root_); }
}  // namespace sakura::core
