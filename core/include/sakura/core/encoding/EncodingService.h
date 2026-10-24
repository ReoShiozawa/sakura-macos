// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#ifndef SAKURA_CORE_ENCODING_ENCODING_SERVICE_H_
#define SAKURA_CORE_ENCODING_ENCODING_SERVICE_H_

#include <span>
#include <string_view>

#include "sakura/core/encoding/Utf16Codec.h"

namespace sakura::core {

enum class TextEncoding {
  automatic,
  utf8,
  utf16LittleEndian,
  utf16BigEndian,
  shiftJis,
  eucJp,
  iso2022Jp,
};

struct EncodingState {
  TextEncoding encoding{TextEncoding::utf8};
  bool hadBom{};

  friend constexpr bool operator==(const EncodingState&, const EncodingState&) = default;
};

struct TextDecodeResult {
  SakuraString text;
  EncodingState state;
  std::optional<CodecError> error;

  [[nodiscard]] bool ok() const noexcept { return !error.has_value(); }
};

struct TextEncodeResult {
  std::vector<std::byte> bytes;
  EncodingState state;
  std::optional<CodecError> error;

  [[nodiscard]] bool ok() const noexcept { return !error.has_value(); }
};

// Codec selection and BOM handling are portable.  The default implementation
// intentionally detects only unambiguous BOMs and valid UTF-8; platform
// adapters can add legacy codecs and locale-specific detection.
class IEncodingService {
 public:
  virtual ~IEncodingService() = default;

  [[nodiscard]] virtual TextDecodeResult decode(
      std::span<const std::byte> data,
      TextEncoding requestedEncoding = TextEncoding::automatic) const = 0;
  [[nodiscard]] virtual TextEncodeResult encode(
      SakuraStringView text,
      EncodingState sourceState,
      BomPolicy bomPolicy = BomPolicy::preserve) const = 0;
};

class EncodingService final : public IEncodingService {
 public:
  [[nodiscard]] TextDecodeResult decode(
      std::span<const std::byte> data,
      TextEncoding requestedEncoding = TextEncoding::automatic) const override;
  [[nodiscard]] TextEncodeResult encode(
      SakuraStringView text,
      EncodingState sourceState,
      BomPolicy bomPolicy = BomPolicy::preserve) const override;
  [[nodiscard]] static std::string_view name(TextEncoding encoding) noexcept;
};

[[nodiscard]] const IEncodingService& defaultEncodingService() noexcept;

}  // namespace sakura::core

#endif  // SAKURA_CORE_ENCODING_ENCODING_SERVICE_H_
