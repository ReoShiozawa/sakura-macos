// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#pragma once
#include "sakura/core/syntax/SyntaxHighlighter.h"
#include <functional>
#include <optional>
#include <string>

namespace sakura::core {
struct CustomSyntaxGroup {
  std::vector<SakuraString> keywords;
  std::vector<SakuraString> patterns;
  bool caseSensitive{true};
};
struct CustomSyntaxRules {
  std::vector<SakuraString> keywords;
  std::vector<SakuraString> patterns;
  bool caseSensitive{true};
  std::vector<CustomSyntaxGroup> additionalGroups; // Groups 2..10; group 1 remains backward-compatible.
};
enum class CustomSyntaxStatus { ok, cancelled, invalidRules, tooLarge, tooManyMatches, timedOut };
struct CustomSyntaxResult {
  std::vector<SyntaxToken> tokens; // Additional keyword tokens only, never overlapping base tokens.
  CustomSyntaxStatus status{CustomSyntaxStatus::ok};
};
inline constexpr std::size_t kCustomSyntaxTextLimit = 2 * 1024 * 1024;
inline constexpr std::size_t kCustomSyntaxLineLimit = 100000;
inline constexpr std::size_t kCustomSyntaxMatchLimit = 10000;
[[nodiscard]] std::optional<std::string> validateCustomSyntaxRules(const CustomSyntaxRules& rules);
[[nodiscard]] CustomSyntaxResult highlightCustomSyntax(
    const TextBuffer& buffer, const std::vector<SyntaxToken>& base,
    const CustomSyntaxRules& rules, std::function<bool()> cancelled = {});
}  // namespace sakura::core
