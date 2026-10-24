// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include "sakura/core/encoding/Utf16Codec.h"

namespace sakura::core {
namespace {

constexpr bool isHighSurrogate(SakuraChar value) noexcept {
  return value >= u'\xD800' && value <= u'\xDBFF';
}

constexpr bool isLowSurrogate(SakuraChar value) noexcept {
  return value >= u'\xDC00' && value <= u'\xDFFF';
}

unsigned char byteAt(std::span<const std::byte> data, std::size_t index) {
  return std::to_integer<unsigned char>(data[index]);
}

SakuraChar decodeCodeUnit(std::span<const std::byte> data, std::size_t offset,
                          Utf16ByteOrder byteOrder) {
  const auto first = byteAt(data, offset);
  const auto second = byteAt(data, offset + 1);
  if (byteOrder == Utf16ByteOrder::littleEndian) {
    return static_cast<SakuraChar>(first | (second << 8));
  }
  return static_cast<SakuraChar>((first << 8) | second);
}

void appendCodeUnit(std::vector<std::byte>& output, SakuraChar value,
                    Utf16ByteOrder byteOrder) {
  const auto lower = static_cast<unsigned char>(value & 0x00FFU);
  const auto upper = static_cast<unsigned char>((value >> 8) & 0x00FFU);
  if (byteOrder == Utf16ByteOrder::littleEndian) {
    output.push_back(static_cast<std::byte>(lower));
    output.push_back(static_cast<std::byte>(upper));
  } else {
    output.push_back(static_cast<std::byte>(upper));
    output.push_back(static_cast<std::byte>(lower));
  }
}

DecodeResult decodeFailure(SakuraString text, bool hadBom, std::size_t offset,
                           std::string message) {
  return {std::move(text), hadBom,
          CodecError{offset, CodecOffsetUnit::inputByte, std::move(message)}};
}

}  // namespace

DecodeResult Utf16Codec::decode(std::span<const std::byte> data,
                                Utf16ByteOrder byteOrder) {
  std::size_t cursor = 0;
  bool hadBom = false;
  if (data.size() >= 2) {
    const auto first = byteAt(data, 0);
    const auto second = byteAt(data, 1);
    if (first == 0xFF && second == 0xFE) {
      byteOrder = Utf16ByteOrder::littleEndian;
      hadBom = true;
      cursor = 2;
    } else if (first == 0xFE && second == 0xFF) {
      byteOrder = Utf16ByteOrder::bigEndian;
      hadBom = true;
      cursor = 2;
    }
  }

  if ((data.size() - cursor) % 2 != 0) {
    return decodeFailure({}, hadBom, data.size() - 1,
                         "UTF-16 input has an incomplete code unit");
  }

  SakuraString text;
  text.reserve((data.size() - cursor) / 2);
  while (cursor < data.size()) {
    const auto characterOffset = cursor;
    const auto character = decodeCodeUnit(data, cursor, byteOrder);
    cursor += 2;

    if (isHighSurrogate(character)) {
      if (cursor == data.size()) {
        return decodeFailure(std::move(text), hadBom, characterOffset,
                             "unpaired UTF-16 high surrogate");
      }
      const auto low = decodeCodeUnit(data, cursor, byteOrder);
      if (!isLowSurrogate(low)) {
        return decodeFailure(std::move(text), hadBom, characterOffset,
                             "unpaired UTF-16 high surrogate");
      }
      text.push_back(character);
      text.push_back(low);
      cursor += 2;
      continue;
    }
    if (isLowSurrogate(character)) {
      return decodeFailure(std::move(text), hadBom, characterOffset,
                           "unpaired UTF-16 low surrogate");
    }
    text.push_back(character);
  }

  return {std::move(text), hadBom, std::nullopt};
}

EncodeResult Utf16Codec::encode(SakuraStringView text, Utf16ByteOrder byteOrder,
                                BomPolicy bomPolicy, bool sourceHadBom) {
  const bool writeBom = bomPolicy == BomPolicy::always ||
                        (bomPolicy == BomPolicy::preserve && sourceHadBom);
  std::vector<std::byte> output;
  output.reserve((text.size() + (writeBom ? 1 : 0)) * 2);
  if (writeBom) {
    appendCodeUnit(output, 0xFEFF, byteOrder);
  }

  for (std::size_t index = 0; index < text.size(); ++index) {
    const auto character = text[index];
    if (isHighSurrogate(character)) {
      if (index + 1 >= text.size() || !isLowSurrogate(text[index + 1])) {
        return {std::move(output),
                CodecError{index, CodecOffsetUnit::utf16CodeUnit,
                           "unpaired UTF-16 high surrogate"}};
      }
      appendCodeUnit(output, character, byteOrder);
      appendCodeUnit(output, text[++index], byteOrder);
      continue;
    }
    if (isLowSurrogate(character)) {
      return {std::move(output),
              CodecError{index, CodecOffsetUnit::utf16CodeUnit,
                         "unpaired UTF-16 low surrogate"}};
    }
    appendCodeUnit(output, character, byteOrder);
  }

  return {std::move(output), std::nullopt};
}

}  // namespace sakura::core
