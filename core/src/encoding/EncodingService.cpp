// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include "sakura/core/encoding/EncodingService.h"

#include "sakura/core/encoding/Utf8Codec.h"

namespace sakura::core {
namespace {

unsigned char byteAt(std::span<const std::byte> data, std::size_t index) {
  return std::to_integer<unsigned char>(data[index]);
}

TextEncoding bomEncoding(std::span<const std::byte> data) noexcept {
  if (data.size() >= 3 && byteAt(data, 0) == 0xEF && byteAt(data, 1) == 0xBB &&
      byteAt(data, 2) == 0xBF) {
    return TextEncoding::utf8;
  }
  if (data.size() >= 2 && byteAt(data, 0) == 0xFF && byteAt(data, 1) == 0xFE) {
    return TextEncoding::utf16LittleEndian;
  }
  if (data.size() >= 2 && byteAt(data, 0) == 0xFE && byteAt(data, 1) == 0xFF) {
    return TextEncoding::utf16BigEndian;
  }
  return TextEncoding::automatic;
}

TextEncoding effectiveEncoding(TextEncoding requested,
                               std::span<const std::byte> data) noexcept {
  const auto detectedBom = bomEncoding(data);
  if (detectedBom != TextEncoding::automatic) {
    return detectedBom;
  }
  return requested == TextEncoding::automatic ? TextEncoding::utf8 : requested;
}

TextDecodeResult makeDecodeResult(DecodeResult result, TextEncoding encoding) {
  return {std::move(result.text), {encoding, result.hadBom}, std::move(result.error)};
}

TextEncodeResult makeEncodeResult(EncodeResult result, EncodingState state) {
  return {std::move(result.bytes), state, std::move(result.error)};
}

TextDecodeResult unsupportedDecode(TextEncoding encoding) {
  return {{}, {encoding, false},
          CodecError{0, CodecOffsetUnit::inputByte,
                     "encoding requires a platform codec adapter"}};
}

TextEncodeResult unsupportedEncode(TextEncoding encoding) {
  return {{}, {encoding, false},
          CodecError{0, CodecOffsetUnit::utf16CodeUnit,
                     "encoding requires a platform codec adapter"}};
}

}  // namespace

TextDecodeResult EncodingService::decode(std::span<const std::byte> data,
                                         TextEncoding requestedEncoding) const {
  const auto encoding = effectiveEncoding(requestedEncoding, data);
  switch (encoding) {
    case TextEncoding::utf8:
      return makeDecodeResult(Utf8Codec::decode(data), encoding);
    case TextEncoding::utf16LittleEndian:
      return makeDecodeResult(
          Utf16Codec::decode(data, Utf16ByteOrder::littleEndian), encoding);
    case TextEncoding::utf16BigEndian:
      return makeDecodeResult(Utf16Codec::decode(data, Utf16ByteOrder::bigEndian),
                              encoding);
    case TextEncoding::shiftJis:
    case TextEncoding::eucJp:
    case TextEncoding::iso2022Jp:
      return unsupportedDecode(encoding);
    case TextEncoding::automatic:
      break;
  }
  return {};
}

TextEncodeResult EncodingService::encode(SakuraStringView text,
                                         EncodingState sourceState,
                                         BomPolicy bomPolicy) const {
  const auto encoding = sourceState.encoding == TextEncoding::automatic
                            ? TextEncoding::utf8
                            : sourceState.encoding;
  const bool outputHasBom = bomPolicy == BomPolicy::always ||
                            (bomPolicy == BomPolicy::preserve && sourceState.hadBom);
  const EncodingState outputState{encoding, outputHasBom};
  switch (encoding) {
    case TextEncoding::utf8:
      return makeEncodeResult(
          Utf8Codec::encode(text, bomPolicy, sourceState.hadBom), outputState);
    case TextEncoding::utf16LittleEndian:
      return makeEncodeResult(Utf16Codec::encode(text, Utf16ByteOrder::littleEndian,
                                                  bomPolicy, sourceState.hadBom),
                              outputState);
    case TextEncoding::utf16BigEndian:
      return makeEncodeResult(Utf16Codec::encode(text, Utf16ByteOrder::bigEndian,
                                                  bomPolicy, sourceState.hadBom),
                              outputState);
    case TextEncoding::shiftJis:
    case TextEncoding::eucJp:
    case TextEncoding::iso2022Jp:
      return unsupportedEncode(encoding);
    case TextEncoding::automatic:
      break;
  }
  return {};
}

std::string_view EncodingService::name(TextEncoding encoding) noexcept {
  switch (encoding) {
    case TextEncoding::automatic:
      return "Auto";
    case TextEncoding::utf8:
      return "UTF-8";
    case TextEncoding::utf16LittleEndian:
      return "UTF-16LE";
    case TextEncoding::utf16BigEndian:
      return "UTF-16BE";
    case TextEncoding::shiftJis:
      return "Shift_JIS (CP932)";
    case TextEncoding::eucJp:
      return "EUC-JP";
    case TextEncoding::iso2022Jp:
      return "ISO-2022-JP";
  }
  return "Unknown";
}

const IEncodingService& defaultEncodingService() noexcept {
  static const EncodingService service;
  return service;
}

}  // namespace sakura::core
