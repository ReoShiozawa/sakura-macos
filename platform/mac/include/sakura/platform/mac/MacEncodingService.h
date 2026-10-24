// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#ifndef SAKURA_PLATFORM_MAC_MAC_ENCODING_SERVICE_H_
#define SAKURA_PLATFORM_MAC_MAC_ENCODING_SERVICE_H_

#include "sakura/core/encoding/EncodingService.h"

namespace sakura::platform::mac {

// macOS Core Foundation adapter.  The portable core owns BOM/UTF codecs; this
// adapter supplies the Japanese legacy codecs available in the operating system.
class MacEncodingService final : public core::IEncodingService {
 public:
  [[nodiscard]] core::TextDecodeResult decode(
      std::span<const std::byte> data,
      core::TextEncoding requestedEncoding = core::TextEncoding::automatic) const override;
  [[nodiscard]] core::TextEncodeResult encode(
      core::SakuraStringView text,
      core::EncodingState sourceState,
      core::BomPolicy bomPolicy = core::BomPolicy::preserve) const override;
};

[[nodiscard]] const MacEncodingService& macEncodingService() noexcept;

}  // namespace sakura::platform::mac

#endif  // SAKURA_PLATFORM_MAC_MAC_ENCODING_SERVICE_H_
