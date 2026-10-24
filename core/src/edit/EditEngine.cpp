// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include "sakura/core/edit/EditEngine.h"

#include <stdexcept>
#include <type_traits>
#include <utility>

namespace sakura::core {

EditEngine::EditEngine(TextBuffer& buffer) : buffer_(buffer) {}

void EditEngine::insert(TextOffset offset, SakuraStringView text) {
  replace({offset, 0}, text);
}

void EditEngine::erase(TextRange range) {
  replace(range, {});
}

EditEngine::EditAction::Change EditEngine::prepareChange(
    const TextBuffer& buffer, TextRange range, SakuraStringView text) {
  // Validate the requested range before expanding it for history. Expansion
  // must never make a caller's split CRLF/surrogate edit appear valid.
  const auto replaced = buffer.slice(range);
  const auto end = range.location + range.length;
  if (!buffer.isEditBoundary(range.location) || !buffer.isEditBoundary(end)) {
    throw std::invalid_argument("edit would split an indivisible text sequence");
  }
  if (replaced == text) return {range.location, replaced, replaced};

  // Expand only when the result joins two previously separate units. Ordinary
  // edits at a line's start/end must keep the one-line index-update fast path.
  const auto joins = [](SakuraChar left, SakuraChar right) {
    return (left == u'\r' && right == u'\n') ||
           (left >= u'\xD800' && left <= u'\xDBFF' &&
            right >= u'\xDC00' && right <= u'\xDFFF');
  };
  const bool hasLeft = range.location != 0;
  const bool hasRight = end < buffer.length();
  const auto left = hasLeft ? buffer.slice({range.location - 1, 1}).front() : u'\0';
  const auto right = hasRight ? buffer.slice({end, 1}).front() : u'\0';
  const bool joinsAcrossDeletion = text.empty() && hasLeft && hasRight &&
      joins(left, right);
  const bool extendLeft = joinsAcrossDeletion ||
      (hasLeft && !text.empty() && joins(left, text.front()));
  const bool extendRight = joinsAcrossDeletion ||
      (hasRight && !text.empty() && joins(text.back(), right));
  auto first = range.location;
  if (extendLeft) {
    --first;
    while (first != 0 && !buffer.isEditBoundary(first)) --first;
  }
  auto last = end;
  if (extendRight) {
    ++last;
    while (last < buffer.length() && !buffer.isEditBoundary(last)) ++last;
  }
  EditAction::Change change;
  change.offset = first;
  change.before = buffer.slice({first, last - first});
  change.after = buffer.slice({first, range.location - first});
  change.after.append(text);
  change.after.append(buffer.slice({end, last - end}));
  return change;
}

void EditEngine::replace(TextRange range, SakuraStringView text) {
  EditAction action;
  auto change = prepareChange(buffer_, range, text);
  if (change.before == change.after) {
    return;
  }
  action.beforeState = stateId_;
  action.afterState = nextStateId_;

  action.changes.reserve(1);
  undoStack_.reserve(undoStack_.size() + 1);
  buffer_.replace({change.offset, change.before.size()}, change.after);
  action.changes.push_back(std::move(change));
  undoStack_.push_back(std::move(action));
  redoStack_.clear();
  stateId_ = undoStack_.back().afterState;
  ++nextStateId_;
}

void EditEngine::replaceMany(const std::vector<EditReplacement>& replacements) {
  if (replacements.empty()) {
    return;
  }
  if (replacements.size() == 1) {
    replace(replacements.front().range, replacements.front().text);
    return;
  }

  EditAction action;
  action.beforeState = stateId_;
  action.afterState = nextStateId_;
  action.changes.reserve(replacements.size());
  undoStack_.reserve(undoStack_.size() + 1);

  // A failed later replacement must not leave an unrecorded partial action.
  // Prepare the whole transaction off to the side, then publish without an
  // allocating copy. Single-character edits keep their logarithmic fast path.
  static_assert(std::is_nothrow_move_assignable_v<TextBuffer>);
  TextBuffer candidate = buffer_;

  for (const auto& replacement : replacements) {
    auto change = prepareChange(candidate, replacement.range, replacement.text);
    if (change.before == change.after) {
      continue;
    }
    candidate.replace({change.offset, change.before.size()}, change.after);
    action.changes.push_back(std::move(change));
  }

  if (action.changes.empty()) {
    return;
  }
  buffer_ = std::move(candidate);
  undoStack_.push_back(std::move(action));
  redoStack_.clear();
  stateId_ = undoStack_.back().afterState;
  ++nextStateId_;
}

bool EditEngine::canUndo() const noexcept {
  return !undoStack_.empty();
}

bool EditEngine::canRedo() const noexcept {
  return !redoStack_.empty();
}

bool EditEngine::undo() {
  if (undoStack_.empty()) {
    return false;
  }

  const auto& action = undoStack_.back();
  redoStack_.reserve(redoStack_.size() + 1);
  if (action.changes.size() == 1) {
    const auto& change = action.changes.front();
    buffer_.replace({change.offset, change.after.size()}, change.before);
  } else {
    TextBuffer candidate = buffer_;
    for (auto change = action.changes.rbegin(); change != action.changes.rend();
         ++change) {
      candidate.replace({change->offset, change->after.size()}, change->before);
    }
    buffer_ = std::move(candidate);
  }
  stateId_ = action.beforeState;
  redoStack_.push_back(std::move(undoStack_.back()));
  undoStack_.pop_back();
  return true;
}

bool EditEngine::redo() {
  if (redoStack_.empty()) {
    return false;
  }

  const auto& action = redoStack_.back();
  undoStack_.reserve(undoStack_.size() + 1);
  if (action.changes.size() == 1) {
    const auto& change = action.changes.front();
    buffer_.replace({change.offset, change.before.size()}, change.after);
  } else {
    TextBuffer candidate = buffer_;
    for (const auto& change : action.changes) {
      candidate.replace({change.offset, change.before.size()}, change.after);
    }
    buffer_ = std::move(candidate);
  }
  stateId_ = action.afterState;
  undoStack_.push_back(std::move(redoStack_.back()));
  redoStack_.pop_back();
  return true;
}

void EditEngine::clearHistory() noexcept {
  undoStack_.clear();
  redoStack_.clear();
  // State tokens may outlive an asynchronous save.  Never reuse one when a
  // different document is loaded into the same session.
  stateId_ = nextStateId_++;
}

std::uint64_t EditEngine::stateId() const noexcept {
  return stateId_;
}

}  // namespace sakura::core
