"""Stage 3 actionable share conflicts retain fail-closed configuration reads."""
from pathlib import Path
import unittest

import test_share_manager_networks as fixture

s = fixture.s


class Stage3SharePathTests(unittest.TestCase):
    setUp = fixture.NetworkManagerTests.setUp
    offline = fixture.NetworkManagerTests.offline

    def test_internal_conflict_names_the_reserved_path_and_leaves_registry_untouched(self):
        before = Path(self.m.path).read_bytes()
        data = self.m.read()
        # The trash is the base's own reserved name; as a hidden folder it never reaches a share.
        self.assertEqual(data["blocked"], [".cop"])
        for path in (".cop", ".cop/old"):
            with self.subTest(path=path), self.assertRaisesRegex(s.ShareError, "gizli/iç klasörler"):
                self.m.validate_path(data, path)
        # A reserved entry is named in the refusal, whether the share would contain it or sit inside it.
        data["blocked"].append("media/pending")
        for path in ("media", "media/pending", "media/pending/part"):
            with self.subTest(path=path), self.assertRaisesRegex(s.ShareError, "iç/geçici alan “media/pending”"):
                self.m.validate_path(data, path)
        self.assertEqual(Path(self.m.path).read_bytes(), before)

    def test_existing_share_conflict_names_its_path_and_exclusion_still_works(self):
        before = Path(self.m.path).read_bytes()
        with self.assertRaisesRegex(s.ShareError, "mevcut paylaşım “alpha”"):
            self.m.validate_path(self.m.read(), "alpha/child")
        path, identity = self.m.validate_path(self.m.read(), "alpha", self.item["id"])
        self.assertEqual((path, identity), ("alpha", self.item["identity"]))
        self.assertEqual(Path(self.m.path).read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
