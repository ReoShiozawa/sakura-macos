# Sakura macOS — Unofficial port

An experimental macOS port inspired by [Sakura Editor](https://github.com/sakura-editor/sakura),
with a C++20 core and an AppKit / Core Text UI.

**This is an unofficial, modified version. It is not provided, endorsed, or supported
by Sakura Editor Organization.** It is not a fully compatible replacement or a stable release.
The upstream baseline is `b1eef8a24b341cd00299727057642d8581c8638b`.

See the [Japanese README](README.md) for the feature list, detailed limitations and build options.

## Build and test

Requires macOS, Xcode Command Line Tools or Xcode, CMake 3.21+, and a C++20 Apple Clang compiler.
Windows submodules and vcpkg are not required for this macOS build.
The publication checker requires Python 3.9+; CMake adds its tests when Python is found.
The application itself does not require Python.

```sh
cmake -S . -B build/macos -DCMAKE_BUILD_TYPE=Debug -DBUILD_TESTING=ON
cmake --build build/macos --parallel
ctest --test-dir build/macos --output-on-failure
python3 tools/check_macos_publication.py --bundle build/macos/ui/mac/SakuraEditor.app
open build/macos/ui/mac/SakuraEditor.app
```

The display name is **Sakura macOS (Unofficial)**. The existing target and bundle filename remain
`SakuraEditor.app`. The default identifier `local.unofficial-sakura.macos` is for development;
distributors must configure their own identifier with `SAKURA_MAC_BUNDLE_IDENTIFIER`.
Old development-build preferences are not automatically migrated.

Development verification uses macOS 26.4.1 on Apple Silicon. Older OS compatibility and
Intel hardware testing remain unverified. Developer ID signing and notarization are not completed.
The release label is **β1.1**, with tag `v1.1.0-beta.1`; this is a prerelease, not a stable version.

## Install the prerelease

Download the Universal DMG from [Releases](https://github.com/ReoShiozawa/sakura-macos/releases/tag/v1.1.0-beta.1)
and drag `SakuraEditor.app` to Applications. To uninstall, move the app to the Trash;
preferences and recovery data are retained. This beta has **no Developer ID signature or notarization**
and macOS may block it. Verify the source and SHA-256; do not disable Gatekeeper globally.
See [Apple's safety guidance](https://support.apple.com/en-us/102445) or build from source.
Windows releases are on hold. This public source snapshot excludes inherited Windows assets,
prebuilt archives, installers, submodules and the full upstream history.
The beta DMG requires **macOS 26.0 or later** (tested on 26.4.1).
Ad-hoc resource sealing does not authenticate a developer identity.

## Protect your data

Local development also includes logical-line jumps (Command-L), session-only shared bookmarks,
indent/unindent, whitespace trimming, literal line sorting, adjacent duplicate removal,
logical-line duplication, width/kana conversion and TAB/space conversion. Each text-changing
command is a single undo operation. These commands are included in β1.1.
Bookmark remapping now retains shared text snapshots and compares bounded windows instead of
serializing the entire document after each edit. Shared prefixes/suffixes are skipped where safe,
and obsolete snapshots are released on a worker. Legacy anchor behavior is preserved; reloads,
large changes and repeated text can still require long comparisons on the main thread.
Further local additions include serial Save All (stopping on cancellation, failure or new edits),
Save and Close, dynamic recent-file/folder menus, date/time insertion, word/line deletion,
file-reference copying and CRLF copying. Pending IME input is committed before saving;
edits newer than the saved snapshot remain dirty and keep their recovery data.
The core now adds Unicode caseless/whole-word search, multiline regex anchors,
language-specific lexical coloring, and outline filtering for comments/strings.
Grep supports explicit encoding, whole words, `!` filename exclusions and UTF-8 result export.
Type-specific custom words and regex rules are editable in the keyword settings tab.
They support ten independently styled groups, preserve base tokens and run asynchronously with resource limits.
Import/export supports a strict subset of upstream .kwd keyword files; unsupported entries reject the entire import.
This is not full syntax parsing or upstream settings-file compatibility.
Search/replace now supports a fixed selection region per pane, wrap on/off,
Command-E to use selected text literally, and asynchronous match counting.
Search criteria and up to 20 query/replacement history entries are shared in memory only;
manual edits or undo invalidate the fixed region until it is explicitly recaptured.
Counting, highlighting, captures and replacements have documented resource limits.
The line buffer uses immutable shared AVL roots for constant-time snapshot creation and path-copy edits,
including newline changes. Highlight matching now runs off the main thread after a 150 ms debounce;
stale results are rejected after text, criteria, scope or composition changes.
Counting and custom coloring also take shared snapshots; normal IME previews share unaffected lines.
Next/previous matching also runs asynchronously, with queued direction changes and stale-selection guards.
Command-period or the stop button cancels pending navigation, counting and highlighting.
Reverse search retains candidates instead of an all-hit array, removing the old 100,000-hit navigation cutoff.
Display strings now retain shared UTF-16 storage instead of serializing the entire buffer;
IME previews splice only marked text, including partial surrogate/CRLF preview ranges.
An immutable block-tree layout remeasures changed logical lines without rewriting every
following row offset. Font/wrap changes still require complete reflow;
explicit-save encoding and startup recovery reads still need optimization.
Single replacement and Replace All prepare matching, expansion, grouped text changes, snapshot undo and each pane's
layout on a serial worker queue. Publication rejects stale text/history, criteria, selection,
composition or layout settings; stop/Command-period/Escape cancels pending work.
No-op replacements leave dirty state and redo untouched. A single undo/redo swaps retained roots;
large obsolete redo/layout data is released on the worker. Single replacement verifies the exact selected
match with full-source regex context; otherwise it selects the next match without editing. That fallback
also authenticates its source before moving the selection. Following a successful single replacement,
next-match search is a separate asynchronous operation. Zero-width matches advance past the original
character; CRLF/surrogate joins never leave a caret inside an edit boundary. An invalidated fixed scope
requires recapture rather than silently searching outside it. Undo/redo cancels pending replacement even
with no usable history. A newer replacement supersedes pending preparation; replacement during pending
navigation requires retrying after search completes. Explicit-save encoding and layout changes
after scrollbar/viewport transitions still need optimization.
Recovery backups now retain immutable text roots and serialize, write and remove on a serial utility queue.
Pending writes coalesce without dropping removal barriers; saves, reloads and closes cannot resurrect old backups.
Quit preserves NSDocument close/save/cancel review, then asynchronously drains recovery work before exit.
Late save completion preserves newer explicit encoding/BOM choices. Startup recovery reads remain synchronous.
These recovery changes are included in β1.1.
Document next/previous/all-hit search, highlighting and replacement no longer unconditionally serialize the full
source. Case-sensitive literal matching streams through small windows using KMP; ICU UText reads shared UTF-16
roots for regular expressions and Unicode caseless matching. Capture expansion copies only the referenced
original-source ranges, and custom keyword/regex coloring also reads the shared source. Match/capture/time/output
limits remain unchanged. Bounded provider windows are not a fixed-memory guarantee for patterns, ICU workspace,
all-hit arrays or replacement output, nor a claim of Bregonig/Onigmo compatibility.
UI Undo/Redo now prepares immutable history transitions and each pane's layout on a worker,
then authenticates document ownership, source/history, selection, IME and pane settings before publication.
Queued directions retain their order; edits, manual movement, cancellation and closing invalidate pending work.
Reentrant publication callbacks cannot start the next transition before refresh finishes.
All panes normalize selections at restored CRLF/surrogate boundaries. This does not make every
editing, save, layout-setting or document-close operation asynchronous or hard real-time.
Command-] now asynchronously jumps to a matching bracket using upstream's 18 default pairs and
right-character priority. It scans raw text rather than excluding comments/strings. Automatic bracket
highlighting and custom-pair settings UI are still missing; DIFF, tag navigation and completion remain unimplemented.
Ordinary lexical coloring now runs on a serial worker after a 75 ms debounce, with cancellation
inside long comments/strings and source-root, revision, language, settings and IME validation.
Base tokens are published before custom rules run against their complete protection mask;
obsolete token/snapshot disposal stays off the drawing thread. Escape stops pending
analysis until a relevant input changes. Pending/failed ordinary analysis displays unstyled text;
the status bar reports progress or the five-second worker time limit. Parsing now resumes from
logical-line checkpoints, retaining outer lexical state and forward-read dependencies (including
failed delimiter searches). A persistent token-block tree shares unchanged prefixes/suffixes and
stores relative offsets. Drawing queries visible ranges instead of flattening every token after
each edit. Input windows grow when more lookahead is needed; a window edge is never treated as EOF.
Large constructs or changed state can still require parsing to EOF. This is lexical analysis,
not complete language parsing or a hard real-time guarantee. Outline parsing remains separate.
Japanese auto-detection now compares CP932/EUC-JP byte evidence, kana frequency and a bounded
Foundation encoding hint. Structurally ambiguous reads remain visibly marked as guesses;
bulk Grep replacement and .kwd import require an explicit encoding for such inputs.
Read-time warnings survive edits, output-encoding changes and new recovery records, and clear
on successful explicit reload. Short, kanji-only and intentionally ambiguous half-kana text
cannot be inferred with certainty; check the display and encoding before saving.

Back up important files before use. Multi-file Grep replacement is not an all-files atomic
transaction; cancel does not undo files already saved. Recovery stores plaintext document
contents and paths under `~/Library/Application Support/SakuraEditor/Recovery/`;
the latest record and two previous generations are retained by default, with validated fallback on corruption.
Common Settings / Recovery configures 0–20 previous generations and a 16–4,096 MiB budget (default 256 MiB).
Conservative quota accounting includes temporary write space. On quota or I/O failure,
existing records are kept and a warning is shown; other documents are never auto-evicted.
Cooperating processes use a permanent advisory lock for quota/rotation/pruning.
File, directory and device synchronization is requested before clearing dirty state or recovery;
post-rename sync failures are reported as already-applied but not durably confirmed.
Physical power-loss validation is still incomplete, and no protection against faulty storage is claimed.
This legacy location is retained to preserve
existing recovery data. Encoding detection, Windows settings/macros/plugins, regex compatibility,
complex typesetting, accessibility and large-document performance remain incomplete.

## Licensing and community

The upstream [LICENSE](LICENSE) is preserved unchanged. Port additions use the zlib terms in
[LICENSE.macos](LICENSE.macos), without assigning new copyright to the upstream organization.
Existing per-file and third-party notices remain applicable; this is not a blanket relicensing.

Read [NOTICE](NOTICE.md), [third-party notices](THIRD_PARTY_NOTICES.md) and
[asset provenance](docs/ASSET_PROVENANCE.md). The macOS bundle excludes extracted upstream
toolbar images and the upstream application icon, using runtime system symbols and a new
independent icon instead. The inherited Windows assets and archives require separate review
before redistribution; this repository has not received comprehensive legal clearance.

Use this unofficial repository's Issues and Pull Requests, not upstream support.
See [CONTRIBUTING](CONTRIBUTING.md), [SECURITY](SECURITY.md), and the
[release checklist](docs/RELEASING.md). No official release or public GitHub CI result is implied.
