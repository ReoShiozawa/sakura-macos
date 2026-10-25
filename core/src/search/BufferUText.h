// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#ifndef SAKURA_CORE_SEARCH_BUFFER_UTEXT_H_
#define SAKURA_CORE_SEARCH_BUFFER_UTEXT_H_

#include <functional>
#include <memory>
#include <unicode/utext.h>
#include "sakura/core/text/TextBuffer.h"

namespace sakura::core::detail {
struct BufferUTextState;

// Read-only ICU provider. Each iterator owns a root snapshot and independent
// bounded UTF-16 window, including across shallow/deep clones. No C++ exception
// can cross ICU callbacks; callers must rethrowFailure() after each ICU call.
// extract() normalizes split surrogate endpoints outward and reports a stable
// required length even for preflight/truncation. Ordinary code-point-aligned
// ranges match ICU openUChars; its split-limit capacity quirk is not copied.
class BufferUText {
 public:
  static constexpr std::size_t chunkUnits = 8192;
  struct Statistics {
    std::uint64_t chunkLoads{}, copiedUnits{}, extractedUnits{}, peakChunkUnits{};
  };
  explicit BufferUText(const TextBuffer& buffer,
                       const std::function<bool()>& cancelled = {});
  [[nodiscard]] UText* get() const noexcept { return text_.get(); }
  void rethrowFailure() const;
  [[nodiscard]] Statistics statistics() const noexcept;
 private:
  std::shared_ptr<BufferUTextState> state_;
  std::unique_ptr<UText, decltype(&utext_close)> text_{nullptr, utext_close};
};
} // namespace sakura::core::detail
#endif
