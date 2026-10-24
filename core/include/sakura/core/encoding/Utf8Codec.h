// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#ifndef SAKURA_CORE_ENCODING_UTF8_CODEC_H_
#define SAKURA_CORE_ENCODING_UTF8_CODEC_H_

#include <span>

#include "sakura/core/encoding/TextCodec.h"

namespace sakura::core {

class Utf8Codec {
 public:
  [[nodiscard]] static DecodeResult decode(std::span<const std::byte> data);
  [[nodiscard]] static EncodeResult encode(
      SakuraStringView text,
      BomPolicy bomPolicy = BomPolicy::never,
      bool sourceHadBom = false);
};

}  // namespace sakura::core

#endif  // SAKURA_CORE_ENCODING_UTF8_CODEC_H_
