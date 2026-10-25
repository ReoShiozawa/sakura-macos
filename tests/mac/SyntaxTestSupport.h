// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#pragma once
#import "SakuraEditorView.h"
#include "sakura/core/syntax/SyntaxHighlighter.h"
@interface SakuraEditorView (SyntaxTestSupport)
- (const std::vector<sakura::core::SyntaxToken>&)activeSyntaxTokens;
@end
inline bool SakuraWaitForSyntax(SakuraEditorView* view) {
  (void)[view activeSyntaxTokens];
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:8];
  while (view.hasPendingSyntax && deadline.timeIntervalSinceNow > 0)
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
  return !view.hasPendingSyntax;
}
