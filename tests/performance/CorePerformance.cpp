// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include <algorithm>
#include <charconv>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include "sakura/app/DocumentSession.h"
#include "sakura/core/layout/LayoutEngine.h"
#ifdef SAKURA_BENCHMARK_WITH_CORETEXT
#include "sakura/platform/mac/CoreTextMetrics.h"
#endif

namespace {

using Clock = std::chrono::steady_clock;

class FixedMetrics final : public sakura::core::ITextMetrics {
 public:
  float advance(sakura::core::SakuraChar,
                const sakura::core::FontStyle&) const override { return 8.0F; }
  float lineHeight(const sakura::core::FontStyle&) const override { return 16.0F; }
};

struct Options {
  std::size_t bytes = 100 * 1024 * 1024;
  std::size_t lines = 1'000'000;
  std::size_t lookups = 100'000;
  std::size_t wrapColumns = 80;
  std::size_t editsPerLocation = 100;
  bool coreText = false;
};

std::size_t parseSize(std::string_view value) {
  std::size_t result{};
  const auto [end, error] = std::from_chars(value.data(), value.data() + value.size(), result);
  if (error != std::errc{} || end != value.data() + value.size()) {
    throw std::invalid_argument("invalid integer: " + std::string(value));
  }
  return result;
}

Options parseOptions(int argc, char** argv) {
  Options options;
  for (int index = 1; index < argc; ++index) {
    const std::string_view argument(argv[index]);
    if (argument == "--core-text") {
#ifdef SAKURA_BENCHMARK_WITH_CORETEXT
      options.coreText = true;
      continue;
#else
      throw std::invalid_argument("Core Text is unavailable in this build");
#endif
    }
    if (index + 1 >= argc) throw std::invalid_argument("missing option value");
    const auto value = parseSize(argv[++index]);
    if (argument == "--bytes") options.bytes = value;
    else if (argument == "--lines") options.lines = value;
    else if (argument == "--lookups") options.lookups = value;
    else if (argument == "--wrap-columns") options.wrapColumns = value;
    else if (argument == "--edits") options.editsPerLocation = value;
    else throw std::invalid_argument("unknown option: " + std::string(argument));
  }
  if (options.lines == 0 || options.bytes < options.lines - 1) {
    throw std::invalid_argument("bytes must fit the requested number of lines");
  }
  return options;
}

std::vector<std::byte> makeSource(const Options& options) {
  // ASCII makes source bytes and UTF-16 units equal. Distribute the exact byte
  // budget over the requested logical lines; the final line has no newline.
  const auto contentBytes = options.bytes - (options.lines - 1);
  const auto perLine = contentBytes / options.lines;
  const auto longerLines = contentBytes % options.lines;
  constexpr std::string_view pattern = "const item_123 = value + 42; // Sakura performance ";
  std::vector<std::byte> bytes(options.bytes);
  std::size_t offset = 0;
  for (std::size_t line = 0; line < options.lines; ++line) {
    const auto count = perLine + (line < longerLines ? 1 : 0);
    for (std::size_t column = 0; column < count; ++column) {
      bytes[offset++] = static_cast<std::byte>(pattern[column % pattern.size()]);
    }
    if (line + 1 < options.lines) bytes[offset++] = std::byte{'\n'};
  }
  return bytes;
}

double elapsedMilliseconds(Clock::time_point start) {
  return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

struct EditMeasurement {
  double editMs{};
  double undoRedoMs{};
  std::uint64_t checksum{};
};

EditMeasurement measureCharacterEdits(sakura::app::DocumentSession& document,
                                     std::size_t iterations,
                                     sakura::core::TextOffset offset) {
  const auto length = document.buffer().length();
  const auto lineCount = document.buffer().lineCount();
  const auto lastLine = lineCount - 1;
  const auto lastStart = document.buffer().lineStartOffset(lastLine);
  const auto position = document.buffer().positionAt(offset);
  const auto lastStartAfterInsert = lastStart + (position.line < lastLine ? 1 : 0);
  const auto originalSuffix = document.buffer().slice(
      {offset, std::min<sakura::core::TextOffset>(1, length - offset)});
  EditMeasurement result;
  const auto editStart = Clock::now();
  for (std::size_t index = 0; index < iterations; ++index) {
    document.insert(offset, u"Z");
    if (document.buffer().length() != length + 1 ||
        document.buffer().lineCount() != lineCount ||
        document.buffer().lineStartOffset(lastLine) != lastStartAfterInsert ||
        document.buffer().positionAt(offset) != position ||
        document.buffer().slice({offset, 1}) != u"Z") {
      throw std::runtime_error("single-character insertion corrupted the line index");
    }
    result.checksum += document.buffer().offsetAt(position) +
                       document.buffer().lineStartOffset(lastLine);
    document.erase({offset, 1});
    if (document.buffer().length() != length ||
        document.buffer().lineCount() != lineCount ||
        document.buffer().lineStartOffset(lastLine) != lastStart ||
        document.buffer().positionAt(offset) != position ||
        document.buffer().slice({offset, originalSuffix.size()}) != originalSuffix) {
      throw std::runtime_error("single-character deletion corrupted the line index");
    }
  }
  result.editMs = elapsedMilliseconds(editStart);
  if (iterations != 0) {
    const auto undoStart = Clock::now();
    if (!document.undo() || document.buffer().slice({offset, 1}) != u"Z" ||
        !document.redo() || document.buffer().length() != length ||
        document.buffer().lineStartOffset(lastLine) != lastStart) {
      throw std::runtime_error("single-character edit undo/redo failed");
    }
    result.undoRedoMs = elapsedMilliseconds(undoStart);
  }
  return result;
}

EditMeasurement measureStructuralEdits(sakura::app::DocumentSession& document,
    std::size_t iterations, sakura::core::TextOffset offset) {
  const auto length = document.buffer().length();
  const auto lines = document.buffer().lineCount();
  EditMeasurement result; const auto start = Clock::now();
  for (std::size_t index=0;index<iterations;++index) {
    document.insert(offset,u"\r\nZ\r\n");
    if (document.buffer().length()!=length+5 || document.buffer().lineCount()!=lines+2 ||
        document.buffer().slice({offset,5})!=u"\r\nZ\r\n")
      throw std::runtime_error("structural insertion corrupted the document");
    document.erase({offset,5});
    if(document.buffer().length()!=length || document.buffer().lineCount()!=lines)
      throw std::runtime_error("structural deletion corrupted the document");
    result.checksum+=document.buffer().lineStartOffset(lines-1);
  }
  result.editMs=elapsedMilliseconds(start);
  if(iterations) {
    const auto undoStart=Clock::now();
    if(!document.undo() || document.buffer().slice({offset,5})!=u"\r\nZ\r\n" || !document.redo() ||
        document.buffer().length()!=length || document.buffer().lineCount()!=lines)
      throw std::runtime_error("structural undo/redo failed");
    result.undoRedoMs=elapsedMilliseconds(undoStart);
  }
  return result;
}

}  // namespace

int main(int argc, char** argv) {
  try {
    const auto options = parseOptions(argc, argv);
    auto source = makeSource(options);
    sakura::app::DocumentSession document;
    const auto loadStart = Clock::now();
    {
      const auto loaded = document.load(source, sakura::core::TextEncoding::utf8);
      if (!loaded.ok()) throw std::runtime_error("UTF-8 load failed");
    }
    const auto loadMs = elapsedMilliseconds(loadStart);
    if (document.buffer().length() != options.bytes ||
        document.buffer().lineCount() != options.lines) {
      throw std::runtime_error("loaded document differs from requested size");
    }
    // Release input memory before layout so peak memory does not include an
    // unnecessary retained copy of the source file.
    source.clear();
    source.shrink_to_fit();
    std::vector<sakura::core::TextBuffer> snapshots;
    snapshots.reserve(10000);
    const auto snapshotStart = Clock::now();
    for (std::size_t index=0;index<10000;++index) snapshots.push_back(document.buffer());
    const auto snapshotMs = elapsedMilliseconds(snapshotStart);
    if (&snapshots.front().line(0)!=&document.buffer().line(0))
      throw std::runtime_error("snapshot copied immutable text payload");

    std::unique_ptr<sakura::core::ITextMetrics> metrics = std::make_unique<FixedMetrics>();
#ifdef SAKURA_BENCHMARK_WITH_CORETEXT
    if (options.coreText) {
      metrics = std::make_unique<sakura::platform::mac::CoreTextMetrics>("Menlo", 12.0F);
    }
#endif
    const sakura::core::FontStyle style{0, 12.0F, 400, false};
    const auto space = metrics->advance(u' ', style);
    const sakura::core::LayoutOptions layoutOptions{
        static_cast<float>(options.wrapColumns) * space, 4};
    const auto layoutStart = Clock::now();
    const auto layout = sakura::core::LayoutEngine{}.layout(
        document.buffer(), *metrics, style, layoutOptions);
    const auto layoutMs = elapsedMilliseconds(layoutStart);
    if (layout.visualLines.size() < options.lines) {
      throw std::runtime_error("layout omitted logical lines");
    }

    std::uint64_t checksum = 0;
    const auto lookupStart = Clock::now();
    for (std::size_t index = 0; index < options.lookups; ++index) {
      const auto line = (index * std::uint64_t{104729}) % options.lines;
      const auto column = document.buffer().line(line).content.size();
      const auto visual = layout.visualLineFor({line, column});
      if (layout.visualLines[visual].logicalLine != line ||
          layout.visualLines[visual].endColumn != column) {
        throw std::runtime_error("layout lookup returned an incorrect line");
      }
      checksum += visual;
    }
    const auto lookupMs = elapsedMilliseconds(lookupStart);
    // Edits go through DocumentSession/EditEngine, including normal history
    // recording. Keep them separate from the existing cold load/layout timing.
    // The first location is in the first logical line; the last is document EOF.
    const auto frontOffset = document.buffer().line(0).content.size() > 1 ? 1 : 0;
    const auto frontEdits = measureCharacterEdits(
        document, options.editsPerLocation, frontOffset);
    const auto tailEdits = measureCharacterEdits(
        document, options.editsPerLocation, document.buffer().length());
    const auto frontStructural = measureStructuralEdits(document, options.editsPerLocation, frontOffset);
    const auto tailStructural = measureStructuralEdits(document, options.editsPerLocation, document.buffer().length());
    const auto statistics = document.buffer().storageStatistics();
    if (!statistics.valid || document.buffer().text()!=snapshots.front().text())
      throw std::runtime_error("edits changed retained snapshot or failed full roundtrip");
    std::cout << std::fixed << std::setprecision(3)
              << "scope=core_load_layout_edit (excludes_AppKit_drawing_and_IME)\n"
#ifdef NDEBUG
              << "build=release\n"
#else
              << "build=debug\n"
#endif
              << "metrics=" << (options.coreText ? "CoreText" : "fixed") << '\n'
              << "source_bytes=" << options.bytes << '\n'
              << "logical_lines=" << document.buffer().lineCount() << '\n'
              << "visual_lines=" << layout.visualLines.size() << '\n'
              << "load_ms=" << loadMs << '\n'
              << "snapshot_copies=10000\n"
              << "snapshot_ms=" << snapshotMs << '\n'
              << "persistent_tree_height=" << statistics.height << '\n'
              << "layout_ms=" << layoutMs << '\n'
              << "lookups=" << options.lookups << '\n'
              << "lookup_ms=" << lookupMs << '\n'
              << "lookup_checksum=" << checksum << '\n'
              << "edit_iterations_per_location=" << options.editsPerLocation << '\n'
              << "edit_operations_per_location=" << options.editsPerLocation * 2 << '\n'
              << "front_insert_erase_ms=" << frontEdits.editMs << '\n'
              << "tail_insert_erase_ms=" << tailEdits.editMs << '\n'
              << "front_undo_redo_ms=" << frontEdits.undoRedoMs << '\n'
              << "tail_undo_redo_ms=" << tailEdits.undoRedoMs << '\n'
              << "front_structural_insert_erase_ms=" << frontStructural.editMs << '\n'
              << "tail_structural_insert_erase_ms=" << tailStructural.editMs << '\n'
              << "front_structural_undo_redo_ms=" << frontStructural.undoRedoMs << '\n'
              << "tail_structural_undo_redo_ms=" << tailStructural.undoRedoMs << '\n'
              << "edit_checksum=" << frontEdits.checksum + tailEdits.checksum << '\n';
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "Core performance benchmark failed: " << error.what() << '\n'
              << "Usage: sakura_core_performance [--bytes N] [--lines N] "
                 "[--lookups N] [--wrap-columns N] [--edits N] [--core-text]\n";
    return 1;
  }
}
