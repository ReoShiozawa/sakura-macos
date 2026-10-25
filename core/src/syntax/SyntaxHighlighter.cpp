// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include "sakura/core/syntax/SyntaxHighlighter.h"
#include "SyntaxScan.h"

#include <array>
#include <algorithm>

namespace sakura::core {
namespace {

bool isIdentifierStart(SakuraChar value) noexcept {
  return (value >= u'a' && value <= u'z') ||
         (value >= u'A' && value <= u'Z') || value == u'_';
}

bool isIdentifierContinue(SakuraChar value) noexcept {
  return isIdentifierStart(value) || (value >= u'0' && value <= u'9');
}

bool isDigit(SakuraChar value) noexcept {
  return value >= u'0' && value <= u'9';
}

bool isKeyword(SakuraStringView identifier) noexcept {
  constexpr std::array<SakuraStringView, 35> kKeywords{
      u"alignas", u"auto", u"bool", u"break", u"case", u"catch", u"char",
      u"class", u"const", u"continue", u"default", u"do", u"double", u"else",
      u"enum", u"explicit", u"false", u"float", u"for", u"if", u"inline",
      u"int", u"namespace", u"new", u"nullptr", u"private", u"protected",
      u"public", u"return", u"static", u"struct", u"switch", u"true", u"void",
      u"while"};
  return std::find(kKeywords.begin(), kKeywords.end(), identifier) !=
         kKeywords.end();
}

void append(std::vector<SyntaxToken>& tokens, std::size_t start,
            std::size_t end, SyntaxTokenKind kind) {
  if (end > start) {
    tokens.push_back({{static_cast<TextOffset>(start),
                       static_cast<TextOffset>(end - start)}, kind});
  }
}

}  // namespace

std::vector<SyntaxToken> SyntaxHighlighter::highlightCLike(
    const TextBuffer& buffer, const std::function<bool()>& cancelled) const {
  detail::SyntaxProbe probe(cancelled);
  const SakuraString source = buffer.text(cancelled);
  const detail::SyntaxText text(source, probe);
  std::vector<SyntaxToken> tokens;
  tokens.reserve(text.size() / 10);

  bool atLineStart = true;
  std::size_t index = 0;
  while (index < text.size()) {
    const SakuraChar current = text[index];
    if (current == u'\r' || current == u'\n') {
      atLineStart = true;
      ++index;
      continue;
    }
    if (current == u' ' || current == u'\t') {
      ++index;
      continue;
    }
    if (atLineStart && current == u'#') {
      const std::size_t start = index++;
      while (index < text.size() && text[index] != u'\r' && text[index] != u'\n') {
        ++index;
      }
      append(tokens, start, index, SyntaxTokenKind::preprocessor);
      continue;
    }
    atLineStart = false;
    if (current == u'/' && index + 1 < text.size() && text[index + 1] == u'/') {
      const std::size_t start = index;
      index += 2;
      while (index < text.size() && text[index] != u'\r' && text[index] != u'\n') {
        ++index;
      }
      append(tokens, start, index, SyntaxTokenKind::comment);
      continue;
    }
    if (current == u'/' && index + 1 < text.size() && text[index + 1] == u'*') {
      const std::size_t start = index;
      index += 2;
      while (index + 1 < text.size() &&
             !(text[index] == u'*' && text[index + 1] == u'/')) {
        ++index;
      }
      index = std::min(text.size(), index + 2);
      append(tokens, start, index, SyntaxTokenKind::comment);
      continue;
    }
    if (current == u'\'' || current == u'\"') {
      const SakuraChar quote = current;
      const std::size_t start = index++;
      while (index < text.size()) {
        if (text[index] == u'\\' && index + 1 < text.size()) {
          index += 2;
          continue;
        }
        if (text[index++] == quote) {
          break;
        }
      }
      append(tokens, start, index, SyntaxTokenKind::string);
      continue;
    }
    if (isDigit(current)) {
      const std::size_t start = index++;
      while (index < text.size() &&
             (isDigit(text[index]) || (text[index] >= u'a' && text[index] <= u'f') ||
              (text[index] >= u'A' && text[index] <= u'F') || text[index] == u'.' ||
              text[index] == u'x' || text[index] == u'X')) {
        ++index;
      }
      append(tokens, start, index, SyntaxTokenKind::number);
      continue;
    }
    if (isIdentifierStart(current)) {
      const std::size_t start = index++;
      while (index < text.size() && isIdentifierContinue(text[index])) {
        ++index;
      }
      if (isKeyword(text.substr(start, index - start))) {
        append(tokens, start, index, SyntaxTokenKind::keyword);
      }
      continue;
    }
    ++index;
  }
  probe.check();
  return tokens;
}

}  // namespace sakura::core
