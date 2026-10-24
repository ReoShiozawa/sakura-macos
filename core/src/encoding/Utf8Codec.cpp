// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include "sakura/core/encoding/Utf8Codec.h"

#include <array>

namespace sakura::core {
namespace {

constexpr std::array<unsigned char, 3> kUtf8Bom{0xEF, 0xBB, 0xBF};

unsigned char byteAt(std::span<const std::byte> data, std::size_t index) {
  return std::to_integer<unsigned char>(data[index]);
}

bool isContinuation(unsigned char value) noexcept {
  return (value & 0xC0U) == 0x80U;
}

DecodeResult decodeFailure(SakuraString text, bool hadBom, std::size_t offset,
                           std::string message) {
  return {std::move(text), hadBom,
          CodecError{offset, CodecOffsetUnit::inputByte, std::move(message)}};
}

void appendCodePoint(SakuraString& output, char32_t value) {
  if (value <= 0xFFFF) {
    output.push_back(static_cast<SakuraChar>(value));
    return;
  }
  value -= 0x10000;
  output.push_back(static_cast<SakuraChar>(0xD800 + (value >> 10)));
  output.push_back(static_cast<SakuraChar>(0xDC00 + (value & 0x3FF)));
}

void appendByte(std::vector<std::byte>& output, unsigned char value) {
  output.push_back(static_cast<std::byte>(value));
}

}  // namespace

DecodeResult Utf8Codec::decode(std::span<const std::byte> data) {
  std::size_t cursor = 0;
  bool hadBom = false;
  if (data.size() >= kUtf8Bom.size() && byteAt(data, 0) == kUtf8Bom[0] &&
      byteAt(data, 1) == kUtf8Bom[1] && byteAt(data, 2) == kUtf8Bom[2]) {
    hadBom = true;
    cursor = kUtf8Bom.size();
  }

  SakuraString output;
  output.reserve(data.size() - cursor);
  while (cursor < data.size()) {
    const auto sequenceStart = cursor;
    const auto first = byteAt(data, cursor++);
    if (first <= 0x7F) {
      output.push_back(static_cast<SakuraChar>(first));
      continue;
    }

    std::size_t continuationCount = 0;
    char32_t value = 0;
    char32_t minimum = 0;
    if (first >= 0xC2 && first <= 0xDF) {
      continuationCount = 1;
      value = first & 0x1F;
      minimum = 0x80;
    } else if (first >= 0xE0 && first <= 0xEF) {
      continuationCount = 2;
      value = first & 0x0F;
      minimum = 0x800;
    } else if (first >= 0xF0 && first <= 0xF4) {
      continuationCount = 3;
      value = first & 0x07;
      minimum = 0x10000;
    } else {
      return decodeFailure(std::move(output), hadBom, sequenceStart,
                           "invalid UTF-8 leading byte");
    }

    if (data.size() - cursor < continuationCount) {
      return decodeFailure(std::move(output), hadBom, sequenceStart,
                           "truncated UTF-8 sequence");
    }
    for (std::size_t index = 0; index < continuationCount; ++index) {
      const auto next = byteAt(data, cursor++);
      if (!isContinuation(next)) {
        return decodeFailure(std::move(output), hadBom, cursor - 1,
                             "invalid UTF-8 continuation byte");
      }
      value = (value << 6) | (next & 0x3F);
    }

    if (value < minimum || value > 0x10FFFF ||
        (value >= 0xD800 && value <= 0xDFFF)) {
      return decodeFailure(std::move(output), hadBom, sequenceStart,
                           "invalid UTF-8 code point");
    }
    appendCodePoint(output, value);
  }

  return {std::move(output), hadBom, std::nullopt};
}

EncodeResult Utf8Codec::encode(SakuraStringView text, BomPolicy bomPolicy,
                               bool sourceHadBom) {
  std::vector<std::byte> output;
  const bool writeBom = bomPolicy == BomPolicy::always ||
                        (bomPolicy == BomPolicy::preserve && sourceHadBom);
  output.reserve(text.size() * 3 + (writeBom ? kUtf8Bom.size() : 0));
  if (writeBom) {
    for (const auto value : kUtf8Bom) {
      appendByte(output, value);
    }
  }

  for (std::size_t index = 0; index < text.size(); ++index) {
    char32_t value = text[index];
    if (value >= 0xD800 && value <= 0xDBFF) {
      if (index + 1 >= text.size() || text[index + 1] < 0xDC00 ||
          text[index + 1] > 0xDFFF) {
        return {std::move(output),
                CodecError{index, CodecOffsetUnit::utf16CodeUnit,
                           "unpaired UTF-16 high surrogate"}};
      }
      value = 0x10000 + ((value - 0xD800) << 10) + (text[++index] - 0xDC00);
    } else if (value >= 0xDC00 && value <= 0xDFFF) {
      return {std::move(output),
              CodecError{index, CodecOffsetUnit::utf16CodeUnit,
                         "unpaired UTF-16 low surrogate"}};
    }

    if (value <= 0x7F) {
      appendByte(output, static_cast<unsigned char>(value));
    } else if (value <= 0x7FF) {
      appendByte(output, static_cast<unsigned char>(0xC0 | (value >> 6)));
      appendByte(output, static_cast<unsigned char>(0x80 | (value & 0x3F)));
    } else if (value <= 0xFFFF) {
      appendByte(output, static_cast<unsigned char>(0xE0 | (value >> 12)));
      appendByte(output, static_cast<unsigned char>(0x80 | ((value >> 6) & 0x3F)));
      appendByte(output, static_cast<unsigned char>(0x80 | (value & 0x3F)));
    } else {
      appendByte(output, static_cast<unsigned char>(0xF0 | (value >> 18)));
      appendByte(output, static_cast<unsigned char>(0x80 | ((value >> 12) & 0x3F)));
      appendByte(output, static_cast<unsigned char>(0x80 | ((value >> 6) & 0x3F)));
      appendByte(output, static_cast<unsigned char>(0x80 | (value & 0x3F)));
    }
  }

  return {std::move(output), std::nullopt};
}

}  // namespace sakura::core
