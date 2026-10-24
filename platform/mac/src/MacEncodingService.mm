// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include "sakura/platform/mac/MacEncodingService.h"

#import <CoreFoundation/CoreFoundation.h>
#import <CoreFoundation/CFStringEncodingExt.h>

#include "sakura/core/encoding/Utf8Codec.h"

namespace sakura::platform::mac {
namespace {

CFStringEncoding coreFoundationEncoding(core::TextEncoding encoding) noexcept {
  switch (encoding) {
    case core::TextEncoding::shiftJis:
      return kCFStringEncodingDOSJapanese;  // Windows CP932 compatibility.
    case core::TextEncoding::eucJp:
      return kCFStringEncodingEUC_JP;
    case core::TextEncoding::iso2022Jp:
      return kCFStringEncodingISO_2022_JP;
    default:
      return kCFStringEncodingInvalidId;
  }
}

bool hasValidIso2022JapaneseText(std::span<const std::byte> data) noexcept {
  enum class CharacterSet { ascii, roman, katakana, jis208 };
  auto characterSet = CharacterSet::ascii;
  bool hasJapaneseDesignation = false;
  bool awaitingSecondByte = false;
  const auto byteAt = [data](std::size_t offset) {
    return std::to_integer<unsigned char>(data[offset]);
  };

  for (std::size_t cursor = 0; cursor < data.size(); ++cursor) {
    const auto value = byteAt(cursor);
    if (value == 0x1B) {
      // ESC alone also occurs in terminal output. Only accept recognized JIS
      // designations, with complete two-byte characters between switches.
      if (awaitingSecondByte || data.size() - cursor < 3) {
        return false;
      }
      const auto intermediate = byteAt(++cursor);
      const auto final = byteAt(++cursor);
      if (intermediate == 0x24 && (final == 0x40 || final == 0x42)) {
        characterSet = CharacterSet::jis208;
        hasJapaneseDesignation = true;
      } else if (intermediate == 0x28 && final == 0x42) {
        characterSet = CharacterSet::ascii;
      } else if (intermediate == 0x28 && final == 0x4A) {
        characterSet = CharacterSet::roman;
        hasJapaneseDesignation = true;
      } else if (intermediate == 0x28 && final == 0x49) {
        characterSet = CharacterSet::katakana;
        hasJapaneseDesignation = true;
      } else {
        return false;
      }
      continue;
    }
    if (value >= 0x80) {
      return false;
    }
    if (value <= 0x20 || value == 0x7F) {
      if (awaitingSecondByte) {
        return false;
      }
      continue;
    }
    if (characterSet == CharacterSet::jis208) {
      awaitingSecondByte = !awaitingSecondByte;
    } else if (characterSet == CharacterSet::katakana && value > 0x5F) {
      return false;
    }
  }
  // ESC ( B by itself is also an ANSI terminal designation. Require an actual
  // Japanese character set before trying the platform's validating decoder.
  return hasJapaneseDesignation && !awaitingSecondByte;
}

core::TextDecodeResult decodeLegacy(std::span<const std::byte> data,
                                    core::TextEncoding encoding) {
  const auto cfEncoding = coreFoundationEncoding(encoding);
  CFStringRef converted = CFStringCreateWithBytes(
      kCFAllocatorDefault, reinterpret_cast<const UInt8*>(data.data()),
      static_cast<CFIndex>(data.size()), cfEncoding, false);
  if (converted == nullptr) {
    return {{}, {encoding, false},
            core::CodecError{0, core::CodecOffsetUnit::inputByte,
                             "Core Foundation could not decode the input"}};
  }

  const auto length = CFStringGetLength(converted);
  core::SakuraString text(static_cast<std::size_t>(length), u'\0');
  if (length != 0) {
    CFStringGetCharacters(converted, CFRangeMake(0, length),
                          reinterpret_cast<UniChar*>(text.data()));
  }
  CFRelease(converted);
  return {std::move(text), {encoding, false}, std::nullopt};
}

core::TextEncodeResult encodeLegacy(core::SakuraStringView text,
                                    core::TextEncoding encoding) {
  // Reject malformed internal UTF-16 before handing it to Foundation.
  const auto utf8 = core::Utf8Codec::encode(text);
  if (!utf8.ok()) {
    return {{}, {encoding, false}, std::move(utf8.error)};
  }
  if (text.empty()) {
    return {{}, {encoding, false}, std::nullopt};
  }

  CFStringRef source = CFStringCreateWithCharacters(
      kCFAllocatorDefault, reinterpret_cast<const UniChar*>(text.data()),
      static_cast<CFIndex>(text.size()));
  if (source == nullptr) {
    return {{}, {encoding, false},
            core::CodecError{0, core::CodecOffsetUnit::utf16CodeUnit,
                             "Core Foundation could not create a UTF-16 string"}};
  }

  const auto cfEncoding = coreFoundationEncoding(encoding);
  const auto capacity = CFStringGetMaximumSizeForEncoding(
      CFStringGetLength(source), cfEncoding);
  std::vector<std::byte> bytes(static_cast<std::size_t>(capacity));
  CFIndex usedBytes = 0;
  const auto convertedCharacters = CFStringGetBytes(
      source, CFRangeMake(0, CFStringGetLength(source)), cfEncoding, 0, false,
      reinterpret_cast<UInt8*>(bytes.data()), capacity, &usedBytes);
  CFRelease(source);

  if (convertedCharacters != static_cast<CFIndex>(text.size())) {
    return {{}, {encoding, false},
            core::CodecError{static_cast<std::uint64_t>(convertedCharacters),
                             core::CodecOffsetUnit::utf16CodeUnit,
                             "the text contains a character not representable in the target encoding"}};
  }
  bytes.resize(static_cast<std::size_t>(usedBytes));
  return {std::move(bytes), {encoding, false}, std::nullopt};
}

bool isLegacyEncoding(core::TextEncoding encoding) noexcept {
  return coreFoundationEncoding(encoding) != kCFStringEncodingInvalidId;
}

}  // namespace

core::TextDecodeResult MacEncodingService::decode(
    std::span<const std::byte> data, core::TextEncoding requestedEncoding) const {
  if (isLegacyEncoding(requestedEncoding)) {
    return decodeLegacy(data, requestedEncoding);
  }

  if (requestedEncoding != core::TextEncoding::automatic) {
    return core::defaultEncodingService().decode(data, requestedEncoding);
  }

  auto portable = core::defaultEncodingService().decode(data);
  if (portable.state.hadBom) {
    // A Unicode BOM remains authoritative even when the body is malformed.
    return portable;
  }

  // ISO-2022-JP uses only ASCII bytes and therefore also passes UTF-8 decoding.
  // Recognize its complete escape syntax before accepting a BOM-less UTF-8
  // result, while leaving explicit encoding requests above unchanged.
  if (hasValidIso2022JapaneseText(data)) {
    auto iso2022 = decodeLegacy(data, core::TextEncoding::iso2022Jp);
    if (iso2022.ok()) {
      return iso2022;
    }
  }
  if (portable.ok()) {
    return portable;
  }
  for (const auto candidate : {core::TextEncoding::shiftJis,
                               core::TextEncoding::eucJp}) {
    auto decoded = decodeLegacy(data, candidate);
    if (decoded.ok()) {
      return decoded;
    }
  }
  return portable;
}

core::TextEncodeResult MacEncodingService::encode(
    core::SakuraStringView text, core::EncodingState sourceState,
    core::BomPolicy bomPolicy) const {
  if (isLegacyEncoding(sourceState.encoding)) {
    // Legacy Japanese encodings have no Unicode BOM representation.
    return encodeLegacy(text, sourceState.encoding);
  }
  return core::defaultEncodingService().encode(text, sourceState, bomPolicy);
}

const MacEncodingService& macEncodingService() noexcept {
  static const MacEncodingService service;
  return service;
}

}  // namespace sakura::platform::mac
