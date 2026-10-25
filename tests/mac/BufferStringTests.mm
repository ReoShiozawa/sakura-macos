// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include "sakura/platform/mac/StringBridge.h"
#include <atomic>
#include <iostream>
#include <thread>

namespace {
using namespace sakura::core;
using namespace sakura::platform::mac;
int failures{};
void check(bool value, const char* message) { if (!value) { ++failures; std::cerr << message << '\n'; } }
void compare(NSString* actual, NSString* expected) {
  check(actual.length == expected.length && [actual isEqualToString:expected] && [expected isEqualToString:actual],
        "snapshot NSString equals native string in both directions");
  check(actual.hash == expected.hash, "snapshot/native equal strings have equal hashes");
  check(CFStringGetLength((__bridge CFStringRef)actual) == static_cast<CFIndex>(expected.length), "CFString length bridge");
  for (NSUInteger first = 0; first <= expected.length; ++first) {
    if (first < expected.length) {
      check([actual characterAtIndex:first] == [expected characterAtIndex:first], "individual UTF-16 code units");
      check(CFStringGetCharacterAtIndex((__bridge CFStringRef)actual, first) == [expected characterAtIndex:first], "CFString character bridge");
      check(NSEqualRanges([actual rangeOfComposedCharacterSequenceAtIndex:first],
                          [expected rangeOfComposedCharacterSequenceAtIndex:first]), "Foundation grapheme ranges match native storage");
    }
    for (NSUInteger length = 0; length <= expected.length - first; ++length) {
      const auto range = NSMakeRange(first, length);
      check([[actual substringWithRange:range] isEqualToString:[expected substringWithRange:range]], "arbitrary substring including partial UTF-16");
      std::vector<unichar> a(length + 1, 0x1234), b(length + 1, 0x1234);
      [actual getCharacters:a.data() range:range]; [expected getCharacters:b.data() range:range];
      check(a == b, "getCharacters honors arbitrary range and destination end");
      CFStringGetCharacters((__bridge CFStringRef)actual, CFRangeMake(first, length), a.data());
      check(a == b, "CFString range bridge");
    }
  }
  check([actual copy] == actual, "immutable copy retains snapshot instead of materializing full text");
  NSMutableString* changed = [actual mutableCopy];
  [changed appendString:@"!"];
  check([changed isEqualToString:[expected stringByAppendingString:@"!"]] && actual.length == expected.length,
        "mutableCopy is independent and has normal NSString semantics");
  check([[actual componentsSeparatedByString:@"\n"] isEqual:[expected componentsSeparatedByString:@"\n"]], "Foundation splitting bridge");
  NSData* a = [actual dataUsingEncoding:NSUTF8StringEncoding];
  NSData* b = [expected dataUsingEncoding:NSUTF8StringEncoding];
  check((a == nil && b == nil) || [a isEqual:b], "UTF-8 serialization bridge");
}
void snapshotsAndRawImeSplices() {
  TextBuffer buffer(u"a\r\nあ😀 e\u0301\n👨‍👩‍👧‍👦\r末尾");
  NSString* native = stringFromSakuraString(buffer.text());
  NSString* snapshot = stringFromTextBuffer(buffer);
  compare(snapshot, native);
  for (const auto range : {NSMakeRange(0, 0), NSMakeRange(2, 1), NSMakeRange(5, 1),
                           NSMakeRange(4, 2), NSMakeRange(2, 7), NSMakeRange(native.length, 0)}) {
    NSString* marked = @"入力\r\ne\u0301";
    NSString* preview = previewStringFromTextBuffer(buffer, {range.location, range.length}, sakuraStringFromString(marked));
    compare(preview, [native stringByReplacingCharactersInRange:range withString:marked]);
  }
  buffer.replace({0, 1}, u"new\ntext");
  compare(snapshot, native);
  check(![stringFromTextBuffer(buffer) isEqualToString:native], "a new snapshot sees the edit");
  @try { (void)[snapshot characterAtIndex:snapshot.length]; check(false, "character out of bounds must raise"); }
  @catch (NSException* error) { check([error.name isEqual:NSRangeException], "native character bounds exception"); }
  @try { unichar out; [snapshot getCharacters:&out range:NSMakeRange(NSNotFound, 1)]; check(false, "range overflow must raise"); }
  @catch (NSException* error) { check([error.name isEqual:NSRangeException], "native range bounds exception"); }
  compare(stringFromTextBuffer(TextBuffer{}), @"");
}
void concurrentReadOfRetainedSnapshot() {
  TextBuffer source(u"immutable\r\n日本語😀\n");
  NSString* snapshot = stringFromTextBuffer(source);
  NSString* expected = stringFromSakuraString(source.text());
  std::atomic<unsigned int> errors{};
  std::vector<std::thread> workers;
  for (int worker = 0; worker < 6; ++worker) workers.emplace_back([&] {
    @autoreleasepool {
      for (int iteration = 0; iteration < 400; ++iteration)
        if (![snapshot isEqualToString:expected] ||
            ![[snapshot substringWithRange:NSMakeRange(11, 3)] isEqualToString:@"日本語"]) ++errors;
    }
  });
  for (int edit = 0; edit < 400; ++edit) source.replace({0, 1}, edit % 2 ? u"a" : u"b");
  for (auto& worker : workers) worker.join();
  check(errors == 0, "shared NSString snapshot stays immutable while source edits");
}
}  // namespace
int main() {
  @autoreleasepool { snapshotsAndRawImeSplices(); concurrentReadOfRetainedSnapshot(); }
  return failures ? 1 : 0;
}
