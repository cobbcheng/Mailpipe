"""Credentialless tests. No real cloud service, account, or signing identity."""
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location("publish_site", Path(__file__).with_name("publish-site.py"))
site = importlib.util.module_from_spec(spec)
spec.loader.exec_module(site)


class PublisherTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.d = Path(temp.name)
        self.zip = self.d / "Mailpipe-0.2.1-build51-abcdef0.zip"
        with zipfile.ZipFile(self.zip, "w") as archive:
            archive.writestr("Mailpipe.app/Contents/Info.plist", plistlib.dumps(dict(
                CFBundleShortVersionString="0.2.1", CFBundleVersion="51", LSMinimumSystemVersion="13.0")))
        self.signature = "A" * 86 + "=="
        self.env = dict(PATH="/bin", HOME=str(self.d), AWS_ACCESS_KEY_ID="example",
                        AWS_SECRET_ACCESS_KEY="example", CLOUDFLARE_API_TOKEN="example-pages")

    def test_metadata_and_filename_binding(self):
        meta = site.metadata(self.zip, self.signature)
        self.assertEqual((meta["version"], meta["build"], meta["minimumSystemVersion"]), ("0.2.1", 51, "13.0.0"))
        wrong = self.zip.rename(self.d / self.zip.name.replace("51", "52"))
        with self.assertRaisesRegex(ValueError, "name disagrees"):
            site.metadata(wrong, self.signature)

    def test_untrusted_event_denied_before_network_or_subprocess(self):
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "pull_request",
                                     "GITHUB_REF": "refs/heads/main"}, clear=True):
            with self.assertRaisesRegex(ValueError, "main push"):
                site.deploy(self.zip, self.d)

    def test_release_verification_process_has_no_cloud_credentials(self):
        with patch.dict(os.environ, self.env, clear=True), patch.object(subprocess, "run") as run:
            site.build(self.zip, self.signature, self.d / "pages")
            self.assertEqual(run.call_args.kwargs["env"], {k: self.env[k] for k in ["PATH", "HOME"]})

    def test_conditional_upload_and_checked_readback(self):
        # Simulate new write, retry of same bytes and collision with different bytes.
        for status, body in [(0, self.zip.read_bytes()), (1, self.zip.read_bytes()), (1, b"another ZIP")]:
            with self.subTest(status=status, same=(body == self.zip.read_bytes())):
                calls = []

                def aws(args, **opts):
                    self.assertNotIn("CLOUDFLARE_API_TOKEN", opts["env"])
                    calls.append(args)
                    if "put-object" in args:
                        self.assertEqual(args[args.index("--if-none-match") + 1], "*")
                        return subprocess.CompletedProcess(args, status, stderr=b"(PreconditionFailed)" if status else b"")
                    self.assertIn("get-object", args)
                    Path(args[-1]).write_bytes(body)
                    return subprocess.CompletedProcess(args, 0)

                with patch.dict(os.environ, self.env, clear=True), patch.object(subprocess, "run", side_effect=aws):
                    if body == self.zip.read_bytes():
                        site.publish_archive(self.zip, "example-bucket", "https://example.invalid", self.d)
                    else:
                        with self.assertRaisesRegex(ValueError, "different bytes"):
                            site.publish_archive(self.zip, "example-bucket", "https://example.invalid", self.d)
                self.assertEqual(len(calls), 2)

    def test_upload_access_error_does_not_attempt_to_deploy(self):
        failure = subprocess.CompletedProcess([], 1, stderr=b"(AccessDenied)")
        with patch.dict(os.environ, self.env, clear=True), patch.object(subprocess, "run", return_value=failure) as run:
            with self.assertRaisesRegex(ValueError, "upload failed"):
                site.publish_archive(self.zip, "example-bucket", "https://example.invalid", self.d)
            self.assertEqual(run.call_count, 1)

    def test_binding_must_match_before_any_write(self):
        project = {"name": site.PROJECT, "production_branch": "main",
                   "deployment_configs": {"production": {"r2_buckets": {"RELEASES": {"name": "untouched"}}}}}
        with patch.object(site.HTTP, "open", return_value=io.BytesIO(json.dumps({"result": project}).encode())):
            with self.assertRaisesRegex(ValueError, "RELEASES binding"):
                site.check_binding("0" * 32, "wrong-bucket", "example")


if __name__ == "__main__":
    unittest.main()
