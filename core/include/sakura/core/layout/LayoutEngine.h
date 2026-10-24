// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#ifndef SAKURA_CORE_LAYOUT_LAYOUT_ENGINE_H_
#define SAKURA_CORE_LAYOUT_LAYOUT_ENGINE_H_

#include <cstddef>
#include <cstdint>
#include <vector>

#include "sakura/core/text/TextBuffer.h"

namespace sakura::core {

// The portable core identifies a font style without retaining platform font
// objects.  AppKit and Win32 adapters resolve the descriptor independently.
struct FontStyle {
  std::uint32_t familyId{};
  float pointSize{};
  std::uint16_t weight{};
  bool italic{};

  friend constexpr bool operator==(const FontStyle&, const FontStyle&) = default;
};

class ITextMetrics {
 public:
  virtual ~ITextMetrics() = default;

  [[nodiscard]] virtual float advance(SakuraChar character,
                                      const FontStyle& style) const = 0;
  // A cluster is an extended grapheme (UTF-16), not necessarily one code
  // point. Platform adapters can shape the entire cluster, for example a ZWJ
  // emoji or a base letter plus combining marks. The default preserves the
  // code-unit metrics contract of existing adapters.
  [[nodiscard]] virtual float advanceCluster(SakuraStringView cluster,
                                             const FontStyle& style) const;
  [[nodiscard]] virtual float lineHeight(const FontStyle& style) const = 0;
};

struct LayoutOptions {
  // A non-positive value disables soft wrapping.
  float wrapWidth{};
  TextOffset tabWidth{4};
};

struct VisualLine {
  std::size_t logicalLine{};
  TextOffset startColumn{};
  TextOffset endColumn{};
  float width{};
  float height{};

  [[nodiscard]] bool isEmpty() const noexcept {
    return startColumn == endColumn;
  }
};

struct LayoutResult {
  std::vector<VisualLine> visualLines;
  float lineHeight{};

  // The end column belongs to the preceding visual line.  Callers that need
  // affinity at a soft-wrap boundary can retain it at their view layer.
  [[nodiscard]] std::size_t visualLineFor(TextPosition position) const;
};

class LayoutEngine {
 public:
  [[nodiscard]] LayoutResult layout(const TextBuffer& buffer,
                                    const ITextMetrics& metrics,
                                    const FontStyle& style,
                                    const LayoutOptions& options) const;
};

}  // namespace sakura::core

#endif  // SAKURA_CORE_LAYOUT_LAYOUT_ENGINE_H_
