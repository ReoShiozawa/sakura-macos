// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import <Foundation/Foundation.h>

// A post-rename failure means the new contents may already be present. Callers
// must retain dirty state/recovery and must not claim the old file survived.
extern NSString* const SakuraWriteCommittedKey;
typedef NS_ENUM(NSUInteger, SakuraDurableWriteStage) {
  SakuraDurableWriteFileSync,
  SakuraDurableWriteRename,
  SakuraDurableWriteDirectorySync,
  SakuraDurableWriteFinalSync,
};
typedef BOOL (^SakuraDurableWriteGate)(SakuraDurableWriteStage stage);
BOOL SakuraDurableReplaceData(NSData* data, NSURL* url, NSError** error);
// Fault gate is for isolated tests; production always uses the ungated entry.
BOOL SakuraDurableReplaceDataWithGate(NSData* data, NSURL* url,
    NSError** error, SakuraDurableWriteGate gate);
BOOL SakuraSynchronizeSavedFile(NSURL* url, NSError** error);
