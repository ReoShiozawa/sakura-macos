// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#include "sakura/core/syntax/SyntaxHighlighter.h"
#include <iostream>
#include <random>
#include <stdexcept>
#include <thread>
#include <atomic>
using namespace sakura::core;
using L = SyntaxLanguage;
using K = SyntaxTokenKind;
int failures = 0;
void check(bool ok, const char* message) { if (!ok) { std::cerr << message << '\n'; ++failures; } }
void has(L language, SakuraStringView source, SakuraStringView fragment, K kind) {
  TextBuffer buffer(source);
  auto tokens = SyntaxHighlighter{}.highlight(buffer, language);
  bool found = false;
  for (auto token : tokens) if (token.kind == kind && source.substr(token.range.location, token.range.length) == fragment) found = true;
  check(found, "expected language token missing");
}
bool same(const std::vector<SyntaxToken>& a, const std::vector<SyntaxToken>& b) {
  if (a.size() != b.size()) return false;
  for (std::size_t i = 0; i < a.size(); ++i)
    if (a[i].range.location != b[i].range.location || a[i].range.length != b[i].range.length ||
        a[i].kind != b[i].kind || a[i].keywordGroup != b[i].keywordGroup) return false;
  return true;
}
void cancellationInsideLongTokens() {
  struct Example { L language; SakuraStringView prefix, suffix; SakuraChar fill; };
  const Example examples[] = {
    {L::cpp,u"/*",u"*/",u'x'}, {L::swift,u"/* /*",u"*/ */",u'x'},
    {L::cpp,u"//",u"\nint x;",u'x'}, {L::cpp,u"#define X ",u"\nint x;",u'x'},
    {L::cpp,u"R\"tag(",u")tag\"",u'x'}, {L::python,u"'''",u"'''",u'x'},
    {L::rust,u"r###\"",u"\"###",u'x'}, {L::sql,u"$tag$",u"$tag$",u'x'},
    {L::sql,u"",u" ",u'x'}, {L::json,u"\"",u"\"",u'x'},
    {L::html,u"<script>/*",u"*/</script>",u'x'}, {L::html,u"<a attr=\"",u"\">",u'x'},
    {L::xml,u"<![CDATA[",u"]]>",u'x'}, {L::markdown,u"```\n",u"\n```",u'x'},
    {L::markdown,u"`",u"`",u'x'}, {L::shell,u"cat <<EOF\n",u"\nEOF",u'x'},
    {L::yaml,u"key: |\n  ",u"\nnext: true",u'x'}, {L::yaml,u"",u": true",u'x'},
    {L::ini,u"[",u"]",u'x'}, {L::ruby,u"'",u"'",u'x'}, {L::go,u"",u" ",u'7'},
  };
  for (const auto& example : examples) {
    SakuraString source(example.prefix); source.append(256 * 1024, example.fill); source += example.suffix;
    TextBuffer buffer(source);
    std::size_t serialization = 0;
    (void)buffer.text([&] { ++serialization; return false; });
    std::size_t checks = 0;
    auto result = SyntaxHighlighter{}.highlight(buffer, example.language, [&] { ++checks; return false; });
    if (checks <= serialization + 3)
      std::cerr << "long-token probe language=" << static_cast<int>(example.language)
                << " prefix-size=" << example.prefix.size() << " checks=" << checks << " serialization=" << serialization << '\n';
    check(checks > serialization + 3, "long tokens have interior cancellation probes, beyond serialization/final check");
    check(same(result, SyntaxHighlighter{}.highlight(buffer, example.language)), "cancellation probes preserve exact lexical output");
    checks = 0; bool cancelled = false;
    try {
      (void)SyntaxHighlighter{}.highlight(buffer, example.language, [&] { return ++checks >= serialization + 3; });
    } catch (const std::runtime_error&) { cancelled = true; }
    check(cancelled && checks == serialization + 3, "cancel during lexical scan without returning partial tokens");
    check(buffer.text() == source, "cancelled lexer preserves source");
  }
  TextBuffer small(u"<script>const x = 'v'; /* c */</script><!-- c -->");
  std::size_t count = 0;
  (void)SyntaxHighlighter{}.highlight(small, L::html, [&] { ++count; return false; });
  for (std::size_t stop = 1; stop <= count; ++stop) {
    std::size_t at = 0; bool cancelled = false;
    try { (void)SyntaxHighlighter{}.highlight(small, L::html, [&] { return ++at == stop; }); }
    catch (const std::runtime_error&) { cancelled = true; }
    check(cancelled, "every nested-lexer cancellation checkpoint aborts atomically");
  }
  TextBuffer legacy(SakuraString(u"/*") + SakuraString(256 * 1024, u'x') + u"*/");
  std::size_t serialization = 0, at = 0;
  (void)legacy.text([&] { ++serialization; return false; });
  bool cancelled = false;
  try { (void)SyntaxHighlighter{}.highlightCLike(legacy, [&] { return ++at >= serialization + 3; }); }
  catch (const std::runtime_error&) { cancelled = true; }
  check(cancelled, "legacy C-like lexer is cancellable inside a long comment");
  // The long-delimiter KMP path, including repetitive near-matches and a
  // delimiter crossing the 64KiB search-chunk boundary.
  SakuraString hashes(128, u'#');
  SakuraString raw = u"r" + hashes + u"\"" + SakuraString(65535, u'x') + u"\"" + hashes + u" int";
  auto rawTokens = SyntaxHighlighter{}.highlight(TextBuffer(raw), L::rust);
  check(rawTokens.size() == 1 && rawTokens.front().range.length == raw.size() - 4, "long raw delimiter closes at the exact boundary");
  SakuraString nearMatches = u"r" + hashes + u"\"";
  for (int n = 0; n < 1000; ++n) { nearMatches += u'"'; nearMatches.append(hashes, 0, hashes.size() - 1); }
  nearMatches += u'"'; nearMatches += hashes;
  has(L::rust, nearMatches, nearMatches, K::string);
  SakuraString markdown = u"`" + SakuraString(65535, u'x') + u"`";
  has(L::markdown, markdown, markdown, K::string);
  bool immediate = false;
  try { (void)SyntaxHighlighter{}.highlight(small, L::plain, [] { return true; }); }
  catch (const std::runtime_error&) { immediate = true; }
  check(immediate, "plain mode honors pre-cancel without serializing");
}
void concurrentSnapshots() {
  TextBuffer live(u"<script>const value = '桜😀'; /* comment */</script>\r\n");
  const TextBuffer snapshot = live;
  const auto expected = SyntaxHighlighter{}.highlight(snapshot, L::html);
  std::atomic<bool> okay{true};
  std::vector<std::thread> workers;
  for (int i = 0; i < 6; ++i) workers.emplace_back([&] {
    for (int n = 0; n < 100; ++n)
      if (!same(expected, SyntaxHighlighter{}.highlight(snapshot, L::html, [] { return false; }))) okay = false;
  });
  for (int n = 0; n < 100; ++n) live.replace({0,0}, u"x");
  for (auto& worker : workers) worker.join();
  check(okay, "concurrent lexers retain independent probes and immutable source");
}
int main() {
  cancellationInsideLongTokens();
  concurrentSnapshots();
  check(SyntaxHighlighter::languageForExtension(".PY") == L::python, "extension dispatch case insensitive");
  check(SyntaxHighlighter::languageForExtension("unknown") == L::plain, "unknown extension plain");
  has(L::python, u"async def f():\n  s = '''# not comment\nclass Fake:''' # real", u"async", K::keyword);
  has(L::python, u"s = '''# not comment\nclass Fake:''' # real", u"'''# not comment\nclass Fake:'''", K::string);
  has(L::python, u"s = '# not comment' # real", u"# real", K::comment);
  has(L::cpp, u"auto s = R\"tag(a \" // b\n)tag\";", u"R\"tag(a \" // b\n)tag\"", K::string);
  has(L::cpp, u"#define X \\\r\n  42\r\nint y;", u"#define X \\\r\n  42", K::preprocessor);
  has(L::objectiveC, u"@interface A\n @\"// 桜😀\"", u"@interface", K::keyword);
  has(L::objectiveC, u"@\"// 桜😀\"", u"@\"// 桜😀\"", K::string);
  has(L::swift, u"actor A { /* outer /* inner */ still */ let s = \"\"\"a\nb\"\"\" }", u"/* outer /* inner */ still */", K::comment);
  has(L::swift, u"let s = \"\"\"a\nb\"\"\"", u"\"\"\"a\nb\"\"\"", K::string);
  has(L::java, u"public record Foo(int x) {}", u"record", K::keyword);
  has(L::csharp, u"var s = @\"a\"\"b\nc\";", u"@\"a\"\"b\nc\"", K::string);
  has(L::javascript, u"const s = `hello \\` world\n`;", u"`hello \\` world\n`", K::string);
  has(L::typescript, u"interface A { readonly x: number; }", u"readonly", K::keyword);
  has(L::go, u"package main\nvar s = `a\nb`", u"`a\nb`", K::string);
  has(L::rust, u"fn f<'a>() { let s = r##\"/* raw */\n\"##; }", u"r##\"/* raw */\n\"##", K::string);
  has(L::rust, u"/* a /* b */ c */ fn f() {}", u"/* a /* b */ c */", K::comment);
  has(L::shell, u"if true; then echo '# x'; fi # real", u"# real", K::comment);
  has(L::ruby, u"class Example\n def f\n end\nend", u"def", K::keyword);
  has(L::json, u"{\"comment\": \"// no\", \"ok\": true}", u"true", K::keyword);
  has(L::sql, u"select 'it''s' from t -- real", u"select", K::keyword);
  has(L::sql, u"select 'it''s', $tag$'quoted'$tag$;", u"'it''s'", K::string);
  has(L::sql, u"select $tag$'quoted'$tag$;", u"$tag$'quoted'$tag$", K::string);
  has(L::html, u"<!-- x --><div id=\"main\">&amp;</div>", u"div", K::keyword);
  has(L::html, u"<SCRIPT type=\"text/javascript\">const s = '<fake/>';</SCRIPT>", u"const", K::keyword);
  has(L::html, u"<style>/* x */ .a { display: flex; }</style>", u"/* x */", K::comment);
  has(L::xml, u"<![CDATA[<fake/>]]>", u"<![CDATA[<fake/>]]>", K::string);
  has(L::css, u"/* x */ .foo { width: 1.5em; display: flex; }", u"flex", K::keyword);
  has(L::markdown, u"# Title\n```python\n# not heading\n```\n", u"```python\n# not heading\n```", K::string);
  has(L::yaml, u"name: value\nflag: true # c", u"flag", K::keyword);
  has(L::yaml, u"description: |\n  # not comment\n  true\nnext: false", u"|\n  # not comment\n  true", K::string);
  has(L::yaml, u"\"http://key\": value", u"\"http://key\"", K::keyword);
  has(L::shell, u"cat <<'EOF'\n# literal\nEOF\necho ok", u"<<'EOF'\n# literal\nEOF", K::string);
  has(L::markdown, u"a **bold** and [label](url)", u"**bold**", K::keyword);
  has(L::toml, u"[section]\nname = \"value\"", u"[section]", K::preprocessor);
  has(L::ini, u"[section]\nname=value ; comment", u"; comment", K::comment);
  has(L::cpp, u"auto n = 1.5e-3;", u"1.5e-3", K::number);
  has(L::rust, u"let x = 0..10;", u"0", K::number);
  // Deterministic malformed-input regression: ordered, nonoverlapping UTF-16
  // ranges, no surrogate/CRLF split, and no source mutation for all profiles.
  std::mt19937 random(1729);
  const SakuraString alphabet = u"ab019_ #<>\"'`/\\*[]{}():;=$+-\r\n\t桜😀";
  for (int sample = 0; sample < 500; ++sample) {
    SakuraString source;
    for (int i = 0; i < 80; ++i) source += alphabet[random() % alphabet.size()];
    TextBuffer buffer(source);
    for (int language = 0; language <= static_cast<int>(L::rust); ++language) {
      auto tokens = SyntaxHighlighter{}.highlight(buffer, static_cast<L>(language));
      TextOffset end = 0;
      for (auto token : tokens) {
        check(token.range.length && token.range.location >= end && token.range.location + token.range.length <= buffer.length(), "valid ordered syntax ranges");
        end = token.range.location + token.range.length;
        check(buffer.isEditBoundary(token.range.location) && buffer.isEditBoundary(end), "syntax ranges preserve surrogate and CRLF boundaries");
      }
      check(buffer.text() == source, "coloring never edits source");
    }
  }
  return failures ? 1 : 0;
}
