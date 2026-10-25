// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#import <Foundation/Foundation.h>
#include <memory>
#include "sakura/core/text/TextBuffer.h"

namespace sakura::ui::mac { struct RecoveryWriterState; }

// Requests are made on main. Immutable snapshots, serialization, durable I/O,
// and snapshot disposal run on utility queues. Pending writes are coalesced;
// removal is an ordered barrier and must never be coalesced into a later write.
@interface SakuraRecoveryWriter : NSObject {
 @private
  std::shared_ptr<sakura::ui::mac::RecoveryWriterState> _state;
}
- (void)writeSnapshot:(const sakura::core::TextBuffer&)snapshot
            metadata:(NSDictionary*)metadata
               toURL:(NSURL*)url
              budget:(unsigned long long)budget
         generations:(NSUInteger)generations
          completion:(void (^)(NSError* error))completion;
- (void)removeAtURL:(NSURL*)url completion:(void (^)(NSError* error))completion;
@end

// Always asynchronous on main. At shutdown, first close/review all documents
// using NSDocumentController, then await this drain before replying to AppKit.
// Only operations submitted before the group becomes idle are covered.
void SakuraRecoveryWhenIdle(dispatch_block_t completion);
