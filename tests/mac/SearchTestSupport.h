// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#pragma once
#import "SakuraEditorView.h"
inline bool SakuraWaitForSearchNavigation(SakuraEditorView* view) {
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:6];
  while (view.hasPendingSearchNavigation && deadline.timeIntervalSinceNow > 0)
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
  return !view.hasPendingSearchNavigation;
}
inline bool SakuraWaitForReplacement(SakuraEditorView* view) {
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:8];
  while (view.hasPendingReplacement && deadline.timeIntervalSinceNow > 0)
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
  return !view.hasPendingReplacement;
}
