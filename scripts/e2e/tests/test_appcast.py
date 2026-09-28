import importlib.util
import pathlib
import tempfile
import unittest
import xml.etree.ElementTree as ElementTree


PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[3]
SCRIPT_PATH = PROJECT_ROOT / "scripts/ci/update-appcast.py"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def load_script():
    spec = importlib.util.spec_from_file_location("cida_update_appcast", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.script = load_script()
        self.directory = tempfile.TemporaryDirectory()
        self.feed = pathlib.Path(self.directory.name) / "appcast.xml"

    def tearDown(self):
        self.directory.cleanup()

    def publish(self, version, build, channel=None, notes=None):
        arguments = [
            "--appcast", str(self.feed),
            "--output", str(self.feed),
            "--version", version,
            "--build", build,
            "--url", f"https://cida-releases.xuanwo.io/releases/{version}-{build}/Cida-{version}-{build}.zip",
            "--length", "19000000",
            "--signature", f"signature-{build}",
            "--published", "Fri, 25 Sep 2026 12:00:00 GMT",
        ]
        if channel:
            arguments += ["--channel", channel]
        if notes is not None:
            notes_path = pathlib.Path(self.directory.name) / "notes.txt"
            notes_path.write_text(notes, encoding="utf-8")
            arguments += ["--notes", str(notes_path)]
        self.script.main(arguments)
        return ElementTree.parse(self.feed).getroot().find("channel").findall("item")

    def test_a_new_feed_gets_the_release_with_its_signed_enclosure(self):
        items = self.publish("1.1.0", "140")

        self.assertEqual(len(items), 1)
        item = items[0]
        self.assertEqual(item.findtext(f"{SPARKLE}version"), "140")
        self.assertEqual(item.findtext(f"{SPARKLE}shortVersionString"), "1.1.0")
        self.assertEqual(item.findtext(f"{SPARKLE}minimumSystemVersion"), "15.0")
        self.assertIsNone(item.find(f"{SPARKLE}channel"), "A release is on the default channel")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get(f"{SPARKLE}edSignature"), "signature-140")
        self.assertEqual(enclosure.get("length"), "19000000")
        self.assertTrue(enclosure.get("url").endswith("/releases/1.1.0-140/Cida-1.1.0-140.zip"))

    def test_newer_items_come_first_and_candidates_carry_the_beta_channel(self):
        self.publish("1.1.0", "140")
        items = self.publish("1.2.0", "150", channel="beta")

        self.assertEqual([item.findtext(f"{SPARKLE}version") for item in items], ["150", "140"])
        self.assertEqual(items[0].findtext(f"{SPARKLE}channel"), "beta")

    def test_a_release_replaces_its_candidate_from_the_same_build(self):
        self.publish("1.1.0", "140")
        self.publish("1.2.0", "150", channel="beta")
        items = self.publish("1.2.0", "150")

        self.assertEqual([item.findtext(f"{SPARKLE}version") for item in items], ["150", "140"])
        self.assertIsNone(items[0].find(f"{SPARKLE}channel"))

    def test_each_channel_keeps_its_two_newest_builds(self):
        self.publish("1.0.0", "120")
        self.publish("1.1.0", "128", channel="beta")
        self.publish("1.1.0", "129", channel="beta")
        self.publish("1.1.0", "140")
        self.publish("1.1.1", "150")
        items = self.publish("1.2.0", "160", channel="beta")

        self.assertEqual(
            [item.findtext(f"{SPARKLE}version") for item in items], ["160", "150", "140", "129"]
        )

    def test_candidates_never_push_the_releases_out(self):
        self.publish("1.1.0", "140")
        self.publish("1.1.1", "150")
        for build in ("160", "161", "162"):
            items = self.publish("1.2.0", build, channel="beta")

        self.assertEqual(
            [item.findtext(f"{SPARKLE}version") for item in items], ["162", "161", "150", "140"]
        )

    def test_update_notes_are_plain_text_lines_marked_for_sparkle(self):
        items = self.publish("1.1.0", "140", notes="翻译 <选中> 的文字\n\n保留 & 恢复\n")

        description = items[0].find("description")
        self.assertEqual(description.text, "翻译 <选中> 的文字\n保留 & 恢复")
        self.assertEqual(description.get(f"{SPARKLE}format"), "plain-text")
        self.assertIn(
            "&lt;选中&gt;", self.feed.read_text(encoding="utf-8"), "The feed escapes the text as XML"
        )

    def test_an_item_without_notes_has_no_description(self):
        items = self.publish("1.1.0", "140")

        self.assertIsNone(items[0].find("description"))


if __name__ == "__main__":
    unittest.main()
