// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include "sakura/platform/mac/StringBridge.h"

#include <limits>
#include <stdexcept>
#include <algorithm>
#include <memory>

namespace {
struct BufferStringStorage {
  sakura::core::TextBuffer source;
  sakura::core::TextRange replaced;
  sakura::core::SakuraString inserted;
  NSUInteger length;
};
}

@interface SakuraBufferString : NSString {
  std::unique_ptr<BufferStringStorage> _storage;
}
- (instancetype)initWithBuffer:(const sakura::core::TextBuffer&)buffer
                   replacement:(sakura::core::TextRange)replacement
                        marked:(sakura::core::SakuraStringView)marked;
@end

@implementation SakuraBufferString
- (instancetype)initWithBuffer:(const sakura::core::TextBuffer&)buffer
                   replacement:(sakura::core::TextRange)replacement
                        marked:(sakura::core::SakuraStringView)marked {
  if (replacement.location > buffer.length() || replacement.length > buffer.length() - replacement.location)
    throw std::out_of_range("string replacement is outside the buffer");
  if (buffer.length() - replacement.length > std::numeric_limits<NSUInteger>::max() - marked.size())
    throw std::length_error("text is too large for NSString");
  self = [super init];
  if (self) _storage = std::make_unique<BufferStringStorage>(BufferStringStorage{
      buffer, replacement, sakura::core::SakuraString(marked),
      static_cast<NSUInteger>(buffer.length() - replacement.length + marked.size())});
  return self;
}
- (NSUInteger)length { return _storage ? _storage->length : 0; }
- (unichar)characterAtIndex:(NSUInteger)index {
  if (index >= self.length) [NSException raise:NSRangeException format:@"Character index is outside the string"];
  const auto& value = *_storage;
  if (index < value.replaced.location) return value.source.characterAt(index);
  const auto after = index - value.replaced.location;
  if (after < value.inserted.size()) return value.inserted[after];
  return value.source.characterAt(index - value.inserted.size() + value.replaced.length);
}
- (void)getCharacters:(unichar*)output range:(NSRange)range {
  if (range.location > self.length || range.length > self.length - range.location)
    [NSException raise:NSRangeException format:@"Character range is outside the string"];
  if (!range.length) return;
  static_assert(sizeof(unichar) == sizeof(sakura::core::SakuraChar));
  const auto& value = *_storage;
  const auto end = NSMaxRange(range);
  auto cursor = range.location;
  const auto copySource = [&](NSUInteger from, NSUInteger count) {
    value.source.copyText({from, count}, {reinterpret_cast<sakura::core::SakuraChar*>(output), count});
  };
  if (cursor < value.replaced.location) {
    const auto count = std::min<NSUInteger>(end, value.replaced.location) - cursor;
    copySource(cursor, count); cursor += count; output += count;
  }
  const auto markedEnd = value.replaced.location + value.inserted.size();
  if (cursor < end && cursor < markedEnd) {
    const auto count = std::min<NSUInteger>(end, markedEnd) - cursor;
    std::copy_n(value.inserted.data() + cursor - value.replaced.location, count,
                reinterpret_cast<sakura::core::SakuraChar*>(output));
    cursor += count; output += count;
  }
  if (cursor < end) copySource(cursor - value.inserted.size() + value.replaced.length, end - cursor);
}
- (id)copyWithZone:(NSZone*)zone { (void)zone; return self; }
- (NSString*)substringWithRange:(NSRange)range {
  if (range.location > self.length || range.length > self.length - range.location)
    [NSException raise:NSRangeException format:@"Substring range is outside the string"];
  sakura::core::SakuraString text(range.length, u'\0');
  [self getCharacters:reinterpret_cast<unichar*>(text.data()) range:range];
  return sakura::platform::mac::stringFromSakuraString(text);
}
@end

namespace sakura::platform::mac {

NSString* stringFromTextBuffer(const core::TextBuffer& buffer) {
  return [[SakuraBufferString alloc] initWithBuffer:buffer replacement:{0, 0} marked:{}];
}

NSString* previewStringFromTextBuffer(const core::TextBuffer& buffer,
    core::TextRange replacement, core::SakuraStringView marked) {
  return [[SakuraBufferString alloc] initWithBuffer:buffer replacement:replacement marked:marked];
}

NSString* stringFromSakuraString(core::SakuraStringView text) {
  static_assert(sizeof(core::SakuraChar) == sizeof(unichar));
  if (text.empty()) {
    return @"";
  }
  if (text.size() > std::numeric_limits<NSUInteger>::max()) {
    throw std::length_error("text is too large for NSString");
  }
  return [[NSString alloc]
      initWithCharacters:reinterpret_cast<const unichar*>(text.data())
                  length:static_cast<NSUInteger>(text.size())];
}

core::SakuraString sakuraStringFromString(NSString* text) {
  static_assert(sizeof(core::SakuraChar) == sizeof(unichar));
  const NSUInteger length = text.length;
  core::SakuraString result(length, u'\0');
  if (length != 0) {
    [text getCharacters:reinterpret_cast<unichar*>(result.data())
                  range:NSMakeRange(0, length)];
  }
  return result;
}

}  // namespace sakura::platform::mac
