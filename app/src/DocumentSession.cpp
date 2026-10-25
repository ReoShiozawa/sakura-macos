// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include "sakura/app/DocumentSession.h"

#include <algorithm>
#include <stdexcept>
#include <limits>

namespace sakura::app {

DocumentSession::DocumentSession(const core::IEncodingService& encodingService)
    : editor_(buffer_), encodingService_(encodingService) {}

const core::TextBuffer& DocumentSession::buffer() const noexcept {
  return buffer_;
}

void DocumentSession::insert(core::TextOffset offset, core::SakuraStringView text) {
  editor_.insert(offset, text);
}

void DocumentSession::erase(core::TextRange range) {
  editor_.erase(range);
}

void DocumentSession::replace(core::TextRange range, core::SakuraStringView text) {
  editor_.replace(range, text);
}

void DocumentSession::replaceMany(
    const std::vector<core::EditReplacement>& replacements) {
  editor_.replaceMany(replacements);
}

bool DocumentSession::canUndo() const noexcept {
  return editor_.canUndo();
}

bool DocumentSession::canRedo() const noexcept {
  return editor_.canRedo();
}

bool DocumentSession::undo() {
  return editor_.undo();
}

bool DocumentSession::redo() {
  return editor_.redo();
}

core::EditEngine::HistorySnapshot DocumentSession::historySnapshot() const {
  return editor_.historySnapshot();
}
core::EditEngine::PreparedHistory DocumentSession::prepareHistory(
    const core::EditEngine::HistorySnapshot& source,
    core::EditEngine::HistoryDirection direction, const std::function<bool()>& cancelled) {
  return core::EditEngine::prepareHistory(source, direction, cancelled);
}
bool DocumentSession::commitPreparedHistory(core::EditEngine::PreparedHistory& prepared) noexcept {
  return editor_.commitPreparedHistory(prepared);
}

std::optional<core::SearchMatch> DocumentSession::findNext(
    core::SakuraStringView needle, core::TextOffset start,
    core::SearchOptions options) const {
  return core::SearchEngine{}.findNext(buffer_, needle, start, options);
}

std::optional<core::SearchMatch> DocumentSession::findPrevious(
    core::SakuraStringView needle, core::TextOffset cursor, core::SearchOptions options) const {
  return core::SearchEngine{}.findPrevious(buffer_, needle, cursor, options);
}

std::vector<core::SearchMatch> DocumentSession::findAll(
    core::SakuraStringView needle, core::SearchOptions options) const {
  return core::SearchEngine{}.findAll(buffer_, needle, options);
}

core::SakuraString DocumentSession::replacementText(
    const core::SearchMatch& match, core::SakuraStringView replacement,
    core::SearchOptions options) const {
  if (!options.regularExpression && options.maxReplacementCodeUnits && replacement.size() > options.maxReplacementCodeUnits)
    throw std::length_error("replacement output limit exceeded");
  std::optional<std::size_t> limit;
  if (options.maxReplacementCodeUnits) limit = options.maxReplacementCodeUnits;
  return options.regularExpression
             ? core::SearchEngine::expandReplacement(buffer_, match,
                                                     replacement, limit, options.cancelled)
             : core::SakuraString(replacement);
}

ReplaceAllResult DocumentSession::replaceAll(core::SakuraStringView needle,
                                             core::SakuraStringView replacement,
                                             core::SearchOptions options) {
  auto prepared = prepareReplaceAll(editSnapshot(), needle, replacement, options);
  if (!prepared.result.valid) return prepared.result;
  if (options.cancelled && options.cancelled()) throw std::runtime_error("replacement cancelled before commit");
  if (!commitPreparedReplacement(prepared)) throw std::runtime_error("replacement source changed before commit");
  return prepared.result;
}
core::EditEngine::Snapshot DocumentSession::editSnapshot() const { return editor_.snapshot(); }
bool DocumentSession::commitPreparedReplacement(PreparedReplaceAll& prepared) noexcept {
  return prepared.result.valid && editor_.commitPrepared(prepared.edit);
}
PreparedReplaceAll DocumentSession::prepareReplaceAll(const core::EditEngine::Snapshot& snapshot,
    core::SakuraStringView needle, core::SakuraStringView replacement, core::SearchOptions options) {
  if (!core::SearchEngine::isValidPattern(needle, options)) return {{0, false, {}, false}, {}};
  const auto& buffer = snapshot.buffer();
  options.maxMatches = options.maxReplacementMatches == std::numeric_limits<std::size_t>::max()
      ? 0 : options.maxReplacementMatches + 1;
  options.captureGroups = options.regularExpression && replacement.find(u'$') != core::SakuraStringView::npos;
  const auto matches = core::SearchEngine{}.findAll(buffer, needle, options);
  if (matches.size() > options.maxReplacementMatches) throw std::length_error("replacement match limit exceeded");
  std::vector<core::EditReplacement> replacements;
  replacements.reserve(matches.size());
  std::size_t replacementUnits = 0;
  std::size_t removedUnits = 0;
  const auto limit = options.maxReplacementCodeUnits;
  for (const auto& match : matches) {
    if (options.cancelled && options.cancelled()) {
      throw std::runtime_error("Replacement cancelled");
    }
    std::optional<std::size_t> remaining;
    if (limit != 0) remaining = limit - replacementUnits;
    if (!options.regularExpression && remaining && replacement.size() > *remaining) {
      throw std::length_error("replacement output limit exceeded");
    }
    core::SakuraString replacementText;
    if (options.regularExpression) {
      replacementText = core::SearchEngine::expandReplacement(buffer, match,
                                                             replacement, remaining, options.cancelled);
    } else replacementText = replacement;
    if (replacementText.size() > std::numeric_limits<std::size_t>::max() - replacementUnits ||
        match.range.length > std::numeric_limits<std::size_t>::max() - removedUnits)
      throw std::length_error("replacement text length overflow");
    replacementUnits += replacementText.size();
    removedUnits += match.range.length;
    replacements.push_back({match.range, std::move(replacementText)});
  }
  if (options.cancelled && options.cancelled()) {
    throw std::runtime_error("Replacement cancelled");
  }
  if (limit != 0 && buffer.length() - removedUnits > limit - replacementUnits) {
    throw std::length_error("replacement document limit exceeded");
  }
  auto prepared = core::EditEngine::prepareOriginalRanges(snapshot, replacements, options.cancelled);
  std::optional<core::TextRange> resultingRange;
  if (options.range) resultingRange = core::TextRange{options.range->location,
      options.range->length - removedUnits + replacementUnits};
  const bool changed = prepared.hasChanges();
  return {{matches.size(), true, resultingRange, changed}, std::move(prepared)};
}

PreparedSearchReplacement DocumentSession::prepareSingleReplacement(const core::EditEngine::Snapshot& snapshot,
    core::TextRange selection, core::SakuraStringView needle, core::SakuraStringView replacement, core::SearchOptions options) {
  const auto check = [&] {
    if (options.cancelled && options.cancelled()) throw std::runtime_error("single replacement cancelled");
  };
  check();
  const auto& buffer = snapshot.buffer();
  if (selection.location > buffer.length() || selection.length > buffer.length()-selection.location ||
      !buffer.isEditBoundary(selection.location) || !buffer.isEditBoundary(selection.location+selection.length))
    throw std::invalid_argument("single replacement selection is not an edit range");
  if (!core::SearchEngine::isValidPattern(needle,options)) return {{0,false,{},false},{}};
  options.captureGroups = options.regularExpression && replacement.find(u'$') != core::SakuraStringView::npos;
  const auto match = core::SearchEngine{}.findNext(buffer,needle,selection.location,options);
  if (!match || match->range.location != selection.location || match->range.length != selection.length) {
    // Commit this no-op plan before using fallbackSelection. A live edit/undo,
    // reload or foreign owner must invalidate navigation as well as writes.
    auto edit = core::EditEngine::prepareOriginalRanges(snapshot,{},options.cancelled);
    return {{0,true,options.range,false},std::move(edit),match ? std::optional{match->range} : std::nullopt};
  }
  if (options.maxReplacementMatches == 0) throw std::length_error("replacement match limit exceeded");
  std::optional<std::size_t> limit;
  if (options.maxReplacementCodeUnits) limit = options.maxReplacementCodeUnits;
  core::SakuraString expanded;
  if (options.regularExpression) {
    expanded = core::SearchEngine::expandReplacement(buffer,*match,replacement,limit,options.cancelled);
  } else {
    if (limit && replacement.size() > *limit) throw std::length_error("replacement output limit exceeded");
    expanded.reserve(replacement.size());
    for (std::size_t offset=0;offset<replacement.size();offset+=65536) {
      check(); expanded.append(replacement.substr(offset,std::min<std::size_t>(65536,replacement.size()-offset)));
    }
  }
  const auto outputLength = expanded.size();
  std::vector<core::EditReplacement> replacements;
  replacements.push_back({match->range,std::move(expanded)});
  auto edit = core::EditEngine::prepareOriginalRanges(snapshot,replacements,options.cancelled);
  const auto& candidate = edit.resultingBuffer();
  const auto rawEnd = selection.location+outputLength;
  const auto boundaryAtOrAfter = [&](core::TextOffset at) {
    while (at<candidate.length() && !candidate.isEditBoundary(at)) ++at;
    return at;
  };
  const auto caret = boundaryAtOrAfter(rawEnd);
  std::optional<core::TextRange> resultingRange;
  if (options.range) resultingRange = core::TextRange{options.range->location,options.range->length-selection.length+outputLength};
  const auto lower = resultingRange ? resultingRange->location : 0;
  const auto upper = resultingRange ? lower+resultingRange->length : candidate.length();
  const bool scopeValid = candidate.isEditBoundary(lower) && candidate.isEditBoundary(upper);
  std::optional<core::TextOffset> next;
  if (scopeValid) {
    if (selection.length) next = caret;
    else if (rawEnd < upper) next = boundaryAtOrAfter(rawEnd+1);
    else if (options.wrap) next = lower;
  }
  const bool changed = edit.hasChanges();
  check();
  return {{1,true,resultingRange,changed},std::move(edit),{},core::TextRange{caret,0},next};
}

core::TextDecodeResult DocumentSession::load(
    std::span<const std::byte> data, core::TextEncoding requestedEncoding) {
  auto result = encodingService_.decode(data, requestedEncoding);
  if (!result.ok()) {
    return result;
  }

  buffer_.assign(result.text);
  editor_.clearHistory();
  ++documentGeneration_;
  encodingState_ = result.state;
  sourceEncodingDetection_ = result.detection;
  savedStateId_ = editor_.stateId();
  metadataRevision_ = 0;
  savedMetadataRevision_ = 0;
  encodingRevision_ = 0;
  return result;
}

DocumentSaveSnapshot DocumentSession::makeSaveSnapshot(core::BomPolicy policy) const {
  auto encoded = encodingService_.encode(buffer_.text(), encodingState_, policy);
  const auto outputState = encoded.state;
  return {std::move(encoded),
          {editor_.stateId(), documentGeneration_, metadataRevision_, outputState,
           encodingRevision_}};
}

void DocumentSession::markSaved(DocumentSaveToken token) noexcept {
  if (token.documentGeneration != documentGeneration_) {
    return;
  }
  savedStateId_ = token.stateId;
  savedMetadataRevision_ = token.metadataRevision;
  if (token.encodingRevision == encodingRevision_) {
    encodingState_ = token.encodingState;
  }
}

bool DocumentSession::isDirty() const noexcept {
  return savedStateId_ != editor_.stateId() ||
         savedMetadataRevision_ != metadataRevision_;
}

bool DocumentSession::sourceHadBom() const noexcept {
  return encodingState_.hadBom;
}

core::EncodingState DocumentSession::encodingState() const noexcept {
  return encodingState_;
}

core::EncodingDetection DocumentSession::sourceEncodingDetection() const noexcept {
  return sourceEncodingDetection_;
}

void DocumentSession::restoreSourceEncodingAmbiguity() noexcept {
  sourceEncodingDetection_ = {core::EncodingDetectionMethod::fallback, true};
}

void DocumentSession::setEncodingState(core::EncodingState state) noexcept {
  if (state == encodingState_) {
    return;
  }
  encodingState_ = state;
  ++metadataRevision_;
  ++encodingRevision_;
}

void DocumentSession::markMetadataChanged() noexcept {
  ++metadataRevision_;
}

}  // namespace sakura::app
