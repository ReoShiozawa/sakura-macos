// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import <Foundation/Foundation.h>
#include "sakura/core/encoding/EncodingService.h"

// Strict .kwd subset: Unicode word keywords, // comments, // CASE=True/False.
// Unsupported entries reject the whole import, never silently drop words.
NSDictionary* SakuraImportKeywordData(NSData* data, sakura::core::TextEncoding encoding,
                                     BOOL defaultCaseSensitive, NSString** error);
NSData* SakuraExportKeywordData(NSDictionary* group, NSString** error);
