// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#import <AppKit/AppKit.h>

@interface SakuraAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
- (void)saveAllDocuments:(id)sender;
@end
