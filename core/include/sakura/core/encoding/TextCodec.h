// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#ifndef SAKURA_CORE_ENCODING_TEXT_CODEC_H_
#define SAKURA_CORE_ENCODING_TEXT_CODEC_H_

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "sakura/core/text/Types.h"

namespace sakura::core {

enum class BomPolicy {
  preserve,
  always,
  never,
};

enum class CodecOffsetUnit {
  inputByte,
  utf16CodeUnit,
};

struct CodecError {
  std::uint64_t offset{};
  CodecOffsetUnit offsetUnit{CodecOffsetUnit::inputByte};
  std::string message;
};

struct DecodeResult {
  SakuraString text;
  bool hadBom{};
  std::optional<CodecError> error;

  [[nodiscard]] bool ok() const noexcept { return !error.has_value(); }
};

struct EncodeResult {
  std::vector<std::byte> bytes;
  std::optional<CodecError> error;

  [[nodiscard]] bool ok() const noexcept { return !error.has_value(); }
};

}  // namespace sakura::core

#endif  // SAKURA_CORE_ENCODING_TEXT_CODEC_H_
