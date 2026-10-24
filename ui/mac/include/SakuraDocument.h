// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#import <AppKit/AppKit.h>

#ifdef __cplusplus
#include <memory>
#include <optional>

#include "sakura/app/DocumentSession.h"
#endif

@interface SakuraDocument : NSDocument {
 @private
#ifdef __cplusplus
  std::unique_ptr<sakura::app::DocumentSession> _session;
  std::optional<sakura::app::DocumentSaveToken> _pendingSaveToken;
  sakura::core::LineEnding _preferredLineEnding;
#endif
}

#ifdef __cplusplus
- (sakura::app::DocumentSession&)documentSession;
- (void)setOutputEncoding:(sakura::core::TextEncoding)encoding
                  writeBom:(BOOL)writeBom;
- (BOOL)reloadUsingEncoding:(sakura::core::TextEncoding)encoding
                       error:(NSError**)error;
#endif

- (void)noteEditorChange:(NSDocumentChangeType)changeType;
- (void)refreshEditorViews;
- (NSString*)preferredLineEndingString;
- (NSString*)newlineInsertionString;
- (void)setPreferredLineEndingString:(NSString*)lineEnding;

+ (void)offerRecoveryIfNeeded;

@end
