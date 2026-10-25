// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import <Foundation/Foundation.h>
extern NSNotificationName const SakuraSearchStateDidChangeNotification;
// Main-thread, in-memory only. Never writes find strings to preferences/files.
@interface SakuraSearchState : NSObject
+ (instancetype)sharedState;
@property(nonatomic, copy, readonly) NSDictionary* criteria;
@property(nonatomic, copy, readonly) NSArray<NSString*>* queryHistory;
@property(nonatomic, copy, readonly) NSArray<NSString*>* replacementHistory;
- (BOOL)updateCriteria:(NSDictionary*)criteria source:(id)source
        rememberQuery:(BOOL)query rememberReplacement:(BOOL)replacement;
- (void)clearHistory;
@end
