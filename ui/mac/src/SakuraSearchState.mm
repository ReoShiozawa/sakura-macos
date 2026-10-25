// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import "SakuraSearchState.h"
NSNotificationName const SakuraSearchStateDidChangeNotification = @"SakuraSearchStateDidChange";
@interface SakuraSearchState ()
@property(nonatomic, copy, readwrite) NSDictionary* criteria;
@property(nonatomic, copy, readwrite) NSArray<NSString*>* queryHistory;
@property(nonatomic, copy, readwrite) NSArray<NSString*>* replacementHistory;
@end
@implementation SakuraSearchState
+ (instancetype)sharedState {
  static SakuraSearchState* state; static dispatch_once_t once;
  dispatch_once(&once, ^{ state = [[SakuraSearchState alloc] init]; }); return state;
}
- (instancetype)init {
  if ((self = [super init])) {
    _criteria = @{@"query":@"", @"replacement":@"", @"caseSensitive":@YES,
        @"wholeWord":@NO, @"regex":@NO, @"wrap":@YES};
    _queryHistory = @[]; _replacementHistory = @[];
  }
  return self;
}
- (NSArray*)history:(NSArray*)old adding:(NSString*)text {
  if (text.length > 4096) return old;
  NSMutableArray* result = old.mutableCopy; [result removeObject:text]; [result insertObject:text.copy atIndex:0];
  if (result.count > 20) [result removeLastObject]; return result;
}
- (BOOL)updateCriteria:(NSDictionary*)criteria source:(id)source rememberQuery:(BOOL)query rememberReplacement:(BOOL)replacement {
  if (![criteria[@"query"] isKindOfClass:NSString.class] || ![criteria[@"replacement"] isKindOfClass:NSString.class] ||
      [criteria[@"query"] length] > 4096 || [criteria[@"replacement"] length] > 65536) return NO;
  NSMutableDictionary* snapshot = [@{@"query":[criteria[@"query"] copy], @"replacement":[criteria[@"replacement"] copy]} mutableCopy];
  for (NSString* key in @[@"caseSensitive", @"wholeWord", @"regex", @"wrap"]) {
    if (![criteria[key] isKindOfClass:NSNumber.class]) return NO;
    snapshot[key] = @([criteria[key] boolValue]);
  }
  self.criteria = snapshot;
  if (query && [snapshot[@"query"] length]) self.queryHistory = [self history:self.queryHistory adding:snapshot[@"query"]];
  if (replacement) self.replacementHistory = [self history:self.replacementHistory adding:snapshot[@"replacement"]];
  [NSNotificationCenter.defaultCenter postNotificationName:SakuraSearchStateDidChangeNotification object:self
      userInfo:source != nil ? @{@"source":source} : nil];
  return YES;
}
- (void)clearHistory {
  self.queryHistory = @[]; self.replacementHistory = @[];
  NSMutableDictionary* empty = self.criteria.mutableCopy; empty[@"query"] = @""; empty[@"replacement"] = @"";
  self.criteria = empty;
  [NSNotificationCenter.defaultCenter postNotificationName:SakuraSearchStateDidChangeNotification object:self];
}
@end
