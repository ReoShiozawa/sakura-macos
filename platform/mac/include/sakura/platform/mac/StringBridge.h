// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#ifndef SAKURA_PLATFORM_MAC_STRING_BRIDGE_H_
#define SAKURA_PLATFORM_MAC_STRING_BRIDGE_H_

#import <Foundation/Foundation.h>

#include "sakura/core/text/Types.h"
#include "sakura/core/text/TextBuffer.h"

namespace sakura::platform::mac {

// Both NSString and the portable core use UTF-16 code units.  Keeping this
// conversion at the platform boundary also keeps Objective-C types out of the
// portable libraries.
[[nodiscard]] NSString* stringFromSakuraString(core::SakuraStringView text);
[[nodiscard]] core::SakuraString sakuraStringFromString(NSString* text);
// Immutable NSString storage backed by a shared TextBuffer snapshot. No full
// serialization is performed until a consumer explicitly requests all units.
[[nodiscard]] NSString* stringFromTextBuffer(const core::TextBuffer& buffer);
// IME may temporarily replace a partial surrogate/CRLF range. This storage view
// splices raw UTF-16 without treating it as a committed core edit.
[[nodiscard]] NSString* previewStringFromTextBuffer(const core::TextBuffer& buffer,
    core::TextRange replacement, core::SakuraStringView marked);

}  // namespace sakura::platform::mac

#endif  // SAKURA_PLATFORM_MAC_STRING_BRIDGE_H_
