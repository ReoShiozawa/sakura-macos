# Copyright (c) 2026 Unofficial Sakura macOS port contributors
# SPDX-License-Identifier: Zlib
"""Bounded publication checks, not a legal audit, secret scan or signature check."""

import argparse
import hashlib
from pathlib import Path
import plistlib
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM_LICENSE_SHA256 = "0d68431babb82ebb2a63f2fbeda6dc51673635420bc8aef8eaebb36661234f4e"
LEGAL_FILES = {
    "LICENSE": "LICENSE",
    "LICENSE.macos": "LICENSE.macos",
    "NOTICE.md": "NOTICE.md",
    "THIRD_PARTY_NOTICES.md": "THIRD_PARTY_NOTICES.md",
    "ASSET_PROVENANCE.md": "docs/ASSET_PROVENANCE.md",
}
SOURCE_ROOTS = ("core", "app", "platform/mac", "ui/mac", "tests")
REQUIRED_DOCS = (
    "README.md", "README.en.md", "CONTRIBUTING.md", "SECURITY.md",
    "docs/RELEASING.md", "cmake/UnofficialVersion.cmake", *LEGAL_FILES.values(),
)


def release_metadata(root=ROOT):
    body = (root / "cmake/UnofficialVersion.cmake").read_text(encoding="utf-8")
    keys = {
        "SakuraReleaseTag": "SAKURA_RELEASE_TAG",
        "SakuraReleaseDisplayVersion": "SAKURA_RELEASE_DISPLAY_VERSION",
        "CFBundleShortVersionString": "SAKURA_RELEASE_NUMERIC_VERSION",
        "CFBundleVersion": "SAKURA_RELEASE_BUNDLE_VERSION",
    }
    result = {}
    for key, variable in keys.items():
        match = re.search(r'set\(' + variable + r' "([^"\n]+)"\)', body)
        if match is None:
            raise ValueError(f"Missing release version declaration: {variable}")
        result[key] = match.group(1)
    return result


def check_source(root=ROOT):
    errors = []
    try:
        release_metadata(root)
    except (OSError, ValueError) as error:
        errors.append(str(error))
    for relative in REQUIRED_DOCS:
        path = root / relative
        if not path.is_file() or not path.stat().st_size:
            errors.append(f"Missing or empty document: {relative}")
    license_path = root / "LICENSE"
    if license_path.is_file():
        if hashlib.sha256(license_path.read_bytes()).hexdigest() != UPSTREAM_LICENSE_SHA256:
            errors.append("Upstream LICENSE differs from the preserved baseline")
    for relative in ("README.md", "README.en.md", "NOTICE.md"):
        path = root / relative
        if path.is_file():
            body = path.read_text(encoding="utf-8")
            if "非公式" not in body and "unofficial" not in body.lower():
                errors.append(f"Unofficial declaration missing: {relative}")
    for directory in SOURCE_ROOTS:
        for path in (root / directory).rglob("*"):
            if path.suffix not in {".cpp", ".h", ".mm", ".py"}:
                continue
            header = "\n".join(path.read_text(encoding="utf-8").splitlines()[:12])
            if "SPDX-License-Identifier: Zlib" not in header or "Copyright" not in header:
                errors.append(f"Port attribution or SPDX missing: {path.relative_to(root)}")
            if "Copyright 2026 Sakura Editor Organization" in header:
                errors.append(f"Incorrect upstream authorship: {path.relative_to(root)}")
    resources = root / "ui/mac/resources"
    if (resources / "SakuraEditor.icns").exists() or list((resources / "toolbar").glob("*.png")):
        errors.append("Extracted upstream artwork remains in macOS source resources")
    return errors


def check_bundle(bundle, root=ROOT):
    errors = []
    contents = Path(bundle) / "Contents"
    try:
        info = plistlib.loads((contents / "Info.plist").read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        return [f"Cannot read bundle metadata: {error}"]
    for key in ("CFBundleName", "CFBundleDisplayName"):
        if "Unofficial" not in str(info.get(key, "")):
            errors.append(f"Missing unofficial branding: {key}")
    identifier = info.get("CFBundleIdentifier", "")
    if not isinstance(identifier, str) or not identifier or identifier.startswith("org.sakura-editor."):
        errors.append("Bundle identifier is missing or uses the upstream namespace")
    if "Unofficial Sakura macOS port contributors" not in str(info.get("NSHumanReadableCopyright", "")):
        errors.append("Port copyright missing from bundle metadata")
    if info.get("CFBundleIconFile") != "UnofficialSakura.icns":
        errors.append("Unexpected application icon")
    try:
        for key, expected in release_metadata(root).items():
            if info.get(key) != expected:
                errors.append(f"Release version mismatch: {key} (expected {expected})")
    except (OSError, ValueError) as error:
        errors.append(str(error))
    resources = contents / "Resources"
    allowed = {"UnofficialSakura.icns"}
    for filename, source in LEGAL_FILES.items():
        relative = f"Licenses/{filename}"
        allowed.add(relative)
        path = resources / relative
        if not path.is_file() or path.read_bytes() != (root / source).read_bytes():
            errors.append(f"Missing or stale bundled notice: {relative}")
    icon = resources / "UnofficialSakura.icns"
    if not icon.is_file() or not icon.read_bytes().startswith(b"icns"):
        errors.append("Generated application icon is missing or invalid")
    for path in resources.rglob("*"):
        if path.is_file() and path.relative_to(resources).as_posix() not in allowed:
            errors.append(f"Unexpected bundled resource: {path.relative_to(resources)}")
    if not (contents / "MacOS/SakuraEditor").is_file():
        errors.append("Application executable missing")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, help="Also inspect an already-built .app")
    parser.add_argument("--mac-snapshot", action="store_true", help="Reject inherited Windows distribution material")
    args = parser.parse_args()
    errors = check_source()
    if args.mac_snapshot:
        for relative in ("externals", "installer", "help", "sakura_core", "src/main/resources/images", ".gitmodules"):
            if (ROOT / relative).exists():
                errors.append(f"Excluded Windows material in Mac-only snapshot: {relative}")
        for path in ROOT.rglob("*"):
            relative = path.relative_to(ROOT)
            if relative.parts[0] in {".git", "build", "dist"}:
                continue
            if path.suffix.lower() in {".zip", ".dll", ".exe", ".chm", ".bmp", ".ico", ".cur", ".icns", ".png"}:
                errors.append(f"Unexpected prebuilt material in Mac-only source: {relative}")
    if args.bundle:
        errors.extend(check_bundle(args.bundle))
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    if errors:
        return 1
    print("Publication checks passed (bounded checks only; manual release checklist still required).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
