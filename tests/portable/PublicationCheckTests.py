# Copyright (c) 2026 Unofficial Sakura macOS port contributors
# SPDX-License-Identifier: Zlib

from pathlib import Path
import plistlib
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
import check_macos_publication as publication


class PublicationCheckTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.bundle = Path(self.temporary.name) / "Test.app"
        self.contents = self.bundle / "Contents"
        self.resources = self.contents / "Resources"
        (self.resources / "Licenses").mkdir(parents=True)
        (self.contents / "MacOS").mkdir()
        (self.contents / "MacOS/SakuraEditor").write_bytes(b"test executable")
        self.info = {
            "CFBundleName": "Sakura macOS (Unofficial)",
            "CFBundleDisplayName": "Sakura macOS (Unofficial)",
            "CFBundleIdentifier": "local.unofficial-sakura.macos",
            "NSHumanReadableCopyright": "Unofficial Sakura macOS port contributors",
            "CFBundleIconFile": "UnofficialSakura.icns",
        }
        self.info.update(publication.release_metadata())
        self.write_info()
        (self.resources / "UnofficialSakura.icns").write_bytes(b"icns test fixture")
        for filename, source in publication.LEGAL_FILES.items():
            shutil.copyfile(publication.ROOT / source, self.resources / "Licenses" / filename)

    def write_info(self):
        (self.contents / "Info.plist").write_bytes(plistlib.dumps(self.info))

    def test_expected_bundle(self):
        self.assertEqual(publication.check_bundle(self.bundle), [])

    def test_official_brand_rejected(self):
        self.info["CFBundleDisplayName"] = "Sakura Editor"
        self.write_info()
        self.assertTrue(publication.check_bundle(self.bundle))

    def test_upstream_namespace_rejected(self):
        self.info["CFBundleIdentifier"] = "org.sakura-editor.SakuraEditor"
        self.write_info()
        self.assertTrue(publication.check_bundle(self.bundle))

    def test_extracted_artwork_rejected(self):
        (self.resources / "toolbar").mkdir()
        (self.resources / "toolbar/new.png").write_bytes(b"test fixture")
        self.assertTrue(publication.check_bundle(self.bundle))

    def test_missing_notice_rejected(self):
        (self.resources / "Licenses/LICENSE.macos").unlink()
        self.assertTrue(publication.check_bundle(self.bundle))

    def test_stale_notice_rejected(self):
        (self.resources / "Licenses/NOTICE.md").write_text("stale", encoding="utf-8")
        self.assertTrue(publication.check_bundle(self.bundle))

    def test_missing_metadata_rejected(self):
        (self.contents / "Info.plist").unlink()
        self.assertTrue(publication.check_bundle(self.bundle))

    def test_old_release_rejected(self):
        self.info["SakuraReleaseTag"] = "v0.1.0"
        self.write_info()
        self.assertTrue(publication.check_bundle(self.bundle))

    def test_missing_release_label_rejected(self):
        del self.info["SakuraReleaseDisplayVersion"]
        self.write_info()
        self.assertTrue(publication.check_bundle(self.bundle))

    def test_source(self):
        self.assertEqual(publication.check_source(), [])


if __name__ == "__main__":
    unittest.main()
