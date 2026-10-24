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
};

struct DocumentSaveSnapshot {
  core::TextEncodeResult encoded;
  DocumentSaveToken token;
};

struct ReplaceAllResult {
  std::size_t replacements{};
  bool valid{true};
};

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

  [[nodiscard]] std::optional<core::SearchMatch> findNext(
      core::SakuraStringView needle, core::TextOffset start,
      core::SearchOptions options = {}) const;
  [[nodiscard]] std::vector<core::SearchMatch> findAll(
      core::SakuraStringView needle, core::SearchOptions options = {}) const;
  [[nodiscard]] core::SakuraString replacementText(
      const core::SearchMatch& match, core::SakuraStringView replacement,
      core::SearchOptions options = {}) const;
  [[nodiscard]] ReplaceAllResult replaceAll(
      core::SakuraStringView needle, core::SakuraStringView replacement,
      core::SearchOptions options = {});

  [[nodiscard]] core::TextDecodeResult load(
      std::span<const std::byte> data,
      core::TextEncoding requestedEncoding = core::TextEncoding::automatic);
  [[nodiscard]] DocumentSaveSnapshot makeSaveSnapshot(
      core::BomPolicy policy = core::BomPolicy::preserve) const;

  // Marks exactly the state represented by a successfully written snapshot.
  // Edits made after snapshot creation therefore remain dirty.
  void markSaved(DocumentSaveToken token) noexcept;
  [[nodiscard]] bool isDirty() const noexcept;
  [[nodiscard]] bool sourceHadBom() const noexcept;
  [[nodiscard]] core::EncodingState encodingState() const noexcept;
  void setEncodingState(core::EncodingState state) noexcept;
  void markMetadataChanged() noexcept;

 private:
  core::TextBuffer buffer_;
  core::EditEngine editor_;
  const core::IEncodingService& encodingService_;
  core::EncodingState encodingState_;
  std::uint64_t savedStateId_{};
  std::uint64_t documentGeneration_{};
  std::uint64_t metadataRevision_{};
  std::uint64_t savedMetadataRevision_{};
};

}  // namespace sakura::app

#endif  // SAKURA_APP_DOCUMENT_SESSION_H_
