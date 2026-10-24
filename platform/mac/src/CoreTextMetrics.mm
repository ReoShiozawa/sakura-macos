// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include "sakura/platform/mac/CoreTextMetrics.h"

#import <CoreText/CoreText.h>

#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <string>

namespace sakura::platform::mac {

CoreTextMetrics::CoreTextMetrics(std::string_view postScriptName,
                                 float pointSize, float extraSpacing)
    : extraSpacing_(std::isfinite(extraSpacing) ? extraSpacing : 0.0F) {
  asciiAdvances_.fill(-1.0F);
  const std::string name(postScriptName);
  CFStringRef family = CFStringCreateWithCString(
      kCFAllocatorDefault, name.c_str(), kCFStringEncodingUTF8);
  font_ = CTFontCreateWithName(family, std::max(1.0F, pointSize), nullptr);
  CFRelease(family);

  const double spacing = extraSpacing_;
  const int ligatures = 0;
  CFNumberRef kern = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &spacing);
  CFNumberRef ligature = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &ligatures);
  const void* keys[] = {kCTFontAttributeName, kCTKernAttributeName, kCTLigatureAttributeName};
  const void* values[] = {font_, kern, ligature};
  attributes_ = CFDictionaryCreate(
      kCFAllocatorDefault, keys, values, 3, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFRelease(kern);
  CFRelease(ligature);

  const auto font = static_cast<CTFontRef>(font_);
  lineHeight_ = std::ceil(CTFontGetAscent(font) + CTFontGetDescent(font) +
                          CTFontGetLeading(font)) +
                3.0F;
}

CoreTextMetrics::~CoreTextMetrics() {
  if (attributes_ != nullptr) {
    CFRelease(static_cast<CFDictionaryRef>(attributes_));
  }
  if (font_ != nullptr) {
    CFRelease(static_cast<CTFontRef>(font_));
  }
}

float CoreTextMetrics::advance(core::SakuraChar character,
                               const core::FontStyle& style) const {
  (void)style;
  const auto unitIndex = static_cast<std::size_t>(character);
  if (unitIndex < asciiAdvances_.size()) {
    const auto width = asciiAdvances_[unitIndex];
    if (width >= 0.0F) return width;
  } else {
    const auto cached = advances_.find(character);
    if (cached != advances_.end()) return cached->second;
  }

  const float width = measure(core::SakuraStringView(&character, 1));
  if (unitIndex < asciiAdvances_.size()) asciiAdvances_[unitIndex] = width;
  else advances_.emplace(character, width);
  return width;
}

float CoreTextMetrics::advanceCluster(core::SakuraStringView cluster,
                                      const core::FontStyle& style) const {
  if (cluster.empty()) return 0.0F;
  if (cluster.size() == 1) return advance(cluster.front(), style);
  constexpr std::size_t maxCachedUnits = 64;
  constexpr std::size_t maxCachedClusters = 4096;
  if (cluster.size() > maxCachedUnits) return measure(cluster);
  const core::SakuraString key(cluster);
  const auto cached = clusterAdvances_.find(key);
  if (cached != clusterAdvances_.end()) return cached->second;
  const auto width = measure(cluster);
  if (clusterAdvances_.size() >= maxCachedClusters) clusterAdvances_.clear();
  clusterAdvances_.emplace(key, width);
  return width;
}

float CoreTextMetrics::measure(core::SakuraStringView text) const {
  if (text.size() > static_cast<std::size_t>(std::numeric_limits<CFIndex>::max())) {
    throw std::length_error("text measurement exceeds Core Text length range");
  }
  static_assert(sizeof(UniChar) == sizeof(core::SakuraChar));
  CFStringRef string = CFStringCreateWithCharacters(kCFAllocatorDefault,
      reinterpret_cast<const UniChar*>(text.data()), static_cast<CFIndex>(text.size()));
  CFAttributedStringRef attributed = CFAttributedStringCreate(
      kCFAllocatorDefault, string, static_cast<CFDictionaryRef>(attributes_));
  CTLineRef line = CTLineCreateWithAttributedString(attributed);
  const float width = static_cast<float>(std::max<CGFloat>(
      0.0, CTLineGetTypographicBounds(line, nullptr, nullptr, nullptr)));
  CFRelease(line);
  CFRelease(attributed);
  CFRelease(string);
  return std::isfinite(width) ? width : 0.0F;
}

float CoreTextMetrics::lineHeight(const core::FontStyle& style) const {
  (void)style;
  return lineHeight_;
}

}  // namespace sakura::platform::mac
