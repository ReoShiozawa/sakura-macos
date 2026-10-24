// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#ifndef SAKURA_PLATFORM_MAC_STRING_BRIDGE_H_
#define SAKURA_PLATFORM_MAC_STRING_BRIDGE_H_

#import <Foundation/Foundation.h>

#include "sakura/core/text/Types.h"

namespace sakura::platform::mac {

// Both NSString and the portable core use UTF-16 code units.  Keeping this
// conversion at the platform boundary also keeps Objective-C types out of the
// portable libraries.
[[nodiscard]] NSString* stringFromSakuraString(core::SakuraStringView text);
[[nodiscard]] core::SakuraString sakuraStringFromString(NSString* text);

}  // namespace sakura::platform::mac

#endif  // SAKURA_PLATFORM_MAC_STRING_BRIDGE_H_
