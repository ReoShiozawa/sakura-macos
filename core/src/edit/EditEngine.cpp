// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include "sakura/core/edit/EditEngine.h"
#include <algorithm>
#include <limits>
#include <stdexcept>
#include <utility>

namespace sakura::core {
struct EditEngine::EditAction {
  TextBuffer before, after;
  std::uint64_t beforeState{}, afterState{};
  std::uint64_t revisionSteps{1};
};
struct EditEngine::HistoryNode {
  std::shared_ptr<const EditAction> action;
  std::shared_ptr<const HistoryNode> next;
  // The last owner can disappear concurrently in distinct snapshots. Checking
  // use_count() in releaseHistory alone cannot prevent the final shared_ptr
  // destructor from recursing; every node also drains its tail iteratively.
  ~HistoryNode() { EditEngine::releaseHistory(next); }
};
struct EditEngine::PreparedEdit::Data {
  Snapshot source;
  std::shared_ptr<EditAction> action;
  std::shared_ptr<HistoryNode> entry;
  std::shared_ptr<const HistoryNode> retiredRedo;
  bool changed{}, consumed{};
  ~Data() {
    EditEngine::releaseHistory(retiredRedo);
    std::shared_ptr<const HistoryNode> retained = std::move(entry);
    EditEngine::releaseHistory(retained);
  }
};
struct EditEngine::HistorySnapshot::Data {
  Snapshot source;
  std::shared_ptr<const HistoryNode> undo, redo;
  Data(Snapshot snapshot, std::shared_ptr<const HistoryNode> undoHead,
       std::shared_ptr<const HistoryNode> redoHead)
      : source(std::move(snapshot)), undo(std::move(undoHead)), redo(std::move(redoHead)) {}
  ~Data() {
    EditEngine::releaseHistory(undo);
    EditEngine::releaseHistory(redo);
  }
};
struct EditEngine::PreparedHistory::Data {
  HistorySnapshot source;
  TextBuffer result;
  std::shared_ptr<const HistoryNode> undo, redo;
  std::uint64_t targetState{}, revisionSteps{};
  bool changed{}, consumed{};
  ~Data() {
    EditEngine::releaseHistory(undo);
    EditEngine::releaseHistory(redo);
  }
};
namespace {
void checkCancelled(const std::function<bool()>& cancelled) {
  if (cancelled && cancelled()) throw std::runtime_error("edit preparation cancelled");
}
void append(SakuraString& destination, SakuraStringView text, const std::function<bool()>& cancelled) {
  if (!cancelled) { destination.append(text); return; }
  for (std::size_t offset = 0; offset < text.size(); offset += 65536) {
    checkCancelled(cancelled);
    destination.append(text.substr(offset, std::min<std::size_t>(65536, text.size() - offset)));
  }
}
bool sameText(SakuraStringView first, SakuraStringView second, const std::function<bool()>& cancelled) {
  if (first.size() != second.size()) return false;
  for (std::size_t offset = 0; offset < first.size(); offset += 65536) {
    checkCancelled(cancelled);
    const auto count = std::min<std::size_t>(65536, first.size() - offset);
    if (first.substr(offset, count) != second.substr(offset, count)) return false;
  }
  return true;
}
}

EditEngine::EditEngine(TextBuffer& buffer) : buffer_(buffer), currentVersion_(buffer), owner_(std::make_shared<const char>(0)) {}
EditEngine::~EditEngine() { releaseHistory(undoStack_); releaseHistory(redoStack_); }
void EditEngine::releaseHistory(std::shared_ptr<const HistoryNode>& head) noexcept {
  // A long unique history chain must not recurse through shared_ptr destructors.
  auto current = std::move(head);
  while (current && current.use_count() == 1) {
    auto next = current->next;
    current.reset(); current = std::move(next);
  }
}
EditEngine::PreparedEdit::PreparedEdit() noexcept = default;
EditEngine::PreparedEdit::~PreparedEdit() = default;
EditEngine::PreparedEdit::PreparedEdit(PreparedEdit&&) noexcept = default;
EditEngine::PreparedEdit& EditEngine::PreparedEdit::operator=(PreparedEdit&&) noexcept = default;
bool EditEngine::PreparedEdit::hasChanges() const noexcept { return data_ && data_->changed; }
const TextBuffer& EditEngine::PreparedEdit::resultingBuffer() const {
  if (!data_) throw std::logic_error("edit preparation has no result");
  return data_->action->after;
}
bool EditEngine::ownsCurrentVersion() const noexcept {
  return buffer_.revision() == currentVersion_.revision() && buffer_.sharesStorageWith(currentVersion_);
}
EditEngine::Snapshot EditEngine::snapshot() const {
  if (!ownsCurrentVersion()) throw std::logic_error("buffer was changed outside its edit engine; clear history explicitly before further edits");
  return Snapshot(buffer_, owner_, stateId_);
}

EditEngine::PreparedEdit EditEngine::makePrepared(const Snapshot& source, TextBuffer candidate, bool changed) {
  PreparedEdit result;
  const auto steps = std::max<std::uint64_t>(1, candidate.revision() - source.buffer_.revision());
  auto action = std::make_shared<EditAction>(EditAction{source.buffer_, std::move(candidate), 0, 0, steps});
  auto entry = std::make_shared<HistoryNode>(HistoryNode{action, {}});
  result.data_ = std::unique_ptr<PreparedEdit::Data>(new PreparedEdit::Data{source, std::move(action), std::move(entry), {}, changed, false});
  return result;
}
bool EditEngine::commitPrepared(PreparedEdit& prepared) noexcept {
  auto* data = prepared.data_.get();
  if (!data || data->consumed) return false;
  data->consumed = true;
  if (!ownsCurrentVersion() || data->source.owner_ != owner_ || data->source.state_ != stateId_ ||
      data->source.buffer_.revision() != buffer_.revision() || !data->source.buffer_.sharesStorageWith(buffer_))
    return false;
  if (!data->changed) return true;
  data->action->beforeState = stateId_;
  data->action->afterState = nextStateId_++;
  data->entry->next = undoStack_;
  data->retiredRedo = std::move(redoStack_);
  buffer_.restoreSnapshot(data->action->after, data->action->revisionSteps);
  currentVersion_ = buffer_;
  undoStack_ = data->entry;
  stateId_ = data->action->afterState;
  return true;
}

const TextBuffer& EditEngine::HistorySnapshot::buffer() const {
  if (!data_) throw std::logic_error("history snapshot has no source");
  return data_->source.buffer_;
}
bool EditEngine::HistorySnapshot::canUndo() const noexcept { return data_ && data_->undo; }
bool EditEngine::HistorySnapshot::canRedo() const noexcept { return data_ && data_->redo; }
EditEngine::PreparedHistory::PreparedHistory() noexcept = default;
EditEngine::PreparedHistory::~PreparedHistory() = default;
EditEngine::PreparedHistory::PreparedHistory(PreparedHistory&&) noexcept = default;
EditEngine::PreparedHistory& EditEngine::PreparedHistory::operator=(PreparedHistory&&) noexcept = default;
bool EditEngine::PreparedHistory::hasChanges() const noexcept { return data_ && data_->changed; }
const TextBuffer& EditEngine::PreparedHistory::resultingBuffer() const {
  if (!data_) throw std::logic_error("history preparation has no result");
  return data_->result;
}
EditEngine::HistorySnapshot EditEngine::historySnapshot() const {
  HistorySnapshot result;
  result.data_ = std::make_shared<const HistorySnapshot::Data>(snapshot(), undoStack_, redoStack_);
  return result;
}
EditEngine::PreparedHistory EditEngine::prepareHistory(const HistorySnapshot& source,
    HistoryDirection direction, const std::function<bool()>& cancelled) {
  if (!source.data_ || (direction != HistoryDirection::undo && direction != HistoryDirection::redo))
    throw std::invalid_argument("invalid history snapshot or direction");
  checkCancelled(cancelled);
  const auto& data = *source.data_;
  const bool undoing = direction == HistoryDirection::undo;
  const auto entry = undoing ? data.undo : data.redo;
  PreparedHistory prepared;
  prepared.data_ = std::unique_ptr<PreparedHistory::Data>(new PreparedHistory::Data{
      source, data.source.buffer_, data.undo, data.redo, data.source.state_, 0, false, false});
  if (!entry) {
    checkCancelled(cancelled);
    return prepared;
  }
  const auto& action = *entry->action;
  auto opposite = std::make_shared<const HistoryNode>(HistoryNode{
      entry->action, undoing ? data.redo : data.undo});
  const auto& target = undoing ? action.before : action.after;
  prepared.data_->result.restoreSnapshot(target, action.revisionSteps);
  prepared.data_->undo = undoing ? entry->next : opposite;
  prepared.data_->redo = undoing ? opposite : entry->next;
  prepared.data_->targetState = undoing ? action.beforeState : action.afterState;
  prepared.data_->revisionSteps = action.revisionSteps;
  prepared.data_->changed = true;
  checkCancelled(cancelled);
  return prepared;
}
bool EditEngine::commitPreparedHistory(PreparedHistory& prepared) noexcept {
  auto* data = prepared.data_.get();
  if (!data || data->consumed) return false;
  data->consumed = true;
  const auto& source = *data->source.data_;
  if (!ownsCurrentVersion() || source.source.owner_ != owner_ || source.source.state_ != stateId_ ||
      source.source.buffer_.revision() != buffer_.revision() ||
      !source.source.buffer_.sharesStorageWith(buffer_) ||
      source.undo != undoStack_ || source.redo != redoStack_)
    return false;
  if (!data->changed) return true;
  buffer_.restoreSnapshot(data->result, data->revisionSteps);
  currentVersion_ = buffer_;
  undoStack_ = data->undo;
  redoStack_ = data->redo;
  stateId_ = data->targetState;
  return true;
}

EditEngine::PreparedEdit EditEngine::prepareSequential(const std::vector<EditReplacement>& replacements) const {
  const auto source = snapshot();
  TextBuffer candidate = source.buffer_;
  bool changed = false;
  for (const auto& replacement : replacements) {
    const auto& range = replacement.range;
    const auto before = candidate.slice(range);
    if (!candidate.isEditBoundary(range.location) || !candidate.isEditBoundary(range.location + range.length))
      throw std::invalid_argument("edit would split an indivisible text sequence");
    if (before == replacement.text) continue;
    candidate.replace(range, replacement.text); changed = true;
  }
  return makePrepared(source, std::move(candidate), changed);
}
void EditEngine::insert(TextOffset offset, SakuraStringView text) { replace({offset, 0}, text); }
void EditEngine::erase(TextRange range) { replace(range, {}); }
void EditEngine::replace(TextRange range, SakuraStringView text) {
  const auto before = buffer_.slice(range);
  if (!buffer_.isEditBoundary(range.location) || !buffer_.isEditBoundary(range.location + range.length))
    throw std::invalid_argument("edit would split an indivisible text sequence");
  if (before == text) return;
  const auto source = snapshot();
  auto candidate = buffer_;
  candidate.replace(range, text);
  auto prepared = makePrepared(source, std::move(candidate), true);
  (void)commitPrepared(prepared);
}
void EditEngine::replaceMany(const std::vector<EditReplacement>& replacements) {
  if (replacements.empty()) return;
  if (replacements.size() == 1) { replace(replacements.front().range, replacements.front().text); return; }
  auto prepared = prepareSequential(replacements);
  (void)commitPrepared(prepared);
}

EditEngine::PreparedEdit EditEngine::prepareOriginalRanges(const Snapshot& source,
    const std::vector<EditReplacement>& replacements, const std::function<bool()>& cancelled) {
  if (!source.owner_) throw std::invalid_argument("invalid edit snapshot");
  checkCancelled(cancelled);
  const auto& base = source.buffer_;
  struct Group { std::size_t first, end, firstLine, endLine; };
  std::vector<Group> groups;
  TextOffset precedingEnd = 0;
  for (std::size_t index = 0; index < replacements.size(); ++index) {
    checkCancelled(cancelled);
    const auto range = replacements[index].range;
    if (range.location > base.length() || range.length > base.length() - range.location ||
        (index != 0 && range.location < precedingEnd) || !base.isEditBoundary(range.location) ||
        !base.isEditBoundary(range.location + range.length))
      throw std::invalid_argument("original edit ranges are invalid, overlapping or unsorted");
    precedingEnd = range.location + range.length;
    const auto first = base.positionAt(range.location).line;
    const auto last = base.positionAt(precedingEnd).line;
    const auto firstLine = first ? first - 1 : 0;
    const auto endLine = std::min(base.lineCount(), last + 2);
    if (!groups.empty() && firstLine <= groups.back().endLine) {
      groups.back().end = index + 1; groups.back().endLine = std::max(groups.back().endLine, endLine);
    } else groups.push_back({index, index + 1, firstLine, endLine});
  }
  TextBuffer candidate = base;
  bool changed = false;
  for (auto group = groups.rbegin(); group != groups.rend(); ++group) {
    checkCancelled(cancelled);
    const auto start = base.lineStartOffset(group->firstLine);
    const auto end = group->endLine == base.lineCount() ? base.length() : base.lineStartOffset(group->endLine);
    const auto original = base.slice({start, end - start}, cancelled);
    SakuraString result;
    TextOffset cursor = start;
    for (auto index = group->first; index < group->end; ++index) {
      checkCancelled(cancelled);
      const auto& edit = replacements[index];
      append(result, SakuraStringView(original).substr(cursor - start, edit.range.location - cursor), cancelled);
      append(result, edit.text, cancelled);
      cursor = edit.range.location + edit.range.length;
    }
    append(result, SakuraStringView(original).substr(cursor - start), cancelled);
    if (sameText(original, result, cancelled)) continue;
    candidate.replace({start, end - start}, result, cancelled);
    changed = true;
  }
  checkCancelled(cancelled);
  return makePrepared(source, std::move(candidate), changed);
}

bool EditEngine::canUndo() const noexcept { return ownsCurrentVersion() && static_cast<bool>(undoStack_); }
bool EditEngine::canRedo() const noexcept { return ownsCurrentVersion() && static_cast<bool>(redoStack_); }
bool EditEngine::undo() {
  if (!canUndo()) return false;
  auto prepared = prepareHistory(historySnapshot(), HistoryDirection::undo);
  return commitPreparedHistory(prepared);
}
bool EditEngine::redo() {
  if (!canRedo()) return false;
  auto prepared = prepareHistory(historySnapshot(), HistoryDirection::redo);
  return commitPreparedHistory(prepared);
}
void EditEngine::clearHistory() noexcept {
  releaseHistory(undoStack_); releaseHistory(redoStack_);
  currentVersion_ = buffer_;
  stateId_ = nextStateId_++;
}
std::uint64_t EditEngine::stateId() const noexcept { return stateId_; }
}  // namespace sakura::core
