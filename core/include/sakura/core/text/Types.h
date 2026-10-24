// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#ifndef SAKURA_CORE_TEXT_TYPES_H_
#define SAKURA_CORE_TEXT_TYPES_H_

#include <cstdint>
#include <string>
#include <string_view>

namespace sakura::core {

using SakuraChar = char16_t;
using SakuraString = std::u16string;
using SakuraStringView = std::u16string_view;
using TextOffset = std::uint64_t;

struct TextRange {
  TextOffset location{};
  TextOffset length{};

  friend constexpr bool operator==(const TextRange&, const TextRange&) = default;
};

struct TextPosition {
  std::size_t line{};
  TextOffset column{};

  friend constexpr bool operator==(const TextPosition&, const TextPosition&) = default;
};

}  // namespace sakura::core

#endif  // SAKURA_CORE_TEXT_TYPES_H_
