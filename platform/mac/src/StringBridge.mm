// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include "sakura/platform/mac/StringBridge.h"

#include <limits>
#include <stdexcept>

namespace sakura::platform::mac {

NSString* stringFromSakuraString(core::SakuraStringView text) {
  static_assert(sizeof(core::SakuraChar) == sizeof(unichar));
  if (text.empty()) {
    return @"";
  }
  if (text.size() > std::numeric_limits<NSUInteger>::max()) {
    throw std::length_error("text is too large for NSString");
  }
  return [[NSString alloc]
      initWithCharacters:reinterpret_cast<const unichar*>(text.data())
                  length:static_cast<NSUInteger>(text.size())];
}

core::SakuraString sakuraStringFromString(NSString* text) {
  static_assert(sizeof(core::SakuraChar) == sizeof(unichar));
  const NSUInteger length = text.length;
  core::SakuraString result(length, u'\0');
  if (length != 0) {
    [text getCharacters:reinterpret_cast<unichar*>(result.data())
                  range:NSMakeRange(0, length)];
  }
  return result;
}

}  // namespace sakura::platform::mac
