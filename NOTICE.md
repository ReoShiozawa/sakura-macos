# Attribution / 非公式改変版の表示

## Upstream

This is an unofficial, modified macOS port of Sakura Editor.
It is not provided, endorsed or supported by Sakura Editor Organization.

Upstream: https://github.com/sakura-editor/sakura
Baseline: b1eef8a24b341cd00299727057642d8581c8638b

Copyright (C) 2018-2022, Sakura Editor Organization

The upstream zlib License is preserved verbatim in LICENSE.
Individual upstream copyright holders and file-level notices remain in force.
The upstream name is used for identification only; no trademark license,
endorsement, or transfer of rights is asserted.

## Port additions

Copyright (c) 2026 Unofficial Sakura macOS port contributors

Additional portable editing/layout/search code, application services, macOS adapters,
AppKit UI, tests, port documentation, publication tools and independent icon-generation
code are provided under the zlib terms in LICENSE.macos, subject to any existing
upstream notices and third-party terms.

The collective attribution identifies contributors to this unofficial port;
it is not a separate incorporated entity, a transfer of copyright, or a claim
that the upstream organization authored these additions. Individual rights remain
with the applicable rights holders. The publisher must confirm authority to license
all submitted additions, including AI-assisted changes, before publication.

Modified areas include the top-level CMake/vcpkg configuration; new core/, app/,
platform/mac/, ui/mac/, tests/ code; fork documentation; and GitHub contribution/CI
configuration. Menu ordering, default colors and behavior draw on the upstream
implementation and resources, notably MainMenu.ini, Japanese resources and
ColorInfo_DEFAULT. These are derivative adaptations, not a claim to have independently
invented the upstream design. New headers do not remove underlying upstream rights.
The CP932/EUC-JP byte-evidence tie breaker in platform/mac/src/MacEncodingService.mm
is an altered adaptation of CESI::GuessEucOrSjis and charset/codechecker.h
(Copyright (C) 2006, 2007, 2018-2022, Sakura Editor Organization; zlib).
The macOS adapter adds SS2 half-kana evidence, a bounded Foundation hint and
read-time ambiguity reporting; it is not the original Windows detector.

## Separate materials

This notice is not a blanket license for every file in the repository.
See THIRD_PARTY_NOTICES.md and docs/ASSET_PROVENANCE.md.
Inherited Windows assets, help, submodules and prebuilt distribution archives
are not relicensed by the port's LICENSE.macos and are excluded from this
Mac-only public source snapshot and beta release. The full upstream history and
Windows build are retained only in the original development checkout.
No comprehensive legal clearance, trademark permission, or security certification
is represented by these documents.
