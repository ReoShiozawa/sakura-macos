// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// Copyright (C) 2006, 2007, 2018-2022, Sakura Editor Organization
// SPDX-License-Identifier: Zlib
// The byte-evidence tie breaker is an altered port of CESI::GuessEucOrSjis
// and codechecker.h. This is not the original Windows detector implementation.

#include "sakura/platform/mac/MacEncodingService.h"

#import <CoreFoundation/CoreFoundation.h>
#import <CoreFoundation/CFStringEncodingExt.h>
#import <Foundation/Foundation.h>

#include <algorithm>

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

struct JapaneseByteEvidence {
  bool valid{true};
  std::size_t encodedBytes{};
  std::size_t kanaBytes{};
  std::size_t halfKanaBytes{};
};

JapaneseByteEvidence japaneseByteEvidence(std::span<const std::byte> data,
                                         core::TextEncoding encoding) noexcept {
  JapaneseByteEvidence evidence;
  const auto byteAt = [data](std::size_t offset) {
    return std::to_integer<unsigned char>(data[offset]);
  };
  const auto eucTrail = [](unsigned char value) { return value >= 0xA1 && value <= 0xFE; };
  for (std::size_t cursor = 0; cursor < data.size();) {
    const auto first = byteAt(cursor);
    if (first < 0x80) { ++cursor; continue; }
    std::size_t width = 1;
    if (encoding == core::TextEncoding::shiftJis) {
      if ((first >= 0x81 && first <= 0x9F) || (first >= 0xE0 && first <= 0xFC)) {
        if (data.size() - cursor < 2) return {false};
        const auto second = byteAt(cursor + 1);
        if (!((second >= 0x40 && second <= 0x7E) || (second >= 0x80 && second <= 0xFC)))
          return {false};
        width = 2;
      }
      // CP932 also has single-byte extensions at 80/A0/FD/FE/FF. The final
      // Core Foundation conversion must still validate the actual mapping.
    } else {
      if (first == 0x8F) {
        width = 3;
        if (data.size() - cursor < width || !eucTrail(byteAt(cursor + 1)) ||
            !eucTrail(byteAt(cursor + 2))) return {false};
      } else if (first == 0x8E) {
        width = 2;
        if (data.size() - cursor < width || byteAt(cursor + 1) < 0xA1 ||
            byteAt(cursor + 1) > 0xDF) return {false};
        evidence.halfKanaBytes += width;
      } else {
        width = 2;
        if (!eucTrail(first) || data.size() - cursor < width ||
            !eucTrail(byteAt(cursor + 1))) return {false};
        const auto second = byteAt(cursor + 1);
        if ((first == 0xA4 && second <= 0xF3) || (first == 0xA5 && second <= 0xF6))
          evidence.kanaBytes += width;
      }
    }
    evidence.encodedBytes += width;
    cursor += width;
  }
  return evidence;
}

core::TextEncoding platformJapaneseGuess(std::span<const std::byte> data) {
  // The Foundation detector is a hint, never the decoder or a validator. Bound
  // the OS's analysis and avoid a large extra string/copy in a file-open path.
  auto sample = data.first(std::min<std::size_t>(data.size(), 64U * 1024U));
  for (int attempt = 0; attempt < 3 && !sample.empty(); ++attempt) {
    if (japaneseByteEvidence(sample, core::TextEncoding::shiftJis).valid &&
        japaneseByteEvidence(sample, core::TextEncoding::eucJp).valid) break;
    sample = sample.first(sample.size() - 1);
  }
  if (sample.size() < 32 ||
      !japaneseByteEvidence(sample, core::TextEncoding::shiftJis).valid ||
      !japaneseByteEvidence(sample, core::TextEncoding::eucJp).valid)
    return core::TextEncoding::automatic;

  @autoreleasepool {
    NSData* input = [NSData dataWithBytesNoCopy:const_cast<std::byte*>(sample.data())
                                       length:sample.size() freeWhenDone:NO];
    const auto sjis = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingDOSJapanese);
    const auto euc = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingEUC_JP);
    NSStringEncoding guesses[2]{};
    for (int order = 0; order < 2; ++order) {
      // Suggested-encoding order itself influences Foundation's preference.
      // Accept a hint only when reversing that order gives the same answer.
      BOOL lossy = NO;
      guesses[order] = [NSString stringEncodingForData:input encodingOptions:@{
        NSStringEncodingDetectionSuggestedEncodingsKey: order == 0 ? @[@(sjis), @(euc)] : @[@(euc), @(sjis)],
        NSStringEncodingDetectionUseOnlySuggestedEncodingsKey: @YES,
        NSStringEncodingDetectionAllowLossyKey: @NO,
        NSStringEncodingDetectionLikelyLanguageKey: @"ja"
      } convertedString:nullptr usedLossyConversion:&lossy];
      if (lossy) return core::TextEncoding::automatic;
    }
    if (guesses[0] != guesses[1]) return core::TextEncoding::automatic;
    if (guesses[0] == sjis) return core::TextEncoding::shiftJis;
    if (guesses[0] == euc) return core::TextEncoding::eucJp;
  }
  return core::TextEncoding::automatic;
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
    auto result = decodeLegacy(data, requestedEncoding);
    result.detection.method = core::EncodingDetectionMethod::explicitEncoding;
    return result;
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
      iso2022.detection.method = core::EncodingDetectionMethod::iso2022Escape;
      return iso2022;
    }
  }
  if (portable.ok()) {
    return portable;
  }
  const auto sjis = japaneseByteEvidence(data, core::TextEncoding::shiftJis);
  const auto euc = japaneseByteEvidence(data, core::TextEncoding::eucJp);
  const bool ambiguous = sjis.valid && euc.valid;
  auto preferred = core::TextEncoding::shiftJis;
  auto method = core::EncodingDetectionMethod::bytePattern;
  if (!sjis.valid && euc.valid) preferred = core::TextEncoding::eucJp;
  if (ambiguous) {
    method = core::EncodingDetectionMethod::fallback;
    // CESI counts encoded bytes and, on a tie, promotes EUC-JP when at least
    // 25% of those bytes encode full-width hiragana/katakana. This is evidence,
    // not certainty: the same bytes may intentionally encode CP932 half-kana.
    if (euc.encodedBytes > sjis.encodedBytes ||
        (euc.encodedBytes == sjis.encodedBytes && euc.encodedBytes != 0 &&
         (euc.kanaBytes >= euc.encodedBytes / 4 + (euc.encodedBytes % 4 != 0) ||
          // Extension to CESI: repeated SS2 half-kana are also useful evidence.
          // A single 8E xx is not enough (it can be an ordinary CP932 kanji).
          (euc.halfKanaBytes >= 8 &&
           euc.halfKanaBytes >= euc.encodedBytes / 2 + (euc.encodedBytes % 2 != 0))))) {
      preferred = core::TextEncoding::eucJp;
      method = core::EncodingDetectionMethod::japaneseHeuristic;
    } else if (sjis.encodedBytes > euc.encodedBytes) {
      method = core::EncodingDetectionMethod::japaneseHeuristic;
    } else {
      const auto guess = platformJapaneseGuess(data);
      if (guess != core::TextEncoding::automatic) {
        preferred = guess;
        method = core::EncodingDetectionMethod::platformHeuristic;
      }
    }
  }
  auto decoded = decodeLegacy(data, preferred);
  if (decoded.ok()) {
    decoded.detection = {method, ambiguous};
    return decoded;
  }
  const auto other = preferred == core::TextEncoding::shiftJis
      ? core::TextEncoding::eucJp : core::TextEncoding::shiftJis;
  auto alternative = decodeLegacy(data, other);
  if (alternative.ok()) {
    alternative.detection.method = core::EncodingDetectionMethod::bytePattern;
    return alternative;
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
