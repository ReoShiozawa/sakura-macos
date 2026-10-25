// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#pragma once

#include "sakura/core/text/TextBuffer.h"
#include <algorithm>
#include <functional>
#include <stdexcept>
#include <vector>

namespace sakura::core::detail {
struct SyntaxNeedsMoreInput {};
// One operation-local probe is shared by nested lexers. No global/thread-local
// callback or document reference: callers may run independent scans in parallel.
class SyntaxProbe {
 public:
  explicit SyntaxProbe(const std::function<bool()>& cancelled, bool track = false)
      : cancelled_(cancelled), track_(track) { check(); }
  void observe(std::size_t end) { if (track_) dependencyEnd = std::max(dependencyEnd, end); }
  std::size_t dependencyEnd{};
  void check() const {
    if (cancelled_ && cancelled_()) throw std::runtime_error("syntax analysis cancelled");
  }
  void tick() {
    if (cancelled_ && ++reads_ == 2048) { reads_ = 0; check(); }
  }
  void append(SakuraString& target, SakuraStringView source) {
    for (std::size_t offset = 0; offset < source.size(); offset += 65536) {
      check(); target.append(source.substr(offset, std::min<std::size_t>(65536, source.size() - offset)));
    }
  }
  bool equal(SakuraStringView left, SakuraStringView right) {
    if (left.size() != right.size()) return false;
    for (std::size_t offset = 0; offset < left.size(); offset += 65536) {
      check();
      auto count = std::min<std::size_t>(65536, left.size() - offset);
      if (left.substr(offset, count) != right.substr(offset, count)) return false;
    }
    return true;
  }
 private:
  const std::function<bool()>& cancelled_;
  bool track_;
  unsigned reads_{0};
};

// Route all input-character reads and potentially unbounded find operations
// through the probe. A single unterminated comment/string must be cancellable,
// not just the outer token loop. substr is non-owning.
class SyntaxText {
 public:
  static constexpr auto npos = SakuraStringView::npos;
  SyntaxText(SakuraStringView text, SyntaxProbe& probe, std::size_t total = npos, std::size_t origin = 0)
      : text_(text), probe_(probe), total_(total == npos ? text.size() : total), origin_(origin) {}
  std::size_t size() const { return total_; }
  SakuraChar operator[](std::size_t index) const {
    probe_.tick();
    if (index >= text_.size()) throw SyntaxNeedsMoreInput{};
    probe_.observe(origin_ + index + 1); return text_[index];
  }
  bool startsWith(std::size_t at, SakuraStringView prefix) const {
    probe_.tick();
    if (at > size()) return false;
    if (prefix.size() <= 64) return substr(at, prefix.size()) == prefix;
    return probe_.equal(substr(at, prefix.size()), prefix);
  }
  SakuraStringView substr(std::size_t at, std::size_t count = npos) const {
    if (at > size()) throw std::out_of_range("syntax slice");
    auto length = std::min(count, size() - at);
    if (at > text_.size() || length > text_.size() - at) throw SyntaxNeedsMoreInput{};
    probe_.observe(origin_ + at + length + (count > size() - at ? 1 : 0));
    return text_.substr(at, length);
  }
  std::size_t find(SakuraChar value, std::size_t at = 0) const {
    for (; at < text_.size(); at += 65536) {
      probe_.check();
      const auto count = std::min<std::size_t>(65536, text_.size() - at);
      auto found = text_.substr(at, count).find(value);
      probe_.observe(origin_ + at + (found != npos ? found + 1 : count));
      if (found != npos) return at + found;
    }
    if (text_.size() < size()) throw SyntaxNeedsMoreInput{};
    probe_.observe(origin_ + size() + 1);
    return npos;
  }
  std::size_t find(SakuraStringView value, std::size_t at = 0) const {
    probe_.check();
    if (at > size()) return npos;
    if (value.empty()) return at;
    if (value.size() > size() - at) { probe_.observe(origin_ + size() + 1); return npos; }
    if (value.size() <= 64) {
      // Bounded overlap keeps delimiters split across chunks visible.
      for (; at < text_.size(); at += 65536) {
        probe_.check();
        const auto count = std::min<std::size_t>(65536 + value.size() - 1, text_.size() - at);
        auto found = text_.substr(at, count).find(value);
        probe_.observe(origin_ + at + (found != npos ? found + value.size() : count));
        if (found != npos) return at + found;
      }
      if (text_.size() < size()) throw SyntaxNeedsMoreInput{};
      probe_.observe(origin_ + size() + 1);
      return npos;
    }
    // Long Rust/SQL/Markdown delimiters must not turn a repetitive malformed
    // input into an uninterruptible quadratic std::string_view::find.
    std::vector<std::size_t> prefix(value.size());
    for (std::size_t i = 1, j = 0; i < value.size(); ++i) {
      probe_.tick();
      while (j && value[i] != value[j]) { probe_.tick(); j = prefix[j - 1]; }
      if (value[i] == value[j]) ++j;
      prefix[i] = j;
    }
    for (std::size_t j = 0; at < size(); ++at) {
      probe_.tick();
      const auto c = (*this)[at];
      while (j && c != value[j]) { probe_.tick(); j = prefix[j - 1]; }
      if (c == value[j]) ++j;
      if (j == value.size()) return at + 1 - j;
    }
    probe_.observe(origin_ + size() + 1); return npos;
  }
  std::size_t find_last_of(SakuraStringView values, std::size_t at) const {
    if (!size()) return npos;
    at = std::min(at, size() - 1);
    do {
      probe_.tick();
      if (values.find((*this)[at]) != npos) return at;
    } while (at-- != 0);
    return npos;
  }
 private:
  SakuraStringView text_;
  SyntaxProbe& probe_;
  std::size_t total_, origin_;
};
}  // namespace sakura::core::detail
