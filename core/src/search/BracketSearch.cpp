// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#include "sakura/core/search/BracketSearch.h"
#include <algorithm>
#include <array>
#include <bitset>
#include <limits>
#include <stdexcept>

namespace sakura::core {
namespace {
constexpr std::array<BracketPair,18> pairs{{
  {u'(',u')'}, {u'[',u']'}, {u'{',u'}'}, {u'<',u'>'}, {u'｢',u'｣'},
  {u'【',u'】'}, {u'『',u'』'}, {u'「',u'」'}, {u'＜',u'＞'}, {u'≪',u'≫'},
  {u'《',u'》'}, {u'（',u'）'}, {u'〈',u'〉'}, {u'｛',u'｝'}, {u'〔',u'〕'},
  {u'［',u'］'}, {u'“',u'”'}, {u'〝',u'〟'}
}};
constexpr std::size_t windowUnits=8192;

void checkCancellation(const BracketSearchOptions& options) {
  if (options.cancelled && options.cancelled())
    throw std::runtime_error("Bracket search cancelled");
}
bool forbidden(SakuraChar value) noexcept {
  return value==u'\r' || value==u'\n' || (value>=0xD800 && value<=0xDFFF);
}
void validatePairs(std::span<const BracketPair> configured,
                   const BracketSearchOptions& options) {
  if (configured.size()>32768) throw std::invalid_argument("too many bracket pairs");
  std::bitset<65536> used;
  std::size_t index=0;
  for (const auto pair:configured) {
    if ((index++%1024)==0) checkCancellation(options);
    if (pair.opening==pair.closing || forbidden(pair.opening) || forbidden(pair.closing) ||
        used[pair.opening] || used[pair.closing])
      throw std::invalid_argument("bracket pairs must be distinct, unambiguous BMP characters without CR/LF");
    used.set(pair.opening); used.set(pair.closing);
  }
}
struct SourceBracket {
  TextOffset offset;
  BracketPair pair;
  bool forward, previous;
};
std::optional<SourceBracket> at(const TextBuffer& source, TextOffset position,
    std::span<const BracketPair> configured, bool previous) {
  if (position>=source.length()) return std::nullopt;
  const auto value=source.characterAt(position);
  for (const auto pair:configured) {
    if (value==pair.opening) return SourceBracket{position,pair,true,previous};
    if (value==pair.closing) return SourceBracket{position,pair,false,previous};
  }
  return std::nullopt;
}
class WindowReader {
 public:
  WindowReader(const TextBuffer& source, const BracketSearchOptions& options,
               BracketSearchStatistics& statistics)
      : source_(source), options_(options), statistics_(statistics) {}
  SakuraChar read(TextOffset offset) {
    if (offset<begin_ || offset>=end_) {
      checkCancellation(options_);
      begin_=offset/windowUnits*windowUnits;
      const auto count=static_cast<std::size_t>(
          std::min<TextOffset>(windowUnits,source_.length()-begin_));
      end_=begin_+count;
      source_.copyText({begin_,count},{units_.data(),count});
      ++statistics_.chunkLoads;
      statistics_.peakChunkCodeUnits=std::max(statistics_.peakChunkCodeUnits,count);
      const auto room=std::numeric_limits<TextOffset>::max()-statistics_.copiedCodeUnits;
      statistics_.copiedCodeUnits+=std::min<TextOffset>(room,count);
    }
    return units_[static_cast<std::size_t>(offset-begin_)];
  }
 private:
  const TextBuffer& source_;
  const BracketSearchOptions& options_;
  BracketSearchStatistics& statistics_;
  std::array<SakuraChar,windowUnits> units_{};
  TextOffset begin_{},end_{};
};
} // namespace

std::span<const BracketPair> defaultBracketPairs() noexcept { return pairs; }

std::optional<BracketMatch> findBracketPair(const TextBuffer& buffer,
    TextOffset caret, const BracketSearchOptions& options) {
  BracketSearchStatistics local;
  auto& statistics=options.statistics ? *options.statistics : local;
  statistics={};
  if (caret>buffer.length() || !buffer.isEditBoundary(caret))
    throw std::out_of_range("bracket search caret is not a valid edit boundary");
  checkCancellation(options);
  const auto configured=options.pairs.empty() ? defaultBracketPairs()
      : std::span<const BracketPair>(options.pairs);
  if (!options.pairs.empty()) validatePairs(configured,options);
  auto source=at(buffer,caret,configured,false);
  if (!source && options.inspectPrevious && caret>0) {
    const auto line=buffer.positionAt(caret).line;
    if (caret>buffer.lineStartOffset(line)) source=at(buffer,caret-1,configured,true);
  }
  if (!source) return std::nullopt;

  WindowReader reader(buffer,options,statistics);
  TextOffset position=source->offset, level=1;
  for (;;) {
    if (source->forward) {
      if (position+1==buffer.length()) break;
      ++position;
    } else {
      if (!position) break;
      --position;
    }
    if ((statistics.scannedCodeUnits%4096)==0) checkCancellation(options);
    if (options.maxScanCodeUnits && statistics.scannedCodeUnits>=options.maxScanCodeUnits)
      throw std::length_error("Bracket search scan limit exceeded");
    const auto value=reader.read(position);
    ++statistics.scannedCodeUnits;
    if (value==(source->forward?source->pair.opening:source->pair.closing)) ++level;
    else if (value==(source->forward?source->pair.closing:source->pair.opening)) --level;
    if (!level) {
      checkCancellation(options);
      return BracketMatch{{source->offset,1},{position,1},source->previous,
                           source->forward,statistics.scannedCodeUnits};
    }
  }
  checkCancellation(options);
  return std::nullopt;
}
} // namespace sakura::core
