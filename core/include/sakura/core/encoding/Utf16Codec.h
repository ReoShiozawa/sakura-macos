// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#ifndef SAKURA_CORE_ENCODING_UTF16_CODEC_H_
#define SAKURA_CORE_ENCODING_UTF16_CODEC_H_

#include <span>

#include "sakura/core/encoding/TextCodec.h"

namespace sakura::core {

enum class Utf16ByteOrder {
  littleEndian,
  bigEndian,
};

// UTF-16 uses the portable core's native char16_t code units.  The byte-order
// conversion and BOM validation live here so platform adapters never depend on
// wchar_t size or native endianness.
class Utf16Codec {
 public:
  [[nodiscard]] static DecodeResult decode(std::span<const std::byte> data,
                                            Utf16ByteOrder byteOrder);
  [[nodiscard]] static EncodeResult encode(
      SakuraStringView text,
      Utf16ByteOrder byteOrder,
      BomPolicy bomPolicy = BomPolicy::never,
      bool sourceHadBom = false);
};

}  // namespace sakura::core

#endif  // SAKURA_CORE_ENCODING_UTF16_CODEC_H_
