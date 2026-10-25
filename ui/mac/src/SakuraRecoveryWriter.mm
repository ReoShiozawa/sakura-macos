// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#import "SakuraRecoveryWriter.h"
#import "SakuraRecoveryStore.h"
#include "sakura/platform/mac/StringBridge.h"
#include <atomic>
#include <deque>
#include <exception>
#include <mutex>
#include <optional>

using RecoveryWriteHandler = BOOL (^)(NSURL*, NSDictionary*, unsigned long long,
                                     NSUInteger, NSError**);
using RecoveryRemoveHandler = BOOL (^)(NSURL*, NSError**);

namespace sakura::ui::mac {
struct RecoveryJob {
  bool removal{};
  std::uint64_t epoch{}, sequence{};
  std::optional<core::TextBuffer> snapshot;
  NSDictionary* metadata;
  NSURL* url;
  unsigned long long budget{};
  NSUInteger generations{};
  void (^completion)(NSError*);
};
struct RecoveryWriterState {
  std::mutex mutex;
  std::deque<std::unique_ptr<RecoveryJob>> pending;
  bool scheduled{};
  std::atomic<std::uint64_t> epoch{}, sequence{};
  RecoveryWriteHandler writer;
  RecoveryRemoveHandler remover;
};
} // namespace sakura::ui::mac

namespace {
using namespace sakura::ui::mac;
dispatch_queue_t recoveryQueue() {
  static dispatch_queue_t queue = dispatch_queue_create(
      "local.unofficial-sakura.recovery", dispatch_queue_attr_make_with_qos_class(
          DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
  return queue;
}
dispatch_group_t recoveryGroup() {
  static dispatch_group_t group = dispatch_group_create();
  return group;
}
void onMain(dispatch_block_t completion) {
  // NSTerminateLater runs AppKit's modal loop. Common-mode run-loop blocks
  // remain deliverable even when a nested modal loop cannot service main GCD.
  CFRunLoopRef loop = CFRunLoopGetMain();
  CFRunLoopPerformBlock(loop, kCFRunLoopCommonModes, completion);
  CFRunLoopWakeUp(loop);
}
NSError* recoveryException(NSString* reason) {
  return [NSError errorWithDomain:@"SakuraRecovery" code:2 userInfo:@{
    NSLocalizedDescriptionKey:@"復旧バックアップの処理に失敗しました。文書を明示的に保存してください。",
    NSLocalizedFailureReasonErrorKey:reason ? reason : @"Unknown exception"}];
}

void drainOne(std::shared_ptr<RecoveryWriterState> state);
void schedule(std::shared_ptr<RecoveryWriterState> state) {
  // Called with state->mutex held. Enter before publishing the queued block so
  // a main-thread shutdown drain also sees work not yet started by the worker.
  state->scheduled = true;
  dispatch_group_async(recoveryGroup(), recoveryQueue(), ^{ drainOne(state); });
}

void drainOne(std::shared_ptr<RecoveryWriterState> state) {
  @autoreleasepool {
    std::unique_ptr<RecoveryJob> job;
    {
      std::lock_guard lock(state->mutex);
      job = std::move(state->pending.front());
      state->pending.pop_front();
    }
    NSError* error = nil;
    bool executed = false;
    @try {
      try {
        // A removal invalidates queued/serializing old writes. If a write has
        // already entered durable I/O it is allowed to finish; the same serial
        // queue then executes removal before any newer write.
        if (job->epoch == state->epoch.load()) {
          if (job->removal) {
            executed = true;
            if (!state->remover(job->url, &error) && !error)
              error = recoveryException(@"Recovery removal failed");
          } else {
            NSMutableDictionary* record = [job->metadata mutableCopy];
            record[@"text"] = sakura::platform::mac::stringFromTextBuffer(*job->snapshot);
            if (job->epoch == state->epoch.load()) {
              executed = true;
              if (!state->writer(job->url, record, job->budget, job->generations, &error) && !error)
                error = recoveryException(@"Recovery write failed");
            }
          }
        }
      } catch (const std::exception& exception) {
        executed = true;
        error = recoveryException([NSString stringWithUTF8String:exception.what()]);
      } catch (...) {
        executed = true;
        error = recoveryException(@"Unknown C++ exception");
      }
    } @catch (NSException* exception) {
      executed = true;
      error = recoveryException(exception.reason);
    }
    if (executed && job->completion) {
      const auto epoch = job->epoch, sequence = job->sequence;
      void (^completion)(NSError*) = job->completion;
      onMain(^{
        // Old errors/successes cannot replace the status of newer requests.
        if (epoch == state->epoch.load() && sequence == state->sequence.load())
          completion(error);
      });
    }
    job.reset(); // Large snapshots must not be destroyed on main.
    {
      std::lock_guard lock(state->mutex);
      state->scheduled = false;
      if (!state->pending.empty()) schedule(state);
    }
  }
}

void submit(const std::shared_ptr<RecoveryWriterState>& state,
            std::unique_ptr<RecoveryJob> job) {
  NSCAssert(NSThread.isMainThread, @"Recovery requests must be submitted on main");
  auto discarded = std::make_shared<std::deque<std::unique_ptr<RecoveryJob>>>();
  {
    std::lock_guard lock(state->mutex);
    job->sequence = ++state->sequence;
    if (job->removal) {
      job->epoch = ++state->epoch;
      // Supersede ALL queued work, but retain the new removal barrier itself.
      discarded->swap(state->pending);
    } else {
      job->epoch = state->epoch.load();
      if (!state->pending.empty() && !state->pending.back()->removal) {
        discarded->push_back(std::move(state->pending.back()));
        state->pending.pop_back();
      }
    }
    state->pending.push_back(std::move(job));
    if (!state->scheduled) schedule(state);
  }
  // A slow fsync on the serial I/O queue must not retain arbitrarily many
  // superseded roots, and releasing old history on main can itself block UI.
  if (!discarded->empty()) {
    dispatch_group_async(recoveryGroup(), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      @autoreleasepool { discarded->clear(); }
    });
  }
}
} // namespace

@implementation SakuraRecoveryWriter
- (instancetype)init {
  return [self initWithWriteHandler:^BOOL(NSURL* url, NSDictionary* record,
      unsigned long long budget, NSUInteger generations, NSError** error) {
    return SakuraWriteRecoveryWithGenerations(url, record, budget, generations, error);
  } removeHandler:^BOOL(NSURL* url, NSError** error) {
    return SakuraRemoveRecoveryChecked(url, error);
  }];
}

// Injectable I/O is private to deterministic tests; production always uses the
// durable store above, without sleeps or environment-controlled fault hooks.
- (instancetype)initWithWriteHandler:(RecoveryWriteHandler)writer
                       removeHandler:(RecoveryRemoveHandler)remover {
  self = [super init];
  if (self) {
    _state = std::make_shared<RecoveryWriterState>();
    _state->writer = [writer copy];
    _state->remover = [remover copy];
  }
  return self;
}

- (void)writeSnapshot:(const sakura::core::TextBuffer&)snapshot
            metadata:(NSDictionary*)metadata toURL:(NSURL*)url
              budget:(unsigned long long)budget generations:(NSUInteger)generations
          completion:(void (^)(NSError*))completion {
  auto job = std::make_unique<RecoveryJob>();
  job->snapshot.emplace(snapshot);
  job->metadata = [metadata copy];
  job->url = [url copy];
  job->budget = budget;
  job->generations = generations;
  job->completion = [completion copy];
  submit(_state, std::move(job));
}

- (void)removeAtURL:(NSURL*)url completion:(void (^)(NSError*))completion {
  auto job = std::make_unique<RecoveryJob>();
  job->removal = true;
  job->url = [url copy];
  job->completion = [completion copy];
  submit(_state, std::move(job));
}
@end

void SakuraRecoveryWhenIdle(dispatch_block_t completion) {
  NSCAssert(NSThread.isMainThread, @"Recovery drain must be requested on main");
  dispatch_group_notify(recoveryGroup(), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    onMain(completion);
  });
}
