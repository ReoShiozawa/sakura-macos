// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#ifndef SAKURA_APP_DOCUMENT_SESSION_H_
#define SAKURA_APP_DOCUMENT_SESSION_H_

#include <span>

#include "sakura/core/edit/EditEngine.h"
#include "sakura/core/encoding/EncodingService.h"
#include "sakura/core/search/SearchEngine.h"

namespace sakura::app {

struct DocumentSaveToken {
  std::uint64_t stateId{};
  std::uint64_t documentGeneration{};
  std::uint64_t metadataRevision{};
  core::EncodingState encodingState;
  std::uint64_t encodingRevision{};
};

struct DocumentSaveSnapshot {
  core::TextEncodeResult encoded;
  DocumentSaveToken token;
};

struct ReplaceAllResult {
  std::size_t replacements{};
  bool valid{true};
  std::optional<core::TextRange> resultingRange;
  bool changed{};
};

struct PreparedSearchReplacement {
  ReplaceAllResult result;
  core::EditEngine::PreparedEdit edit;
  // Single replacement only. A nonmatching selection navigates to fallback
  // without editing. Even that plan has a no-op edit for source authentication.
  std::optional<core::TextRange> fallbackSelection{};
  std::optional<core::TextRange> selectionAfter{};
  std::optional<core::TextOffset> nextSearchStart{};
};
using PreparedReplaceAll = PreparedSearchReplacement;

class DocumentSession {
 public:
  explicit DocumentSession(
      const core::IEncodingService& encodingService = core::defaultEncodingService());
  DocumentSession(const DocumentSession&) = delete;
  DocumentSession& operator=(const DocumentSession&) = delete;
  DocumentSession(DocumentSession&&) = delete;
  DocumentSession& operator=(DocumentSession&&) = delete;

  [[nodiscard]] const core::TextBuffer& buffer() const noexcept;

  void insert(core::TextOffset offset, core::SakuraStringView text);
  void erase(core::TextRange range);
  void replace(core::TextRange range, core::SakuraStringView text);
  void replaceMany(const std::vector<core::EditReplacement>& replacements);
  [[nodiscard]] bool canUndo() const noexcept;
  [[nodiscard]] bool canRedo() const noexcept;
  bool undo();
  bool redo();
  [[nodiscard]] core::EditEngine::HistorySnapshot historySnapshot() const;
  [[nodiscard]] static core::EditEngine::PreparedHistory prepareHistory(
      const core::EditEngine::HistorySnapshot& source,
      core::EditEngine::HistoryDirection direction,
      const std::function<bool()>& cancelled = {});
  [[nodiscard]] bool commitPreparedHistory(core::EditEngine::PreparedHistory& prepared) noexcept;

  [[nodiscard]] std::optional<core::SearchMatch> findNext(
      core::SakuraStringView needle, core::TextOffset start,
      core::SearchOptions options = {}) const;
  [[nodiscard]] std::optional<core::SearchMatch> findPrevious(
      core::SakuraStringView needle, core::TextOffset cursor,
      core::SearchOptions options = {}) const;
  [[nodiscard]] std::vector<core::SearchMatch> findAll(
      core::SakuraStringView needle, core::SearchOptions options = {}) const;
  [[nodiscard]] core::SakuraString replacementText(
      const core::SearchMatch& match, core::SakuraStringView replacement,
      core::SearchOptions options = {}) const;
  [[nodiscard]] ReplaceAllResult replaceAll(
      core::SakuraStringView needle, core::SakuraStringView replacement,
      core::SearchOptions options = {});
  [[nodiscard]] core::EditEngine::Snapshot editSnapshot() const;
  [[nodiscard]] static PreparedReplaceAll prepareReplaceAll(
      const core::EditEngine::Snapshot& snapshot, core::SakuraStringView needle,
      core::SakuraStringView replacement, core::SearchOptions options = {});
  [[nodiscard]] static PreparedSearchReplacement prepareSingleReplacement(
      const core::EditEngine::Snapshot& snapshot, core::TextRange selection,
      core::SakuraStringView needle, core::SakuraStringView replacement,
      core::SearchOptions options = {});
  [[nodiscard]] bool commitPreparedReplacement(PreparedReplaceAll& prepared) noexcept;

  [[nodiscard]] core::TextDecodeResult load(
      std::span<const std::byte> data,
      core::TextEncoding requestedEncoding = core::TextEncoding::automatic);
  [[nodiscard]] DocumentSaveSnapshot makeSaveSnapshot(
      core::BomPolicy policy = core::BomPolicy::preserve) const;

  // Marks exactly the state represented by a successfully written snapshot.
  // Edits made after snapshot creation therefore remain dirty. A successful
  // save may update its BOM policy, but never a newer explicit encoding choice.
  void markSaved(DocumentSaveToken token) noexcept;
  [[nodiscard]] bool isDirty() const noexcept;
  [[nodiscard]] bool sourceHadBom() const noexcept;
  [[nodiscard]] core::EncodingState encodingState() const noexcept;
  [[nodiscard]] core::EncodingDetection sourceEncodingDetection() const noexcept;
  // Recovery stores Unicode text but must not silently confirm a previous guess.
  // This can raise an uncertainty warning; only a new successful load clears it.
  void restoreSourceEncodingAmbiguity() noexcept;
  void setEncodingState(core::EncodingState state) noexcept;
  void markMetadataChanged() noexcept;

 private:
  core::TextBuffer buffer_;
  core::EditEngine editor_;
  const core::IEncodingService& encodingService_;
  core::EncodingState encodingState_;
  core::EncodingDetection sourceEncodingDetection_;
  std::uint64_t savedStateId_{};
  std::uint64_t documentGeneration_{};
  std::uint64_t metadataRevision_{};
  std::uint64_t savedMetadataRevision_{};
  std::uint64_t encodingRevision_{};
};

}  // namespace sakura::app

#endif  // SAKURA_APP_DOCUMENT_SESSION_H_
