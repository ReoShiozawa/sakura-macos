// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#include "BufferUText.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <exception>
#include <limits>
#include <mutex>
#include <stdexcept>

namespace sakura::core::detail {
struct BufferUTextState {
  std::function<bool()> cancelled;
  std::mutex mutex;
  std::exception_ptr failure;
  std::atomic<bool> failed{};
  std::atomic<std::uint64_t> chunkLoads{}, copiedUnits{}, extractedUnits{}, peakChunkUnits{};
  void check() const {
    if (cancelled && cancelled()) throw std::runtime_error("Search cancelled");
  }
  void fail() noexcept {
    std::lock_guard lock(mutex);
    if (!failure) failure = std::current_exception();
    failed = true;
  }
};
namespace {
struct Context {
  TextBuffer source;
  std::shared_ptr<const TextBuffer> identity;
  std::shared_ptr<BufferUTextState> state;
  std::array<UChar, BufferUText::chunkUnits + 2> units{};
};
Context& context(const UText* text) noexcept {
  return *const_cast<Context*>(static_cast<const Context*>(text->p));
}
void emptyChunk(UText* text, std::int64_t index) noexcept {
  text->chunkNativeStart = text->chunkNativeLimit = index;
  text->chunkOffset = text->chunkLength = text->nativeIndexingLimit = 0;
}
UBool U_CALLCONV access(UText* text, std::int64_t requested, UBool forward) noexcept {
  auto& value = context(text);
  const auto length = static_cast<std::int64_t>(value.source.length());
  auto index = std::clamp<std::int64_t>(requested, 0, length);
  try {
    value.state->check();
    // access() itself, not only the common UText iterator entry points, must
    // leave the position at the beginning of a code point.
    if (index && index < length && !value.source.isCodePointBoundary(index)) --index;
    if ((forward && index == length) || (!forward && index == 0)) {
      emptyChunk(text, index);
      return false;
    }
    if (!((forward && index >= text->chunkNativeStart && index < text->chunkNativeLimit) ||
          (!forward && index > text->chunkNativeStart && index <= text->chunkNativeLimit))) {
      const auto anchor = forward ? index : index - 1;
      auto begin = anchor / BufferUText::chunkUnits * BufferUText::chunkUnits;
      auto end = std::min<std::uint64_t>(length, begin + BufferUText::chunkUnits);
      // UText chunks may split CR/LF but never a paired surrogate/code point.
      if (begin && !value.source.isCodePointBoundary(begin)) --begin;
      if (end < value.source.length() && !value.source.isCodePointBoundary(end)) ++end;
      const auto count = static_cast<std::size_t>(end - begin);
      static_assert(sizeof(UChar) == sizeof(SakuraChar));
      value.source.copyText({begin, count},
          {reinterpret_cast<SakuraChar*>(value.units.data()), count});
      text->chunkNativeStart = static_cast<std::int64_t>(begin);
      text->chunkNativeLimit = static_cast<std::int64_t>(end);
      text->chunkLength = text->nativeIndexingLimit = static_cast<std::int32_t>(count);
      ++value.state->chunkLoads;
      value.state->copiedUnits += count;
      auto peak = value.state->peakChunkUnits.load();
      while (peak < count && !value.state->peakChunkUnits.compare_exchange_weak(peak, count)) {}
    }
    text->chunkOffset = static_cast<std::int32_t>(index - text->chunkNativeStart);
    return true;
  } catch (...) {
    value.state->fail();
    emptyChunk(text, index);
    return false;
  }
}
std::int64_t U_CALLCONV nativeLength(UText* text) noexcept {
  return static_cast<std::int64_t>(context(text).source.length());
}
void U_CALLCONV close(UText* text) noexcept {
  delete static_cast<const Context*>(text->p);
  text->p = nullptr;
  text->context = nullptr;
  text->chunkContents = nullptr;
}
std::int32_t U_CALLCONV extract(UText* text, std::int64_t begin, std::int64_t end,
    UChar* destination, std::int32_t capacity, UErrorCode* status) noexcept {
  if (U_FAILURE(*status)) return 0;
  if (capacity < 0 || (capacity && !destination) || end < begin) {
    *status = U_ILLEGAL_ARGUMENT_ERROR;
    return 0;
  }
  auto& value = context(text);
  const auto length = static_cast<std::int64_t>(value.source.length());
  begin = std::clamp<std::int64_t>(begin, 0, length);
  end = std::clamp<std::int64_t>(end, 0, length);
  try {
    value.state->check();
    // Normalize the requested range so that endpoints alone cannot split a
    // valid pair (capacity truncation still follows ordinary UTF-16 rules).
    // Snap the start backward and limit forward, with the same required length for
    // preflight and copying. ICU's built-in UChars provider has a historical
    // capacity-dependent return length for a split limit; do not reproduce it.
    if (begin && begin < length && !value.source.isCodePointBoundary(begin)) --begin;
    if (end && end < length && !value.source.isCodePointBoundary(end)) ++end;
    const auto required = end - begin;
    if (required > INT32_MAX) { *status = U_INDEX_OUTOFBOUNDS_ERROR; return 0; }
    const auto copied = std::min<std::int64_t>(required, capacity);
    for (std::int64_t at = 0; at < copied; at += BufferUText::chunkUnits) {
      value.state->check();
      const auto count = static_cast<std::size_t>(std::min<std::int64_t>(BufferUText::chunkUnits, copied-at));
      value.source.copyText({static_cast<TextOffset>(begin+at), count},
          {reinterpret_cast<SakuraChar*>(destination+at), count});
      value.state->extractedUnits += count;
    }
    if (required < capacity) {
      destination[required] = 0;
      if (*status == U_STRING_NOT_TERMINATED_WARNING) *status = U_ZERO_ERROR;
    }
    else if (required > capacity) *status = U_BUFFER_OVERFLOW_ERROR;
    else *status = U_STRING_NOT_TERMINATED_WARNING;
    utext_setNativeIndex(text, end);
    return static_cast<std::int32_t>(required);
  } catch (...) {
    value.state->fail();
    *status = U_INTERNAL_PROGRAM_ERROR;
    return 0;
  }
}
UText* open(UText* destination, std::shared_ptr<const TextBuffer> identity,
            std::shared_ptr<BufferUTextState> state, UErrorCode* status);
UText* U_CALLCONV clone(UText* destination, const UText* original, UBool deep,
                        UErrorCode* status) noexcept {
  if (U_FAILURE(*status)) return nullptr;
  try {
    // Capture before setup(), which can close an already open destination.
    const auto source = context(original).source;
    auto identity = context(original).identity;
    // utext_equals() uses context pointer identity, not a provider callback.
    // Shallow clones share their source identity; deep clones have a separate
    // logical immutable document but can still share persistent storage.
    if (deep) identity = std::make_shared<const TextBuffer>(source);
    const auto state = context(original).state;
    const auto index = utext_getNativeIndex(original);
    UText* result = open(destination, std::move(identity), state, status);
    if (result) utext_setNativeIndex(result, index);
    return result;
  } catch (...) {
    *status = U_MEMORY_ALLOCATION_ERROR;
    return nullptr;
  }
}
const UTextFuncs functions = {
  sizeof(UTextFuncs), 0, 0, 0, clone, nativeLength, access, extract,
  nullptr, nullptr, nullptr, nullptr, close, nullptr, nullptr, nullptr
};
UText* open(UText* destination, std::shared_ptr<const TextBuffer> identity,
            std::shared_ptr<BufferUTextState> state, UErrorCode* status) {
  if (U_FAILURE(*status)) return nullptr;
  auto value = std::make_unique<Context>(Context{*identity, identity, std::move(state), {}});
  UText* result = utext_setup(destination, 0, status);
  if (!result || U_FAILURE(*status)) return result;
  result->pFuncs = &functions;
  result->providerProperties = 1 << UTEXT_PROVIDER_OWNS_TEXT;
  result->context = identity.get();
  result->p = value.release();
  result->chunkContents = context(result).units.data();
  emptyChunk(result, 0);
  return result;
}
} // namespace

BufferUText::BufferUText(const TextBuffer& buffer, const std::function<bool()>& cancelled)
    : state_(std::make_shared<BufferUTextState>()) {
  if (buffer.length() > INT64_MAX) throw std::length_error("ICU text length exceeds int64 range");
  state_->cancelled = cancelled;
  state_->check();
  UErrorCode status = U_ZERO_ERROR;
  text_.reset(open(nullptr, std::make_shared<const TextBuffer>(buffer), state_, &status));
  if (U_FAILURE(status) || !text_) throw std::runtime_error("ICU text provider initialization failed");
}
void BufferUText::rethrowFailure() const {
  if (!state_->failed.load()) return;
  std::lock_guard lock(state_->mutex);
  if (state_->failure) std::rethrow_exception(state_->failure);
}
BufferUText::Statistics BufferUText::statistics() const noexcept {
  return {state_->chunkLoads.load(), state_->copiedUnits.load(),
          state_->extractedUnits.load(), state_->peakChunkUnits.load()};
}
} // namespace sakura::core::detail
