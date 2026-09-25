import contextlib
import importlib.util
import io
import pathlib
import tempfile
import unittest


PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[3]
SCRIPT_PATH = PROJECT_ROOT / "scripts/ci/release-notes.py"


def load_script():
    spec = importlib.util.spec_from_file_location("cida_release_notes", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        self.script = load_script()
        self.directory = tempfile.TemporaryDirectory()
        self.releases = pathlib.Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def notes(self, version, text=None):
        if text is not None:
            (self.releases / f"{version}.md").write_text(text, encoding="utf-8")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.script.main([version, "--directory", str(self.releases)])
        return output.getvalue()

    def test_items_are_printed_one_per_line_without_the_marker(self):
        output = self.notes("1.1.0", "- 新的安装包是 DMG。\n\n-  开机启动时不再弹出面板。 \n")

        self.assertEqual(output, "新的安装包是 DMG。\n开机启动时不再弹出面板。\n")

    def test_a_missing_file_fails(self):
        with self.assertRaisesRegex(SystemExit, "1.2.0.md is missing"):
            self.notes("1.2.0")

    def test_a_line_that_is_not_an_item_fails(self):
        with self.assertRaisesRegex(SystemExit, r"1.1.0.md:2: every line"):
            self.notes("1.1.0", "- 第一条\n接着上一条写的一行\n")

    def test_an_empty_item_fails(self):
        with self.assertRaisesRegex(SystemExit, r"1.1.0.md:1: every line"):
            self.notes("1.1.0", "- \n")

    def test_a_file_without_items_fails(self):
        with self.assertRaisesRegex(SystemExit, "has no items"):
            self.notes("1.1.0", "\n\n")

    def test_every_shipped_version_has_valid_notes(self):
        for path in sorted((PROJECT_ROOT / "docs/releases").glob("*.md")):
            with self.subTest(version=path.stem):
                self.assertTrue(self.script.read_notes(path))


if __name__ == "__main__":
    unittest.main()
