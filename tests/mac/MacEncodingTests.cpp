// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include <cstddef>
#include <cmath>
#include <iostream>
#include <string_view>
#include <vector>

#include <CoreText/CoreText.h>

#include "sakura/app/DocumentSession.h"
#include "sakura/core/layout/LayoutEngine.h"
#include "sakura/platform/mac/CoreTextMetrics.h"
#include "sakura/platform/mac/MacEncodingService.h"

namespace {

using sakura::app::DocumentSession;
using sakura::core::SakuraString;
using sakura::core::TextEncoding;
using sakura::core::TextBuffer;
using sakura::platform::mac::macEncodingService;

int failures = 0;

void fail(std::string_view test, std::string_view expression, int line) {
  std::cerr << test << ':' << line << ": expectation failed: " << expression << '\n';
  ++failures;
}

#define EXPECT(test, expression) \
  do {                           \
    if (!(expression)) {         \
      fail(test, #expression, __LINE__); \
    }                            \
  } while (false)

std::vector<std::byte> bytes(std::initializer_list<unsigned int> values) {
  std::vector<std::byte> result;
  for (const auto value : values) {
    result.push_back(static_cast<std::byte>(value));
  }
  return result;
}

void decodesAndEncodesJapaneseCodecs() {
  constexpr std::string_view test = "decodesAndEncodesJapaneseCodecs";
  const auto& service = macEncodingService();

  const auto shiftJis = bytes({0x8D, 0xF7});  // 桜 in CP932
  const auto decodedShiftJis = service.decode(shiftJis, TextEncoding::shiftJis);
  EXPECT(test, decodedShiftJis.ok());
  EXPECT(test, decodedShiftJis.text == u"桜");
  const auto encodedShiftJis = service.encode(decodedShiftJis.text,
                                               decodedShiftJis.state);
  EXPECT(test, encodedShiftJis.ok());
  EXPECT(test, encodedShiftJis.bytes == shiftJis);

  const auto eucJp = bytes({0xA4, 0xB5, 0xA4, 0xAF, 0xA4, 0xE9});  // さくら
  const auto decodedEucJp = service.decode(eucJp, TextEncoding::eucJp);
  EXPECT(test, decodedEucJp.ok());
  EXPECT(test, decodedEucJp.text == u"さくら");
  EXPECT(test, service.encode(decodedEucJp.text, decodedEucJp.state).bytes == eucJp);

  const auto iso2022 = bytes({0x1B, 0x24, 0x42, 0x3C, 0x21, 0x1B, 0x28, 0x42});
  const auto decodedIso2022 = service.decode(iso2022, TextEncoding::iso2022Jp);
  EXPECT(test, decodedIso2022.ok());
  EXPECT(test, decodedIso2022.text == u"次");
  EXPECT(test, service.encode(decodedIso2022.text, decodedIso2022.state).bytes == iso2022);
}

void automaticDetectionAndDocumentSessionUseMacService() {
  constexpr std::string_view test = "automaticDetectionAndDocumentSessionUseMacService";
  const auto shiftJis = bytes({0x8D, 0xF7});
  const auto& service = macEncodingService();
  const auto detected = service.decode(shiftJis);
  EXPECT(test, detected.ok());
  EXPECT(test, detected.state.encoding == TextEncoding::shiftJis);

  DocumentSession document(service);
  EXPECT(test, document.load(shiftJis).ok());
  EXPECT(test, document.encodingState().encoding == TextEncoding::shiftJis);
  document.insert(1, u"!" );
  const auto saved = document.makeSaveSnapshot();
  EXPECT(test, saved.encoded.ok());
  EXPECT(test, saved.encoded.bytes == bytes({0x8D, 0xF7, 0x21}));

  // This EUC-JP sequence is not valid CP932: the final 0xF9 would need a trail
  // byte. Keep the existing fallback to EUC-JP when CP932 cannot decode input.
  const auto eucJp = bytes({0xBA, 0xF9});  // 桜
  const auto detectedEucJp = service.decode(eucJp);
  EXPECT(test, detectedEucJp.ok());
  EXPECT(test, detectedEucJp.text == u"桜");
  EXPECT(test, detectedEucJp.state.encoding == TextEncoding::eucJp);
  EXPECT(test, service.encode(detectedEucJp.text, detectedEucJp.state).bytes == eucJp);
}

void detectsIso2022BeforeAsciiAndPreservesItWhenSaving() {
  constexpr std::string_view test = "detectsIso2022BeforeAsciiAndPreservesItWhenSaving";
  const auto& service = macEncodingService();
  const auto iso2022 = bytes({0x1B, 0x24, 0x42, 0x24, 0x22, 0x1B, 0x28, 0x42});
  const auto detected = service.decode(iso2022);
  EXPECT(test, detected.ok());
  EXPECT(test, detected.text == u"あ");
  EXPECT(test, detected.state.encoding == TextEncoding::iso2022Jp);
  EXPECT(test, !detected.state.hadBom);

  DocumentSession document(service);
  EXPECT(test, document.load(iso2022).ok());
  EXPECT(test, document.encodingState().encoding == TextEncoding::iso2022Jp);
  EXPECT(test, document.makeSaveSnapshot().encoded.bytes == iso2022);
  document.insert(1, u"!");
  const auto saved = document.makeSaveSnapshot();
  EXPECT(test, saved.encoded.ok());
  auto expected = iso2022;
  expected.push_back(std::byte{0x21});
  EXPECT(test, saved.encoded.bytes == expected);
  EXPECT(test, service.decode(saved.encoded.bytes).text == u"あ!");

  const auto jis1978 = bytes({0x1B, 0x24, 0x40, 0x24, 0x22, 0x1B, 0x28, 0x42});
  const auto detected1978 = service.decode(jis1978);
  EXPECT(test, detected1978.ok());
  EXPECT(test, detected1978.text == u"あ");
  EXPECT(test, detected1978.state.encoding == TextEncoding::iso2022Jp);

  const auto explicitUtf8 = service.decode(iso2022, TextEncoding::utf8);
  EXPECT(test, explicitUtf8.ok());
  EXPECT(test, explicitUtf8.state.encoding == TextEncoding::utf8);
  EXPECT(test, explicitUtf8.text == u"\x1B$B$\"\x1B(B");
}

void doesNotMistakeAsciiOrTerminalEscapesForIso2022() {
  constexpr std::string_view test = "doesNotMistakeAsciiOrTerminalEscapesForIso2022";
  const auto& service = macEncodingService();
  const std::vector<std::vector<std::byte>> inputs{
      {},
      bytes({0x61, 0x62, 0x63, 0x0D, 0x0A}),
      bytes({0x1B}),
      bytes({0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x61, 0x1B, 0x5B, 0x30, 0x6D}),
      bytes({0x1B, 0x28, 0x42, 0x61}),
      bytes({0x1B, 0x24}),
      bytes({0x1B, 0x24, 0x58, 0x61}),
      bytes({0x1B, 0x24, 0x42, 0x24, 0x1B, 0x28, 0x42}),
      bytes({0x1B, 0x24, 0x42, 0x24}),
      bytes({0x1B, 0x24, 0x42, 0x24, 0x22, 0x1B, 0x5B, 0x30, 0x6D}),
      bytes({0xE6, 0xA1, 0x9C}),  // UTF-8 桜
  };
  for (const auto& input : inputs) {
    const auto expected = sakura::core::defaultEncodingService().decode(input);
    const auto detected = service.decode(input);
    EXPECT(test, detected.ok());
    EXPECT(test, detected.state.encoding == TextEncoding::utf8);
    EXPECT(test, detected.text == expected.text);
    EXPECT(test, service.encode(detected.text, detected.state).bytes == input);
  }
}

void unicodeBomsRemainAuthoritative() {
  constexpr std::string_view test = "unicodeBomsRemainAuthoritative";
  const auto& service = macEncodingService();
  const SakuraString text{u"\x1B$B$\"\x1B(B"};
  for (const auto encoding : {TextEncoding::utf8, TextEncoding::utf16LittleEndian,
                             TextEncoding::utf16BigEndian}) {
    const auto encoded = service.encode(text, {encoding, true});
    EXPECT(test, encoded.ok());
    DocumentSession document(service);
    const auto decoded = document.load(encoded.bytes);
    EXPECT(test, decoded.ok());
    EXPECT(test, decoded.text == text);
    EXPECT(test, document.encodingState().encoding == encoding);
    EXPECT(test, document.sourceHadBom());
    EXPECT(test, decoded.detection.method == sakura::core::EncodingDetectionMethod::unicodeBom);
    EXPECT(test, !decoded.detection.ambiguous);
    EXPECT(test, document.makeSaveSnapshot().encoded.bytes == encoded.bytes);
  }

  for (const auto& invalid : {
           bytes({0xEF, 0xBB, 0xBF, 0x8D, 0xF7}),  // CP932 after a UTF-8 BOM
           bytes({0xFF, 0xFE, 0x61}),              // Truncated UTF-16LE
           bytes({0xFE, 0xFF, 0x61}),              // Truncated UTF-16BE
       }) {
    const auto decoded = service.decode(invalid);
    EXPECT(test, !decoded.ok());
    EXPECT(test, decoded.state.hadBom);
    EXPECT(test, decoded.state.encoding != TextEncoding::shiftJis);
    EXPECT(test, decoded.state.encoding != TextEncoding::eucJp);
  }
}

void rejectsUnrepresentableText() {
  constexpr std::string_view test = "rejectsUnrepresentableText";
  const auto result = macEncodingService().encode(
      SakuraString{u"😀"}, {TextEncoding::shiftJis, false});
  EXPECT(test, !result.ok());
}

void detectsAmbiguousJapaneseByteSequences() {
  constexpr std::string_view test = "detectsAmbiguousJapaneseByteSequences";
  const auto& service = macEncodingService();
  // Independent JIS X 0208 fixtures, not bytes generated by the codec under test.
  for (const auto& fixture : {
           std::pair{bytes({0xA4, 0xA2}), SakuraString{u"あ"}},
           std::pair{bytes({0xA4, 0xA4}), SakuraString{u"い"}},
           std::pair{bytes({0xA5, 0xC6, 0xA5, 0xB9, 0xA5, 0xC8}), SakuraString{u"テスト"}},
           std::pair{bytes({0xA4, 0xB3, 0xA4, 0xF3, 0xA4, 0xCB, 0xA4, 0xC1, 0xA4, 0xCF}),
                     SakuraString{u"こんにちは"}},
       }) {
    EXPECT(test, service.decode(fixture.first, TextEncoding::shiftJis).ok());
    const auto decoded = service.decode(fixture.first);
    EXPECT(test, decoded.ok());
    EXPECT(test, decoded.state.encoding == TextEncoding::eucJp);
    EXPECT(test, decoded.text == fixture.second);
    EXPECT(test, service.encode(decoded.text, decoded.state).bytes == fixture.first);
  }
}

void usesCoreTextMetricsWithPortableLayout() {
  constexpr std::string_view test = "usesCoreTextMetricsWithPortableLayout";
  sakura::platform::mac::CoreTextMetrics metrics("Menlo-Regular", 13.0F);
  const sakura::core::FontStyle style{0, 13.0F, 400, false};
  const float advance = metrics.advance(u'a', style);
  EXPECT(test, advance > 0.0F);
  EXPECT(test, metrics.lineHeight(style) > 0.0F);

  const TextBuffer buffer(u"aaaaaa");
  const sakura::core::LayoutEngine engine;
  const auto layout = engine.layout(buffer, metrics, style,
                                    {.wrapWidth = advance * 2.0F, .tabWidth = 4});
  EXPECT(test, layout.visualLines.size() == 3);
  EXPECT(test, layout.visualLines[1].startColumn == 2);
  EXPECT(test, layout.visualLines[2].endColumn == 6);
}

void characterSpacingChangesWrappingAndKeepsCachedWidthsStable() {
  constexpr std::string_view test = "characterSpacingChangesWrappingAndKeepsCachedWidthsStable";
  const sakura::core::FontStyle style{0, 13.0F, 400, false};
  sakura::platform::mac::CoreTextMetrics ordinary("Menlo-Regular", 13.0F);
  const float baseWidth = ordinary.advance(u'a', style);
  const float spacing = baseWidth * 0.5F;
  sakura::platform::mac::CoreTextMetrics spaced("Menlo-Regular", 13.0F, spacing);
  for (const auto character : {u'a', u' ', u'桜'}) {
    const auto width = spaced.advance(character, style);
    EXPECT(test, std::abs(width - ordinary.advance(character, style) - spacing) < 0.001F);
    for (int index = 0; index < 100; ++index) {
      EXPECT(test, spaced.advance(character, style) == width);
    }
  }
  EXPECT(test, spaced.lineHeight(style) == ordinary.lineHeight(style));
  const TextBuffer buffer(u"aaaa");
  const sakura::core::LayoutOptions options{baseWidth * 3.5F, 4};
  const sakura::core::LayoutEngine engine;
  const auto normalLayout = engine.layout(buffer, ordinary, style, options);
  const auto spacedLayout = engine.layout(buffer, spaced, style, options);
  EXPECT(test, normalLayout.visualLines.front().endColumn == 3);
  EXPECT(test, spacedLayout.visualLines.front().endColumn == 2);
}

float coreTextReferenceWidth(sakura::core::SakuraStringView text,
                             float spacing) {
  CTFontRef font = CTFontCreateWithName(CFSTR("Menlo-Regular"), 13.0, nullptr);
  const double kernValue = spacing;
  const int ligatures = 0;
  CFNumberRef kern = CFNumberCreate(nullptr, kCFNumberDoubleType, &kernValue);
  CFNumberRef ligature = CFNumberCreate(nullptr, kCFNumberIntType, &ligatures);
  const void* keys[]{kCTFontAttributeName, kCTKernAttributeName, kCTLigatureAttributeName};
  const void* values[]{font, kern, ligature};
  CFDictionaryRef attributes = CFDictionaryCreate(nullptr, keys, values, 3,
      &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFStringRef string = CFStringCreateWithCharacters(nullptr,
      reinterpret_cast<const UniChar*>(text.data()), static_cast<CFIndex>(text.size()));
  CFAttributedStringRef attributed = CFAttributedStringCreate(nullptr, string, attributes);
  CTLineRef line = CTLineCreateWithAttributedString(attributed);
  const float width = CTLineGetTypographicBounds(line, nullptr, nullptr, nullptr);
  CFRelease(line);
  CFRelease(attributed);
  CFRelease(string);
  CFRelease(attributes);
  CFRelease(ligature);
  CFRelease(kern);
  CFRelease(font);
  return width;
}

void measuresWholeComposedClustersUsingCoreText() {
  constexpr std::string_view test = "measuresWholeComposedClustersUsingCoreText";
  const sakura::core::FontStyle style{0, 13.0F, 400, false};
  const std::vector<SakuraString> clusters{
      u"e\u0301", u"か\u3099", u"😀", u"👨‍👩‍👧‍👦", u"🇯🇵", u"👍🏽", u"1\uFE0F\u20E3"};
  for (const float spacing : {0.0F, 2.0F}) {
    sakura::platform::mac::CoreTextMetrics metrics("Menlo-Regular", 13.0F, spacing);
    for (const auto& cluster : clusters) {
      const auto width = metrics.advanceCluster(cluster, style);
      EXPECT(test, width > 0 && std::isfinite(width));
      EXPECT(test, std::abs(width - coreTextReferenceWidth(cluster, spacing)) < 0.01F);
      for (int repeat = 0; repeat < 20; ++repeat) {
        EXPECT(test, metrics.advanceCluster(cluster, style) == width);
      }
      SakuraString source = cluster;
      source.append(u"X");
      const auto layout = sakura::core::LayoutEngine{}.layout(
          TextBuffer(source), metrics, style, {.wrapWidth = width * 0.9F, .tabWidth = 4});
      EXPECT(test, layout.visualLines.size() == 2);
      EXPECT(test, layout.visualLines.front().startColumn == 0);
      EXPECT(test, layout.visualLines.front().endColumn == cluster.size());
      EXPECT(test, std::abs(layout.visualLines.front().width - width) < 0.01F);
    }
    EXPECT(test, metrics.advanceCluster({}, style) == 0);
    EXPECT(test, metrics.advanceCluster(u"a", style) == metrics.advance(u'a', style));
  }
  // Measure actual fallback glyphs for a surrogate pair, not two isolated
  // surrogate replacement glyphs. The same applies to the joined family.
  sakura::platform::mac::CoreTextMetrics metrics("Menlo-Regular", 13.0F);
  const auto scalar = metrics.advanceCluster(u"😀", style);
  EXPECT(test, std::abs(scalar - metrics.advance(u'\xD83D', style) -
                                    metrics.advance(u'\xDE00', style)) > 0.1F);
  EXPECT(test, metrics.advanceCluster(u"👨‍👩‍👧‍👦", style) < scalar * 1.5F);
  EXPECT(test, std::abs(metrics.advanceCluster(u"e\u0301", style) -
                       metrics.advance(u'e', style)) < 0.01F);
  sakura::platform::mac::CoreTextMetrics spaced("Menlo-Regular", 13.0F, 2.0F);
  for (const auto& cluster : clusters) {
    EXPECT(test, std::abs(spaced.advanceCluster(cluster, style) -
                         metrics.advanceCluster(cluster, style) - 2.0F) < 0.01F);
  }
  const SakuraString large = u"e" + SakuraString(128, u'\u0301');
  EXPECT(test, std::isfinite(metrics.advanceCluster(large, style)));
}

}  // namespace

int main() {
  decodesAndEncodesJapaneseCodecs();
  automaticDetectionAndDocumentSessionUseMacService();
  detectsIso2022BeforeAsciiAndPreservesItWhenSaving();
  doesNotMistakeAsciiOrTerminalEscapesForIso2022();
  unicodeBomsRemainAuthoritative();
  rejectsUnrepresentableText();
  detectsAmbiguousJapaneseByteSequences();
  usesCoreTextMetricsWithPortableLayout();
  characterSpacingChangesWrappingAndKeepsCachedWidthsStable();
  measuresWholeComposedClustersUsingCoreText();

  if (failures != 0) {
    std::cerr << failures << " macOS encoding test(s) failed\n";
    return 1;
  }
  std::cout << "All macOS encoding tests passed\n";
  return 0;
}
