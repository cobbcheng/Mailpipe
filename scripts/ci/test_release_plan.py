import runpy
import unittest
from pathlib import Path

plan = runpy.run_path(str(Path(__file__).with_name("release-plan.py")))["plan"]
sha = "a" * 40


def feed(build=50, version="0.2.0", commit="3427852"):
    return f"""<rss xmlns:s="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
    <s:version>{build}</s:version><s:shortVersionString>{version}</s:shortVersionString>
    <enclosure url="https://mailpipeai.com/downloads/Mailpipe-{version}-build{build}-{commit}.zip"/>
    </item></channel></rss>"""


class PlanTests(unittest.TestCase):
    def test_first_push_and_retry(self):
        for attempt in range(2):
            self.assertEqual(plan("1", sha, feed()), dict(state="new", version="0.2.1", build="51",
                             filename="Mailpipe-0.2.1-build51-aaaaaaa.zip"))
        self.assertEqual(plan("2", sha, feed(51, "0.2.1", "bbbbbbb"))["build"], "52")
        self.assertEqual(plan("1", sha, feed(51, "0.2.1", "aaaaaaa"))["state"], "published")

    def test_conflicts_and_invalid_input(self):
        for xml in [feed(51, "0.2.1"), feed(52, "0.2.2"), feed(50, "0.3.0"), "<rss/>"]:
            with self.assertRaises(ValueError):
                plan("1", sha, xml)
        with self.assertRaises(ValueError):
            plan("-1", sha, feed())
