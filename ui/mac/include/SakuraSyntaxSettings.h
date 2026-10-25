// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import <Foundation/Foundation.h>
#include "sakura/core/syntax/CustomSyntax.h"

NSString* SakuraSyntaxPreferenceKey(NSString* type);
NSDictionary* SakuraSyntaxPreferences(NSString* type, NSUserDefaults* defaults);
NSArray<NSDictionary*>* SakuraSyntaxGroups(NSDictionary* preferences);
NSDictionary* SakuraSyntaxPreferencesFromGroups(NSArray<NSDictionary*>* groups);
BOOL SakuraSyntaxPreferencesHaveRules(NSDictionary* preferences);
NSString* SakuraParseSyntaxPreferences(NSDictionary* preferences, sakura::core::CustomSyntaxRules& rules);
// Merge only edited fields; a stale panel must not republish unchanged fields.
void SakuraSaveSyntaxPreferences(NSString* type, NSUserDefaults* defaults,
                                 NSDictionary* draft, NSDictionary* baseline);
