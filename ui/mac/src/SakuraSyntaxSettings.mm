// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import "SakuraSyntaxSettings.h"
#include "sakura/platform/mac/StringBridge.h"

namespace {
NSDictionary* normalizedGroup(id value) {
  NSDictionary* saved = [value isKindOfClass:NSDictionary.class] ? value : @{};
  return @{@"keywords":[saved[@"keywords"] isKindOfClass:NSString.class] ? [saved[@"keywords"] copy] : @"",
           @"patterns":[saved[@"patterns"] isKindOfClass:NSString.class] ? [saved[@"patterns"] copy] : @"",
           @"caseSensitive":[saved[@"caseSensitive"] isKindOfClass:NSNumber.class] ? saved[@"caseSensitive"] : @YES};
}
NSString* parseGroup(NSDictionary* group, sakura::core::CustomSyntaxGroup& result) {
  NSString* words = group[@"keywords"];
  NSString* patterns = group[@"patterns"];
  if (![words isKindOfClass:NSString.class] || ![patterns isKindOfClass:NSString.class] ||
      ![group[@"caseSensitive"] isKindOfClass:NSNumber.class]) return @"設定形式が不正です。";
  if (words.length > 65536 || patterns.length > 8192) return @"単語64K文字・正規表現8K文字の入力上限を超えています。";
  result.caseSensitive = [group[@"caseSensitive"] boolValue];
  for (NSString* word in [words componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet])
    if (word.length) result.keywords.push_back(sakura::platform::mac::sakuraStringFromString(word));
  NSString* normalized = [[patterns stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
      stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
  for (NSString* pattern in [normalized componentsSeparatedByString:@"\n"])
    if (pattern.length) result.patterns.push_back(sakura::platform::mac::sakuraStringFromString(pattern));
  sakura::core::CustomSyntaxRules check{result.keywords, result.patterns, result.caseSensitive};
  auto error = sakura::core::validateCustomSyntaxRules(check);
  return error ? [NSString stringWithUTF8String:error->c_str()] : nil;
}
}
NSString* SakuraSyntaxPreferenceKey(NSString* type) {
  return [@"SakuraSyntaxRules." stringByAppendingString:type.length ? type : @"basic"];
}
NSArray<NSDictionary*>* SakuraSyntaxGroups(NSDictionary* preferences) {
  NSMutableArray* result = [NSMutableArray arrayWithObject:normalizedGroup(preferences)];
  id extra = preferences[@"groups"];
  NSArray* groups = [extra isKindOfClass:NSArray.class] ? extra : @[];
  for (NSUInteger n = 0; n < 9; ++n) [result addObject:normalizedGroup(n < groups.count ? groups[n] : nil)];
  return result;
}
NSDictionary* SakuraSyntaxPreferencesFromGroups(NSArray<NSDictionary*>* groups) {
  NSMutableDictionary* result = [normalizedGroup(groups.firstObject) mutableCopy];
  NSMutableArray* extra = [NSMutableArray array];
  for (NSUInteger n = 1; n < 10; ++n) [extra addObject:normalizedGroup(n < groups.count ? groups[n] : nil)];
  result[@"groups"] = extra;
  return result;
}
NSDictionary* SakuraSyntaxPreferences(NSString* type, NSUserDefaults* defaults) {
  id value = [defaults objectForKey:SakuraSyntaxPreferenceKey(type)];
  NSDictionary* saved = [value isKindOfClass:NSDictionary.class] ? value : @{};
  return SakuraSyntaxPreferencesFromGroups(SakuraSyntaxGroups(saved));
}
BOOL SakuraSyntaxPreferencesHaveRules(NSDictionary* preferences) {
  for (NSDictionary* group in SakuraSyntaxGroups(preferences))
    if ([group[@"keywords"] length] || [group[@"patterns"] length]) return YES;
  return NO;
}
NSString* SakuraParseSyntaxPreferences(NSDictionary* preferences, sakura::core::CustomSyntaxRules& rules) {
  rules = {};
  id extra = preferences[@"groups"];
  if (extra && (![extra isKindOfClass:NSArray.class] || [extra count] > 9)) return @"キーワードグループは10個までです。";
  NSMutableArray* raw = [NSMutableArray arrayWithObject:preferences];
  if (extra) [raw addObjectsFromArray:extra];
  for (NSUInteger n = 0; n < raw.count; ++n) {
    if (![raw[n] isKindOfClass:NSDictionary.class]) return @"キーワードグループの形式が不正です。";
    sakura::core::CustomSyntaxGroup group;
    NSString* error = parseGroup(raw[n], group);
    if (error) return [NSString stringWithFormat:@"キーワード%lu: %@", (unsigned long)n + 1, error];
    if (n == 0) {
      rules.keywords = std::move(group.keywords); rules.patterns = std::move(group.patterns); rules.caseSensitive = group.caseSensitive;
    } else rules.additionalGroups.push_back(std::move(group));
  }
  auto error = sakura::core::validateCustomSyntaxRules(rules);
  if (error) return [@"全グループ合計の制限: " stringByAppendingString:[NSString stringWithUTF8String:error->c_str()]];
  return nil;
}
void SakuraSaveSyntaxPreferences(NSString* type, NSUserDefaults* defaults, NSDictionary* draft, NSDictionary* baseline) {
  NSMutableArray* current = [SakuraSyntaxGroups(SakuraSyntaxPreferences(type, defaults)) mutableCopy];
  NSArray* edited = SakuraSyntaxGroups(draft);
  NSArray* original = SakuraSyntaxGroups(baseline);
  BOOL changed = NO;
  NSUInteger count = draft[@"groups"] ? 10 : 1;
  for (NSUInteger n = 0; n < count; ++n) {
    NSMutableDictionary* group = [current[n] mutableCopy];
    for (NSString* property in @[@"keywords", @"patterns", @"caseSensitive"])
      if (![edited[n][property] isEqual:original[n][property]]) { group[property] = edited[n][property]; changed = YES; }
    current[n] = group;
  }
  if (changed) [defaults setObject:SakuraSyntaxPreferencesFromGroups(current) forKey:SakuraSyntaxPreferenceKey(type)];
}
