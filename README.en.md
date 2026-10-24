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
The release label is **β1.0**, with tag `v1.0.0-beta.1`; this is a prerelease, not a stable version.

## Install the prerelease

Download the Universal DMG from [Releases](https://github.com/ReoShiozawa/sakura-macos/releases/tag/v1.0.0-beta.1)
and drag `SakuraEditor.app` to Applications. To uninstall, move the app to the Trash;
preferences and recovery data are retained. This beta has **no Developer ID signature or notarization**
and macOS may block it. Verify the source and SHA-256; do not disable Gatekeeper globally.
See [Apple's safety guidance](https://support.apple.com/en-us/102445) or build from source.
Windows releases are on hold. This public source snapshot excludes inherited Windows assets,
prebuilt archives, installers, submodules and the full upstream history.
The beta DMG requires **macOS 26.0 or later** (tested on 26.4.1).
Ad-hoc resource sealing does not authenticate a developer identity.

## Protect your data

Back up important files before use. Multi-file Grep replacement is not an all-files atomic
transaction; cancel does not undo files already saved. Recovery stores plaintext document
contents and paths under `~/Library/Application Support/SakuraEditor/Recovery/`;
retention and size management are incomplete. This legacy location is retained to preserve
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
