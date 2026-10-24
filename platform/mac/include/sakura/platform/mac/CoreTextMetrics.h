// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#ifndef SAKURA_PLATFORM_MAC_CORE_TEXT_METRICS_H_
#define SAKURA_PLATFORM_MAC_CORE_TEXT_METRICS_H_

#include <array>
#include <string_view>
#include <unordered_map>

#include "sakura/core/layout/LayoutEngine.h"

namespace sakura::platform::mac {

// Core Text adapter for the platform-independent LayoutEngine.  The adapter
// owns its CTFont internally, so Core Foundation types do not escape into the
// portable core headers.
class CoreTextMetrics final : public core::ITextMetrics {
 public:
  CoreTextMetrics(std::string_view postScriptName, float pointSize,
                  float extraSpacing = 0.0F);
  ~CoreTextMetrics() override;

  CoreTextMetrics(const CoreTextMetrics&) = delete;
  CoreTextMetrics& operator=(const CoreTextMetrics&) = delete;

  [[nodiscard]] float advance(core::SakuraChar character,
                              const core::FontStyle& style) const override;
  [[nodiscard]] float advanceCluster(core::SakuraStringView cluster,
                                     const core::FontStyle& style) const override;
  [[nodiscard]] float lineHeight(const core::FontStyle& style) const override;

 private:
  [[nodiscard]] float measure(core::SakuraStringView text) const;
  const void* font_{};
  const void* attributes_{};
  float lineHeight_{};
  float extraSpacing_{};
  // Most source documents repeatedly use ASCII. Avoid a hash lookup for each
  // code unit during full-document layout; non-ASCII widths remain lazy.
  mutable std::array<float, 128> asciiAdvances_;
  mutable std::unordered_map<core::SakuraChar, float> advances_;
  // Repeated composed emoji/combining sequences are measured as a whole.
  // Huge or highly diverse clusters must not grow a document-sized cache.
  mutable std::unordered_map<core::SakuraString, float> clusterAdvances_;
};

}  // namespace sakura::platform::mac

#endif  // SAKURA_PLATFORM_MAC_CORE_TEXT_METRICS_H_
