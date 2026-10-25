// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import "SakuraKeywordFile.h"
#include "sakura/platform/mac/MacEncodingService.h"
#include <iostream>
namespace {
int failures = 0;
void check(bool ok, const char* label) { if (!ok) { std::cerr << label << '\n'; ++failures; } }
NSData* encoded(sakura::core::TextEncoding encoding, bool bom) {
  auto result = sakura::platform::mac::macEncodingService().encode(
      u"// Own test keywords\r\n// CASE=False\r\n日本語\r\nAlpha\r\nAlpha\r\n", {encoding, bom});
  check(result.ok(), "encode own keyword fixture");
  return [NSData dataWithBytes:result.bytes.data() length:result.bytes.size()];
}
}
int main() {
  @autoreleasepool {
    using E = sakura::core::TextEncoding;
    for (auto encoding : {E::utf8, E::utf16LittleEndian, E::utf16BigEndian, E::shiftJis, E::eucJp, E::iso2022Jp}) {
      NSString* error = nil;
      NSDictionary* group = SakuraImportKeywordData(encoded(encoding, encoding == E::utf8 || encoding == E::utf16LittleEndian || encoding == E::utf16BigEndian), encoding, YES, &error);
      check(group && !error && [group[@"keywords"] isEqual:@"日本語\nAlpha"] && ![group[@"caseSensitive"] boolValue],
            "import own keywords in all supported encodings and deduplicate exact lines");
      if (!group) continue;
      NSMutableDictionary* draft = group.mutableCopy; draft[@"patterns"] = @"ignored-regex";
      NSData* exported = SakuraExportKeywordData(draft, &error);
      check(exported.length >= 3 && static_cast<const unsigned char*>(exported.bytes)[0] == 0xef, "export UTF8 BOM");
      NSDictionary* roundTrip = SakuraImportKeywordData(exported, E::automatic, YES, &error);
      check([roundTrip[@"keywords"] isEqual:@"Alpha\n日本語"] && ![roundTrip[@"caseSensitive"] boolValue], "export sorted CRLF keywords and CASE round trip");
    }
    NSString* error = nil;
    const unsigned char ambiguousBytes[] = {0xa4, 0xa2, 0x0d, 0x0a};
    NSData* ambiguousData = [NSData dataWithBytes:ambiguousBytes length:sizeof(ambiguousBytes)];
    check(!SakuraImportKeywordData(ambiguousData, E::automatic, YES, &error) && [error containsString:@"曖昧"],
          "ambiguous auto-detected keywords require explicit encoding before modifying draft");
    check([SakuraImportKeywordData(ambiguousData, E::eucJp, YES, &error)[@"keywords"] isEqual:@"あ"],
          "explicit EUC-JP imports ambiguous keyword bytes");
    auto parse = [&](NSString* text) { return SakuraImportKeywordData([text dataUsingEncoding:NSUTF8StringEncoding], E::utf8, NO, &error); };
    check(!parse(@"// own\nGood\nbad-name\n") && [error containsString:@"3行"], "unsupported word rejects whole file with line number");
    check(!parse(@"// CASE=Maybe\nGood") && [error containsString:@"1行"], "invalid CASE rejected");
    check(![parse(@"// no CASE\nGood")[@"caseSensitive"] boolValue], "missing CASE keeps caller choice");
    check([parse(@"// CASE=False\n// CASE=True\nGood")[@"caseSensitive"] boolValue], "last CASE declaration wins like upstream");
    check(!SakuraImportKeywordData([NSMutableData dataWithLength:256 * 1024 + 1], E::utf8, YES, &error), "file size bounded before decode");
    const unsigned char invalid[] = {0xff, 0xfe, 0};
    check(!SakuraImportKeywordData([NSData dataWithBytes:invalid length:sizeof(invalid)], E::automatic, YES, &error), "malformed UTF16 rejected");
    check(!SakuraImportKeywordData(NSData.data, static_cast<E>(999), YES, &error), "invalid encoding rejected");
    check(SakuraExportKeywordData(@{@"keywords":@"bad-word", @"caseSensitive":@YES}, &error) == nil, "invalid words never exported silently");
  }
  return failures ? 1 : 0;
}
