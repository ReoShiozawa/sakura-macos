// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import <Foundation/Foundation.h>

// Recovery data is unencrypted. Never evict another document to make room.
extern NSString* const SakuraRecoveryGenerationsKey;
extern NSString* const SakuraRecoveryBudgetMiBKey;
NSUInteger SakuraRecoveryGenerations(NSUserDefaults* defaults);
NSUInteger SakuraRecoveryBudgetMiB(NSUserDefaults* defaults);
BOOL SakuraSetRecoverySettings(NSUserDefaults* defaults, NSInteger generations,
                              NSInteger budgetMiB, NSError** error);
NSDictionary* SakuraReadRecovery(NSURL* url);
BOOL SakuraWriteRecovery(NSURL* url, NSDictionary* record,
                         unsigned long long budget, NSError** error);
BOOL SakuraWriteRecoveryWithGenerations(NSURL* url, NSDictionary* record,
    unsigned long long budget, NSUInteger generations, NSError** error);
void SakuraRemoveRecovery(NSURL* url);
// Success includes an already absent recovery directory. Busy locks, unsafe
// entries, unlink failures and deletion-sync failures are observable errors.
BOOL SakuraRemoveRecoveryChecked(NSURL* url, NSError** error);
