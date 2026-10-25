// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include <array>
#include <atomic>
#include <iostream>
#include <random>
#include <thread>

#include "sakura/app/DocumentSession.h"
#include "sakura/platform/mac/MacEncodingService.h"

namespace {
using E = sakura::core::TextEncoding;
using M = sakura::core::EncodingDetectionMethod;
using sakura::core::SakuraString;
using sakura::platform::mac::macEncodingService;
int failures{};
void check(bool value, const char* label) {
  if (!value) { ++failures; std::cerr << label << '\n'; }
}
std::vector<std::byte> bytes(std::initializer_list<unsigned int> values) {
  std::vector<std::byte> result;
  for (auto value : values) result.push_back(static_cast<std::byte>(value));
  return result;
}

void fixedByteFixtures() {
  const auto& service = macEncodingService();
  // Independently specified byte fixtures (JIS X 0208 rows and CP932 values).
  struct Fixture { std::vector<std::byte> input; SakuraString text; E encoding; };
  const Fixture fixtures[]{
    {bytes({0xA4,0xA2}), u"あ", E::eucJp},
    {bytes({0xA4,0xA4}), u"い", E::eucJp},
    {bytes({0xA5,0xC6,0xA5,0xB9,0xA5,0xC8}), u"テスト", E::eucJp},
    {bytes({0xA4,0xB3,0xA4,0xF3,0xA4,0xCB,0xA4,0xC1,0xA4,0xCF}), u"こんにちは", E::eucJp},
    {bytes({0x8D,0xF7}), u"桜", E::shiftJis},
    {bytes({0x82,0xA0,0x82,0xA2}), u"あい", E::shiftJis},
    {bytes({0xB6,0xC0,0xB6,0xC5}), u"ｶﾀｶﾅ", E::shiftJis},
    {bytes({0xBA,0xF9}), u"桜", E::eucJp},
    {bytes({0x8E,0xB6,0x8E,0xC0,0x8E,0xB6,0x8E,0xC5}), u"ｶﾀｶﾅ", E::eucJp},
  };
  for (const auto& fixture : fixtures) {
    const auto decoded = service.decode(fixture.input);
    check(decoded.ok() && decoded.text == fixture.text && decoded.state.encoding == fixture.encoding,
          "fixed-byte detection and text");
    check(service.encode(decoded.text, decoded.state).bytes == fixture.input, "fixed-byte round trip");
  }
}

void representativeTextCorpus() {
  // Original text fixtures representing editor use, not extracted user files or
  // third-party literary text. These are regression examples, not an accuracy
  // estimate for all Japanese documents.
  constexpr std::array corpus{
    u"さくらの花が咲きました。今日も日本語の文章を編集します。\r\n保存する前に内容を確認してください。\r\n",
    u"検索条件を入力して、次の候補へ移動します。文字コードと改行コードは維持します。\n",
    u"テキストエディタ、ファイル、ウィンドウ、キャンセル、ステータスバー。\n",
    u"// 日本語のコメントです。\nint main() { return 0; }\n// 関数の戻り値を確認する。\n",
    u"# 日本語ドキュメント\n\nこれは編集機能の試験です。\n- 読み込み\n- 書き込み\n- 検索と置換\n",
    u"番号,商品名,数量,備考\r\n1,さくらノート,2,発送をお願いします\r\n2,テスト用紙,10,店頭で受け取ります\r\n",
    u"<!doctype html><html><head><title>日本語のページ</title></head><body>読み込みが完了しました。</body></html>\n",
    u"件名: 設定の確認\r\n\r\nお世話になっております。添付の資料をご確認ください。\r\nよろしくお願いいたします。\r\n",
    u"2026-10-25 10:00:00 INFO 設定ファイルを読み込みました\n2026-10-25 10:00:01 WARN 保存先を確認してください\n",
    u"{\"説明\":\"日本語の設定ファイル\",\"表示\":\"行番号を表示します\",\"保存\":true}\n",
    u"名称\t値\t説明\n文字コード\t自動\t候補から判定します\n改行\tCRLF\t元の形式を維持します\n",
    u"[表示設定]\n説明=日本語を正しく表示するための設定です\nフォント=等幅\n",
    u"#!/bin/sh\n# バックアップを作成してから更新します\necho '更新が完了しました'\n",
    u"def save_document():\n    # 保存する前に内容を確認します\n    return 'ファイルを保存しました'\n",
    u"SELECT 名称, 数量 FROM 商品 WHERE 備考 = '発送をお願いします';\n",
    u"ﾃｽﾄ ﾌｧｲﾙ ｶﾀｶﾅ ｻｸﾗ\nﾊﾝｶｸｶﾅ ｶﾞｷﾞｸﾞｹﾞｺﾞ 123 ABC\n",
    u"半角ｶﾅと全角カナ、ひらがなを混在させて表示します。\n",
    u"C:\\work\\資料\\test.txt\r\nパスと日本語のファイル名を表示します。\r\n",
    u"# A long ASCII header precedes Japanese text.\n# Encoding: not declared\n本文をここから読み込みます。内容を確認して保存してください。\n",
    u"東京大阪京都神戸札幌横浜名古屋福岡広島仙台\n日本国東京都中央区大阪府大阪市北区\n",
    u"日本 日本 日本 日本 日本 日本 日本 日本 日本 日本 日本 日本 日本 日本 日本 日本\n",
  };
  std::size_t total{};
  for (const auto text : corpus) {
    for (const auto encoding : {E::shiftJis, E::eucJp}) {
      const auto encoded = macEncodingService().encode(text, {encoding, false});
      check(encoded.ok(), "corpus can be represented in expected encoding");
      const auto decoded = macEncodingService().decode(encoded.bytes);
      if (!decoded.ok() || decoded.text != text || decoded.state.encoding != encoding) {
        ++failures;
        std::cerr << "corpus sample " << total << " expected " << static_cast<int>(encoding)
                  << " detected " << static_cast<int>(decoded.state.encoding)
                  << " method " << static_cast<int>(decoded.detection.method) << '\n';
      }
      check(macEncodingService().encode(decoded.text, decoded.state).bytes == encoded.bytes,
            "corpus round trip preserves bytes including line endings");
      ++total;
    }
  }
  check(total == corpus.size() * 2, "all corpus entries tested in both encodings");
}

void ambiguityIsNotSilentlyCalledCertain() {
  const auto& service = macEncodingService();
  // A4 A2 can intentionally mean CP932 half-width punctuation, not only EUC あ.
  const auto ambiguous = bytes({0xA4,0xA2});
  const auto guessed = service.decode(ambiguous);
  check(guessed.detection.ambiguous && guessed.detection.method == M::japaneseHeuristic,
        "kana heuristic explicitly reports ambiguity");
  const auto explicitSjis = service.decode(ambiguous, E::shiftJis);
  check(explicitSjis.ok() && explicitSjis.text == u"､｢" && !explicitSjis.detection.ambiguous &&
        explicitSjis.detection.method == M::explicitEncoding, "explicit CP932 is never overridden");
  const auto explicitEuc = service.decode(ambiguous, E::eucJp);
  check(explicitEuc.text == u"あ" && explicitEuc.detection.method == M::explicitEncoding,
        "explicit EUC-JP is never overridden");
  const auto undecidable = bytes({0xB0,0xA6});  // CP932 half-kana versus EUC-JP 愛
  const auto result = service.decode(undecidable);
  check(result.ok() && result.detection.ambiguous && result.detection.method == M::fallback,
        "short kana-less input reports defaulted ambiguous decision");
  check(service.decode(bytes({0x8D,0xF7})).detection.method == M::bytePattern,
        "unique legacy byte syntax has separate evidence");

  sakura::app::DocumentSession doc(service);
  check(doc.load(ambiguous).ok() && doc.sourceEncodingDetection() == guessed.detection,
        "document preserves read-time detection evidence");
  doc.insert(1, u"!");
  doc.setEncodingState({E::utf8, false});
  doc.markSaved(doc.makeSaveSnapshot().token);
  check(doc.sourceEncodingDetection() == guessed.detection,
        "editing and output selection do not confirm a guessed interpretation");
  const auto invalid = bytes({0x81});
  const auto before = doc.buffer().text();
  check(!doc.load(invalid).ok() && doc.buffer().text() == before &&
        doc.sourceEncodingDetection() == guessed.detection,
        "failed reload preserves document and previous evidence");
  check(doc.load(ambiguous, E::shiftJis).ok() && !doc.sourceEncodingDetection().ambiguous,
        "successful explicit reload resolves warning");
  doc.restoreSourceEncodingAmbiguity();
  check(doc.sourceEncodingDetection().ambiguous && doc.sourceEncodingDetection().method == M::fallback,
        "Unicode recovery retains warning without inventing detection evidence");
  check(!service.decode(ambiguous, static_cast<E>(999)).ok(), "invalid requested encoding fails");
}

void independentDetectionsCanRunConcurrently() {
  const auto& service = macEncodingService();
  const auto input = bytes({0xC6,0xFC,0xCB,0xDC,0x20,0xC6,0xFC,0xCB,0xDC,0x20,
                           0xC6,0xFC,0xCB,0xDC,0x20,0xC6,0xFC,0xCB,0xDC,0x20,
                           0xC6,0xFC,0xCB,0xDC,0x20,0xC6,0xFC,0xCB,0xDC,0x20,
                           0xC6,0xFC,0xCB,0xDC,0x20,0xC6,0xFC,0xCB,0xDC});
  const auto expected = service.decode(input);
  std::atomic<unsigned int> errors{};
  std::vector<std::thread> workers;
  for (int index = 0; index < 6; ++index) workers.emplace_back([&] {
    for (int run = 0; run < 100; ++run) {
      const auto decoded = service.decode(input);
      if (!decoded.ok() || decoded.text != expected.text || decoded.state != expected.state ||
          decoded.detection != expected.detection) ++errors;
    }
  });
  for (auto& worker : workers) worker.join();
  check(errors == 0, "concurrent detections have independent state and deterministic results");
}

void longAndMalformedInputs() {
  const auto& service = macEncodingService();
  // A bounded platform sample must not hide evidence after its end or accept a
  // file whose final multibyte sequence is invalid.
  SakuraString longText(70U * 1024U, u'A');
  longText += u"\nこれは末尾の日本語です。保存前に確認します。\n";
  for (const auto encoding : {E::shiftJis, E::eucJp}) {
    const auto encoded = service.encode(longText, {encoding, false});
    const auto decoded = service.decode(encoded.bytes);
    check(decoded.ok() && decoded.text == longText && decoded.state.encoding == encoding,
          "full input validated beyond statistical sample");
  }
  std::mt19937 random(0xE0C0932);
  for (int sample = 0; sample < 4000; ++sample) {
    std::vector<std::byte> input(random() % 96);
    for (auto& value : input) value = static_cast<std::byte>(random() & 0xFF);
    const auto automatic = service.decode(input);
    if (!automatic.ok()) continue;
    const auto explicitResult = service.decode(input, automatic.state.encoding);
    check(explicitResult.ok() && explicitResult.text == automatic.text,
          "random successful inference agrees with strict explicit decoder");
    if (automatic.state.encoding == E::shiftJis || automatic.state.encoding == E::eucJp ||
        automatic.state.encoding == E::iso2022Jp)
      check(automatic.text.find(u'\uFFFD') == SakuraString::npos,
            "legacy inference does not insert replacement characters on random input");
  }
}
}  // namespace

int main() {
  fixedByteFixtures();
  representativeTextCorpus();
  ambiguityIsNotSilentlyCalledCertain();
  independentDetectionsCanRunConcurrently();
  longAndMalformedInputs();
  if (failures) std::cerr << failures << " Japanese detection failures\n";
  return failures ? 1 : 0;
}
