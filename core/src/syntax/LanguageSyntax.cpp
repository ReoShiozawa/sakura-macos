// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#include "sakura/core/syntax/SyntaxHighlighter.h"
#include "LanguageSyntaxInternal.h"
#include <algorithm>
#include <string>

namespace sakura::core {
namespace {
using L = SyntaxLanguage;
using K = SyntaxTokenKind;
using detail::SyntaxProbe;
using detail::SyntaxText;
bool digit(char16_t c) { return c >= u'0' && c <= u'9'; }
bool letter(char16_t c) { return (c >= u'a' && c <= u'z') || (c >= u'A' && c <= u'Z') || c == u'_' || c >= 0x80; }
bool ident(char16_t c) { return letter(c) || digit(c) || c == u'$'; }
bool eol(char16_t c) { return c == u'\r' || c == u'\n'; }
bool space(char16_t c) { return c == u' ' || c == u'\t'; }
bool starts(SyntaxText text, std::size_t at, SakuraStringView prefix) {
  return text.startsWith(at, prefix);
}
std::size_t lineEnd(SyntaxText text, std::size_t at) {
  while (at < text.size() && !eol(text[at])) ++at;
  return at;
}
std::size_t closed(SyntaxText text, std::size_t at, SakuraStringView delimiter) {
  auto end = text.find(delimiter, at);
  return end == text.npos ? text.size() : end + delimiter.size();
}
void add(std::vector<SyntaxToken>& out, std::size_t begin, std::size_t end, K kind) {
  if (end > begin) out.push_back({{begin, end - begin}, kind});
}
SakuraStringView words(L language) {
  switch (language) {
    case L::python: return u"False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case";
    case L::javascript: case L::typescript: return u"abstract any as async await boolean break case catch class const constructor continue debugger declare default delete do else enum export extends false finally for from function get if implements import in instanceof interface keyof let module namespace never new null number of override private protected public readonly return set static string super switch symbol this throw true try type typeof undefined unknown var void while with yield";
    case L::swift: return u"actor any as associatedtype async await break case catch class continue convenience default defer deinit didSet do dynamic else enum extension fallthrough false fileprivate final for func get guard if import in indirect init inout internal is lazy let mutating nil nonisolated open operator optional override private protocol public repeat required rethrows return self Self set some static struct subscript super switch throw throws true try typealias unowned var weak where while willSet";
    case L::java: return u"abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for if implements import instanceof int interface long native new null package private protected public record return sealed short static strictfp super switch synchronized this throw throws transient true false try var void volatile while yield";
    case L::csharp: return u"abstract as async await base bool break byte case catch char checked class const continue decimal default delegate do double else enum event explicit extern false finally fixed float for foreach get if implicit in int interface internal is lock long namespace new null object operator out override params partial private protected public readonly record ref required return sbyte sealed set short sizeof stackalloc static string struct switch this throw true try typeof uint ulong unchecked unsafe ushort using value var virtual void volatile while yield";
    case L::go: return u"break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var true false nil";
    case L::rust: return u"Self as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self static struct super trait true type unsafe use where while";
    case L::shell: return u"if then else elif fi case esac for select while until do done in function time coproc export local readonly declare return break continue";
    case L::ruby: return u"BEGIN END alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield";
    case L::sql: return u"ADD ALL ALTER AND ANY AS ASC BEGIN BETWEEN BY CALL CASE CHECK COLUMN COMMIT CONSTRAINT CREATE CROSS DATABASE DEFAULT DELETE DESC DISTINCT DROP ELSE END EXCEPT EXISTS FALSE FOREIGN FROM FULL GROUP HAVING IF IN INDEX INNER INSERT INTERSECT INTO IS JOIN KEY LEFT LIKE LIMIT NOT NULL OFFSET ON OR ORDER OUTER PRIMARY PROCEDURE REFERENCES RETURN RIGHT ROLLBACK SELECT SET TABLE THEN TOP TRANSACTION TRUE TRUNCATE UNION UNIQUE UPDATE USE USING VALUES VIEW WHEN WHERE WITH";
    case L::json: return u"true false null";
    case L::yaml: return u"true false null True False Null TRUE FALSE NULL yes no on off";
    case L::toml: return u"true false inf nan";
    case L::css: return u"important inherit initial unset revert auto none block flex grid solid relative absolute fixed sticky";
    default: return u"alignas alignof asm auto bool break case catch char char8_t char16_t char32_t class concept const consteval constexpr constinit const_cast continue co_await co_return co_yield decltype default delete do double dynamic_cast else enum explicit export extern false float for friend goto if inline int long mutable namespace new noexcept nullptr operator override private protected public register reinterpret_cast requires return short signed sizeof static static_assert static_cast struct switch template this thread_local throw true try typedef typeid typename union unsigned using virtual void volatile wchar_t while final interface implementation end property synthesize dynamic protocol selector import id nil YES NO self super";
  }
}
bool keyword(SakuraStringView word, L language, SyntaxProbe& probe) {
  if (language == L::ini) return false;
  auto list = words(language); SakuraString folded;
  if (language == L::sql) {
    probe.append(folded, word);
    for (auto& c : folded) { probe.tick(); if (c >= u'a' && c <= u'z') c -= 32; }
    word = folded;
  }
  for (std::size_t start = 0; start < list.size();) {
    auto end = list.find(u' ', start); if (end == list.npos) end = list.size();
    if (word == list.substr(start, end - start)) return true;
    start = end + 1;
  }
  return false;
}
std::vector<SyntaxToken> lex(SakuraStringView source, L language, SyntaxProbe& probe, detail::SyntaxScanOptions options = {});
std::vector<SyntaxToken> markup(SakuraStringView source, L language, SyntaxProbe& probe, detail::SyntaxScanOptions options) {
  SyntaxText text(source, probe, options.total, options.origin);
  std::vector<SyntaxToken> out; bool tag = options.initial.tag, name = options.initial.name, closingTag = options.initial.closingTag;
  L raw = options.initial.raw;
  for (std::size_t i = 0; i < text.size();) {
    if (options.driver) options.driver->at(i, {true, tag, name, closingTag, raw}, text, probe, out);
    auto start = i;
    if (starts(text, i, u"<!--")) { i = closed(text, i + 4, u"-->"); add(out, start, i, K::comment); }
    else if (starts(text, i, u"<![CDATA[")) { i = closed(text, i + 9, u"]]>"); add(out, start, i, K::string); }
    else if (text[i] == u'<') { tag = true; name = true; raw = L::plain; ++i; closingTag = i < text.size() && text[i] == u'/'; if (closingTag) ++i; }
    else if (tag && text[i] == u'>') {
      tag = false; ++i;
      if (raw != L::plain) {
        auto begin = i; SakuraStringView ending = raw == L::javascript ? u"</script" : u"</style";
        auto stop = text.size();
        for (auto at = text.find(u'<', begin); at != text.npos; at = text.find(u'<', at + 1)) {
          bool matches = at + ending.size() <= text.size();
          for (std::size_t n = 0; matches && n < ending.size(); ++n) {
            auto c = text[at + n]; if (c >= u'A' && c <= u'Z') c += 32;
            matches = c == ending[n];
          }
          auto end = at + ending.size();
          if (matches && (end == text.size() || space(text[end]) || eol(text[end]) || text[end] == u'>')) { stop = at; break; }
        }
        detail::SyntaxScanOptions nested; nested.origin = options.origin + begin;
        for (auto token : lex(text.substr(begin, stop - begin), raw, probe, nested)) {
          probe.tick();
          token.range.location += begin; out.push_back(token);
        }
        i = stop; raw = L::plain;
      }
    }
    else if (tag && (text[i] == u'\'' || text[i] == u'"')) {
      auto quote = text[i++]; while (i < text.size() && text[i] != quote) ++i;
      if (i < text.size()) ++i; add(out, start, i, K::string);
    } else if (tag && letter(text[i])) {
      ++i; while (i < text.size() && (ident(text[i]) || text[i] == u':' || text[i] == u'-')) ++i;
      add(out, start, i, name ? K::keyword : K::preprocessor);
      if (name && !closingTag && language == L::html) {
        SakuraString tagName; probe.append(tagName, text.substr(start, i - start));
        for (auto& c : tagName) { probe.tick(); if (c >= u'A' && c <= u'Z') c += 32; }
        if (tagName == u"script") raw = L::javascript;
        if (tagName == u"style") raw = L::css;
      }
      name = false;
    } else if (!tag && text[i] == u'&') {
      auto local = text.substr(i + 1, std::min<std::size_t>(16,text.size()-i-1)).find(u';');
      auto stop = local == text.npos ? text.npos : i+1+local;
      if (stop != text.npos && stop - i <= 16) { i = stop + 1; add(out, start, i, K::number); }
      else ++i;
    } else ++i;
  }
  if (options.driver) options.driver->finalState = {true, tag, name, closingTag, raw};
  return out;
}
std::vector<SyntaxToken> markdown(SakuraStringView source, SyntaxProbe& probe, detail::SyntaxScanOptions options) {
  SyntaxText text(source, probe, options.total, options.origin);
  std::vector<SyntaxToken> out;
  for (std::size_t i = 0; i < text.size();) {
    if (options.driver) options.driver->at(i, {}, text, probe, out);
    auto start = i; bool beginning = i == 0 || eol(text[i - 1]);
    auto visible = i; if (beginning) while (visible < text.size() && visible - i < 3 && text[visible] == u' ') ++visible;
    if (visible == text.size()) break;
    if (beginning && (starts(text, visible, u"```") || starts(text, visible, u"~~~"))) {
      auto marker = text[visible]; auto count = std::size_t{0};
      while (visible + count < text.size() && text[visible + count] == marker) ++count;
      auto line = lineEnd(text, visible + count); i = text.size();
      while (line < text.size()) {
        while (line < text.size() && eol(text[line])) ++line;
        auto first = line; while (first < text.size() && first - line < 3 && text[first] == u' ') ++first;
        auto end = first; while (end < text.size() && text[end] == marker) ++end;
        auto tail = end; while (tail < text.size() && space(text[tail])) ++tail;
        if (end - first >= count && (tail == text.size() || eol(text[tail]))) { i = tail; break; }
        line = lineEnd(text, line);
      }
      add(out, start, i, K::string);
    } else if (beginning && text[visible] == u'#') {
      auto end = visible; while (end < text.size() && text[end] == u'#') ++end;
      if (end - visible <= 6 && (end == text.size() || space(text[end]))) {
        i = lineEnd(text, end); add(out, start, i, K::keyword);
      } else ++i;
    } else if (starts(text, i, u"<!--")) { i = closed(text, i + 4, u"-->"); add(out, start, i, K::comment); }
    else if (text[i] == u'\\' && i + 1 < text.size()) i += 2;
    else if (text[i] == u'[') {
      auto label = text.find(u']', i + 1);
      if (label != text.npos && label + 1 < text.size() && text[label + 1] == u'(') {
        auto end = text.find(u')', label + 2);
        if (end != text.npos && end <= lineEnd(text, i)) {
          add(out, i, label + 1, K::keyword); add(out, label + 1, end + 1, K::string); i = end + 1;
        } else ++i;
      } else ++i;
    } else if ((text[i] == u'*' || text[i] == u'_') && i + 1 < text.size() && !space(text[i + 1]) && !eol(text[i + 1])) {
      auto count = i + 1 < text.size() && text[i + 1] == text[i] ? 2U : 1U;
      auto delimiter = text.substr(i, count); auto end = text.find(delimiter, i + count);
      if (end != text.npos && end <= lineEnd(text, i)) { i = end + count; add(out, start, i, K::keyword); }
      else i += count;
    }
    else if (text[i] == u'`') {
      while (i < text.size() && text[i] == u'`') ++i;
      auto delimiter = text.substr(start, i - start);
      auto end = text.find(delimiter, i);
      if (end != text.npos) { i = end + delimiter.size(); add(out, start, i, K::string); }
    } else ++i;
  }
  if (options.driver) options.driver->finalState = {};
  return out;
}
std::vector<SyntaxToken> lex(SakuraStringView source, L language, SyntaxProbe& probe, detail::SyntaxScanOptions options) {
  if (language == L::plain) return {};
  if (language == L::html || language == L::xml) return markup(source, language, probe, options);
  if (language == L::markdown) return markdown(source, probe, options);
  SyntaxText text(source, probe, options.total, options.origin);
  std::vector<SyntaxToken> out;
  const bool hash = language == L::python || language == L::shell || language == L::ruby || language == L::yaml || language == L::toml || language == L::ini;
  const bool slash = !hash && language != L::sql && language != L::json;
  const bool nested = language == L::swift || language == L::rust || language == L::sql;
  bool lineStart = options.initial.lineStart;
  for (std::size_t i = 0; i < text.size();) {
    if (options.driver) options.driver->at(i, {lineStart}, text, probe, out);
    auto start = i; auto c = text[i];
    if (eol(c)) { lineStart = true; ++i; continue; }
    if (space(c)) { ++i; continue; }
    bool atStart = lineStart; lineStart = false;
    if (atStart && (language == L::c || language == L::cpp || language == L::objectiveC || language == L::csharp) && c == u'#') {
      i = lineEnd(text, i);
      while (i && text[i - 1] == u'\\' && i < text.size()) {
        if (text[i] == u'\r') ++i;
        if (i < text.size() && text[i] == u'\n') ++i;
        i = lineEnd(text, i);
      }
      add(out, start, i, K::preprocessor); continue;
    }
    if ((hash && c == u'#' && ((language != L::shell && language != L::yaml) || atStart || (i && space(text[i - 1])))) ||
        (language == L::ini && c == u';') || (language == L::sql && starts(text, i, u"--")) ||
        (slash && language != L::css && starts(text, i, u"//"))) {
      i = lineEnd(text, i); add(out, start, i, K::comment); continue;
    }
    if ((slash || language == L::sql) && starts(text, i, u"/*")) {
      i += 2; std::size_t depth = 1;
      while (i < text.size() && depth) {
        if (nested && starts(text, i, u"/*")) { ++depth; i += 2; }
        else if (starts(text, i, u"*/")) { --depth; i += 2; }
        else ++i;
      }
      add(out, start, i, K::comment); continue;
    }
    if (language == L::shell && starts(text, i, u"<<") && !starts(text, i, u"<<<")) {
      auto cursor = i + 2; bool stripTabs = cursor < text.size() && text[cursor] == u'-';
      if (stripTabs) ++cursor;
      while (cursor < text.size() && space(text[cursor])) ++cursor;
      char16_t quote = cursor < text.size() && (text[cursor] == u'\'' || text[cursor] == u'"') ? text[cursor++] : 0;
      auto begin = cursor;
      while (cursor < text.size() && (quote ? text[cursor] != quote && !eol(text[cursor]) : ident(text[cursor]))) ++cursor;
      auto delimiter = text.substr(begin, cursor - begin);
      if (!delimiter.empty() && (!quote || (cursor < text.size() && text[cursor] == quote))) {
        auto line = lineEnd(text, cursor); i = text.size();
        while (line < text.size()) {
          if (text[line] == u'\r') ++line;
          if (line < text.size() && text[line] == u'\n') ++line;
          auto end = lineEnd(text, line); auto content = line;
          if (stripTabs) while (content < end && text[content] == u'\t') ++content;
          if (probe.equal(text.substr(content, end - content), delimiter)) { i = end; break; }
          line = end;
        }
        add(out, start, i, K::string); continue;
      }
    }
    auto before = i;
    if (language == L::yaml && (c == u'|' || c == u'>'))
      while (before && space(text[before - 1])) --before;
    if (language == L::yaml && (c == u'|' || c == u'>') &&
        (!before || eol(text[before - 1]) || text[before - 1] == u':' || text[before - 1] == u'-')) {
      auto line = text.find_last_of(u"\r\n", i); line = line == text.npos ? 0 : line + 1;
      auto indentEnd = line; while (indentEnd < text.size() && space(text[indentEnd])) ++indentEnd;
      auto indent = indentEnd - line;
      auto end = lineEnd(text, i); i = end;
      while (end < text.size()) {
        if (text[end] == u'\r') ++end;
        if (end < text.size() && text[end] == u'\n') ++end;
        auto first = end; while (first < text.size() && space(text[first])) ++first;
        if (first < text.size() && !eol(text[first]) && first - end <= indent) break;
        i = lineEnd(text, first); end = i;
      }
      add(out, start, i, K::string); continue;
    }
    if ((language == L::cpp || language == L::c) && starts(text, i, u"R\"")) {
      auto local = text.substr(i + 2, std::min<std::size_t>(17,text.size()-i-2)).find(u'(');
      auto paren = local == text.npos ? text.npos : i+2+local;
      if (paren != text.npos && paren - i - 2 <= 16) {
        SakuraString ending = u")"; ending += text.substr(i + 2, paren - i - 2); ending += u'"';
        i = closed(text, paren + 1, ending); add(out, start, i, K::string); continue;
      }
    }
    if (language == L::rust && (c == u'r' || starts(text, i, u"br"))) {
      auto quote = i + (c == u'b' ? 2 : 1);
      while (quote < text.size() && text[quote] == u'#') ++quote;
      if (quote < text.size() && text[quote] == u'"') {
        SakuraString ending = u"\""; auto begin = i + (c == u'b' ? 2 : 1);
        probe.append(ending, text.substr(begin, quote - begin));
        i = closed(text, quote + 1, ending); add(out, start, i, K::string); continue;
      }
    }
    if (language == L::sql && c == u'$') {
      auto end = i + 1; while (end < text.size() && (letter(text[end]) || digit(text[end]))) ++end;
      if (end < text.size() && text[end] == u'$') {
        auto delimiter = text.substr(i, end - i + 1);
        i = closed(text, end + 1, delimiter); add(out, start, i, K::string); continue;
      }
    }
    if ((language == L::toml || language == L::ini) && atStart && c == u'[') {
      i = lineEnd(text, i); add(out, start, i, K::preprocessor); continue;
    }
    if ((language == L::yaml || language == L::toml || language == L::ini) && atStart) {
      auto end = i; char16_t quote = 0;
      for (; end < text.size() && !eol(text[end]); ++end) {
        auto value = text[end];
        if (quote) {
          if (value == u'\\' && quote == u'"' && end + 1 < text.size()) ++end;
          else if (value == quote) quote = 0;
        } else if (value == u'\'' || value == u'"') quote = value;
        else if (value == u'#' || value == u'=' || (value == u':' && language == L::yaml &&
            (end + 1 == text.size() || space(text[end + 1]) || eol(text[end + 1])))) break;
      }
      if (end < text.size() && (text[end] == u'=' || (language == L::yaml && text[end] == u':'))) {
        while (end > i && space(text[end - 1])) --end;
        if (end > i) { i = end; add(out, start, i, K::keyword); continue; }
      }
    }
    bool verbatim = language == L::csharp && starts(text, i, u"@\"");
    bool objcString = language == L::objectiveC && starts(text, i, u"@\"");
    if (verbatim || objcString) c = text[++i];
    bool rustLifetime = language == L::rust && c == u'\'' && i + 1 < text.size() && letter(text[i + 1]) &&
        !(i + 2 < text.size() && text[i + 2] == u'\'') && !(i + 3 < text.size() && text[i + 3] == u'\'');
    if (!rustLifetime && (c == u'"' || (c == u'\'' && language != L::json) ||
        (c == u'`' && (language == L::javascript || language == L::typescript || language == L::go || language == L::shell || language == L::sql)))) {
      auto quote = c; ++i;
      bool triple = (language == L::python || language == L::swift || language == L::toml || language == L::csharp) &&
          i + 1 < text.size() && text[i] == quote && text[i + 1] == quote;
      if (triple) {
        i += 2; SakuraString ending(3, quote);
        auto end = text.find(ending, i);
        while (end != text.npos && !(language == L::toml && quote == u'\'')) {
          auto back = end; while (back > i && text[back - 1] == u'\\') --back;
          if ((end - back) % 2 == 0) break;
          end = text.find(ending, end + 1);
        }
        i = end == text.npos ? text.size() : end + 3;
      }
      else {
        bool multiline = verbatim || quote == u'`' || language == L::sql || language == L::shell || language == L::ruby;
        while (i < text.size()) {
          if (!multiline && eol(text[i])) break;
          bool escapes = !verbatim && language != L::sql &&
              !(language == L::go && quote == u'`') &&
              !(language == L::shell && quote == u'\'') && !(language == L::toml && quote == u'\'');
          if (escapes && text[i] == u'\\' && i + 1 < text.size()) { i += 2; continue; }
          if (text[i++] == quote) {
            if ((verbatim || language == L::sql) && i < text.size() && text[i] == quote) { ++i; continue; }
            break;
          }
        }
      }
      add(out, start, i, K::string); continue;
    }
    if (digit(c) || (c == u'.' && i + 1 < text.size() && digit(text[i + 1]))) {
      bool radix = c == u'0' && i + 1 < text.size() &&
          (text[i + 1] == u'x' || text[i + 1] == u'X' || text[i + 1] == u'b' || text[i + 1] == u'B' || text[i + 1] == u'o' || text[i + 1] == u'O');
      if (radix) {
        i += 2;
        while (i < text.size() && (digit(text[i]) || text[i] == u'_' ||
            (text[i] >= u'a' && text[i] <= u'f') || (text[i] >= u'A' && text[i] <= u'F'))) ++i;
      } else {
        ++i; while (i < text.size() && (digit(text[i]) || text[i] == u'_')) ++i;
        if (c != u'.' && i < text.size() && text[i] == u'.' && !starts(text, i, u"..")) {
          ++i; while (i < text.size() && (digit(text[i]) || text[i] == u'_')) ++i;
        }
        if (i < text.size() && (text[i] == u'e' || text[i] == u'E')) {
          auto exponent = i + 1;
          if (exponent < text.size() && (text[exponent] == u'+' || text[exponent] == u'-')) ++exponent;
          if (exponent < text.size() && digit(text[exponent])) {
            i = exponent + 1; while (i < text.size() && (digit(text[i]) || text[i] == u'_')) ++i;
          }
        }
      }
      add(out, start, i, K::number); continue;
    }
    if (letter(c) || c == u'$' || (language == L::objectiveC && c == u'@')) {
      ++i; while (i < text.size() && ident(text[i])) ++i;
      auto begin = start + (c == u'@' ? 1 : 0);
      if (keyword(text.substr(begin, i - begin), language, probe)) add(out, start, i, K::keyword);
      continue;
    }
    ++i;
  }
  if (options.driver) options.driver->finalState = {lineStart};
  return out;
}
}
std::vector<SyntaxToken> detail::scanLanguageSyntax(SakuraStringView source, SyntaxLanguage language,
    SyntaxProbe& probe, SyntaxScanOptions options) {
  return lex(source, language, probe, options);
}
SyntaxLanguage SyntaxHighlighter::languageForExtension(std::string_view extension) {
  std::string ext(extension); if (!ext.empty() && ext.front() == '.') ext.erase(0, 1);
  for (auto& c : ext) if (c >= 'A' && c <= 'Z') c += 32;
  static constexpr std::pair<std::string_view, L> entries[] = {
    {"c",L::c},{"h",L::cpp},{"cc",L::cpp},{"cpp",L::cpp},{"cxx",L::cpp},{"hh",L::cpp},{"hpp",L::cpp},{"hxx",L::cpp},
    {"m",L::objectiveC},{"mm",L::objectiveC},{"swift",L::swift},{"java",L::java},{"cs",L::csharp},
    {"js",L::javascript},{"jsx",L::javascript},{"mjs",L::javascript},{"cjs",L::javascript},
    {"ts",L::typescript},{"tsx",L::typescript},{"mts",L::typescript},{"cts",L::typescript},
    {"py",L::python},{"pyw",L::python},{"json",L::json},{"sh",L::shell},{"bash",L::shell},{"zsh",L::shell},
    {"rb",L::ruby},{"sql",L::sql},{"html",L::html},{"htm",L::html},{"xml",L::xml},{"svg",L::xml},{"plist",L::xml},
    {"css",L::css},{"md",L::markdown},{"markdown",L::markdown},{"mdown",L::markdown},{"mkd",L::markdown},
    {"yml",L::yaml},{"yaml",L::yaml},{"toml",L::toml},{"ini",L::ini},{"cfg",L::ini},{"conf",L::ini},{"go",L::go},{"rs",L::rust},
  };
  for (auto [name, language] : entries) if (ext == name) return language;
  return L::plain;
}
std::vector<SyntaxToken> SyntaxHighlighter::highlight(const TextBuffer& buffer, SyntaxLanguage language,
    const std::function<bool()>& cancelled) const {
  SyntaxProbe probe(cancelled);
  if (language == L::plain) return {}; // Do not copy large plain-text documents.
  auto result = lex(buffer.text(cancelled), language, probe);
  probe.check();
  return result;
}
}  // namespace sakura::core
