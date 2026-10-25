// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import "SakuraKeywordFile.h"
#import "SakuraSyntaxSettings.h"
#include "sakura/platform/mac/MacEncodingService.h"
#include "sakura/platform/mac/StringBridge.h"
namespace {
void fail(NSString** error, NSString* message) { if (error) *error = message; }
}
NSDictionary* SakuraImportKeywordData(NSData* data, sakura::core::TextEncoding encoding,
                                     BOOL sensitive, NSString** error) {
  if (error) *error = nil;
  if (static_cast<int>(encoding) < 0 || static_cast<int>(encoding) > 6) {
    fail(error, @"未対応の文字コードです。"); return nil;
  }
  if (data.length > 256 * 1024) { fail(error, @"キーワードファイルは256KiBまでです。"); return nil; }
  const auto* bytes = static_cast<const std::byte*>(data.bytes);
  const auto decoded = sakura::platform::mac::macEncodingService().decode({bytes, data.length}, encoding);
  if (!decoded.ok()) { fail(error, @"指定した文字コードで読めません。文字コードを確認してください。"); return nil; }
  if (decoded.detection.ambiguous) {
    fail(error, @"CP932／EUC-JPの判定が曖昧です。文字コードを指定して再度読み込んでください。"); return nil;
  }
  NSString* text = sakura::platform::mac::stringFromSakuraString(decoded.text);
  text = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
      stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
  NSMutableArray<NSString*>* words = [NSMutableArray array];
  NSMutableSet<NSString*>* seen = [NSMutableSet set];
  NSUInteger lineNumber = 0, total = 0;
  for (NSString* line in [text componentsSeparatedByString:@"\n"]) {
    ++lineNumber;
    if (!line.length) continue;
    if ([line hasPrefix:@"//"]) {
      if ([line isEqual:@"// CASE=True"]) sensitive = YES;
      else if ([line isEqual:@"// CASE=False"]) sensitive = NO;
      else if ([line hasPrefix:@"// CASE="]) {
        fail(error, [NSString stringWithFormat:@"%lu行: CASEはTrueかFalseを指定してください。", (unsigned long)lineNumber]); return nil;
      }
      continue;
    }
    sakura::core::CustomSyntaxRules one{{sakura::platform::mac::sakuraStringFromString(line)}, {}, true};
    if (sakura::core::validateCustomSyntaxRules(one)) {
      fail(error, [NSString stringWithFormat:@"%lu行: 未対応のキーワードです。1行1語、128 UTF-16単位以内の単語文字だけを指定してください。", (unsigned long)lineNumber]); return nil;
    }
    if ([seen containsObject:line]) continue;
    [seen addObject:line]; [words addObject:line]; total += line.length;
    if (words.count > 2048 || total > 32768) { fail(error, @"単語数または合計文字数の上限を超えています。"); return nil; }
  }
  return @{@"keywords":[words componentsJoinedByString:@"\n"], @"caseSensitive":@(sensitive)};
}
NSData* SakuraExportKeywordData(NSDictionary* group, NSString** error) {
  if (error) *error = nil;
  if (![group isKindOfClass:NSDictionary.class]) { fail(error, @"キーワード設定が不正です。"); return nil; }
  NSMutableDictionary* wordsOnly = group.mutableCopy; wordsOnly[@"patterns"] = @"";
  [wordsOnly removeObjectForKey:@"groups"];
  sakura::core::CustomSyntaxRules parsed;
  NSString* validation = SakuraParseSyntaxPreferences(wordsOnly, parsed);
  if (validation) { fail(error, validation); return nil; }
  NSMutableSet<NSString*>* unique = [NSMutableSet set];
  for (const auto& word : parsed.keywords) [unique addObject:sakura::platform::mac::stringFromSakuraString(word)];
  NSArray* sorted = [unique.allObjects sortedArrayUsingComparator:^NSComparisonResult(NSString* a, NSString* b) {
    return [a compare:b options:NSLiteralSearch];
  }];
  NSMutableString* output = [NSMutableString stringWithFormat:
      @"// Sakura macOS キーワード定義ファイル\r\n// CASE=%@\r\n\r\n", parsed.caseSensitive ? @"True" : @"False"];
  for (NSString* word in sorted) [output appendFormat:@"%@\r\n", word];
  const unsigned char bom[] = {0xef, 0xbb, 0xbf};
  NSMutableData* data = [NSMutableData dataWithBytes:bom length:sizeof(bom)];
  [data appendData:[output dataUsingEncoding:NSUTF8StringEncoding]];
  return data;
}
