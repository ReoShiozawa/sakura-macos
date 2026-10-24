// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include "sakura/app/DocumentSession.h"

#include <stdexcept>

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

std::optional<core::SearchMatch> DocumentSession::findNext(
    core::SakuraStringView needle, core::TextOffset start,
    core::SearchOptions options) const {
  return core::SearchEngine{}.findNext(buffer_, needle, start, options);
}

std::vector<core::SearchMatch> DocumentSession::findAll(
    core::SakuraStringView needle, core::SearchOptions options) const {
  return core::SearchEngine{}.findAll(buffer_, needle, options);
}

core::SakuraString DocumentSession::replacementText(
    const core::SearchMatch& match, core::SakuraStringView replacement,
    core::SearchOptions options) const {
  return options.regularExpression
             ? core::SearchEngine::expandReplacement(buffer_.text(), match,
                                                     replacement)
             : core::SakuraString(replacement);
}

ReplaceAllResult DocumentSession::replaceAll(core::SakuraStringView needle,
                                             core::SakuraStringView replacement,
                                             core::SearchOptions options) {
  if (!core::SearchEngine::isValidPattern(needle, options)) return {0, false};

  options.maxMatches = 0;
  const auto matches = core::SearchEngine{}.findAll(buffer_, needle, options);
  const core::SakuraString source = buffer_.text();
  std::vector<core::EditReplacement> replacements;
  replacements.reserve(matches.size());
  std::size_t replacementUnits = 0;
  std::size_t removedUnits = 0;
  const auto limit = options.maxReplacementCodeUnits;
  for (auto match = matches.rbegin(); match != matches.rend(); ++match) {
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
      replacementText = core::SearchEngine::expandReplacement(source, *match,
                                                             replacement, remaining);
    } else replacementText = replacement;
    replacementUnits += replacementText.size();
    removedUnits += match->range.length;
    replacements.push_back({match->range, std::move(replacementText)});
  }
  if (options.cancelled && options.cancelled()) {
    throw std::runtime_error("Replacement cancelled");
  }
  if (limit != 0 && source.size() - removedUnits > limit - replacementUnits) {
    throw std::length_error("replacement document limit exceeded");
  }
  editor_.replaceMany(replacements);
  return {matches.size(), true};
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
  savedStateId_ = editor_.stateId();
  metadataRevision_ = 0;
  savedMetadataRevision_ = 0;
  return result;
}

DocumentSaveSnapshot DocumentSession::makeSaveSnapshot(core::BomPolicy policy) const {
  auto encoded = encodingService_.encode(buffer_.text(), encodingState_, policy);
  const auto outputState = encoded.state;
  return {std::move(encoded),
          {editor_.stateId(), documentGeneration_, metadataRevision_, outputState}};
}

void DocumentSession::markSaved(DocumentSaveToken token) noexcept {
  if (token.documentGeneration != documentGeneration_) {
    return;
  }
  savedStateId_ = token.stateId;
  savedMetadataRevision_ = token.metadataRevision;
  encodingState_ = token.encodingState;
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

void DocumentSession::setEncodingState(core::EncodingState state) noexcept {
  if (state == encodingState_) {
    return;
  }
  encodingState_ = state;
  ++metadataRevision_;
}

void DocumentSession::markMetadataChanged() noexcept {
  ++metadataRevision_;
}

}  // namespace sakura::app
