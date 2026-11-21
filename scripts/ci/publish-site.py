#!/usr/bin/env python3
"""Prepare a verified site offline; publish only from the production CI job."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import time
import urllib.request
from urllib.error import URLError
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SITE = ROOT / "website"
ORIGIN = "https://mailpipeai.com"
PROJECT = "mailpipe-official"
NAME = re.compile(r"Mailpipe-(\d+\.\d+\.\d+)-build([1-9]\d*)-([0-9a-f]{7})\.zip")
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
MAX_ZIP = 256 * 1024 * 1024
USER_AGENT = "Mailpipe-Release-CI/1.0"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        # Keep production probes on the expected host and never forward the API token.
        return None


HTTP = urllib.request.build_opener(NoRedirect())


def check(ok, message):
    if not ok:
        raise ValueError(message)


def metadata(archive, signature):
    match = NAME.fullmatch(archive.name)
    check(match, "Unexpected archive filename")
    with zipfile.ZipFile(archive) as z:
        app = plistlib.loads(z.read("Mailpipe.app/Contents/Info.plist"))
    version, build = app["CFBundleShortVersionString"], app["CFBundleVersion"]
    check((version, build) == match.groups()[:2], "Archive name disagrees with packaged plist")
    system = app["LSMinimumSystemVersion"].split(".")
    check(1 <= len(system) <= 3 and all(s.isdecimal() for s in system), "Invalid minimum macOS")
    check(re.fullmatch(r"[A-Za-z0-9+/]{86}==", signature), "Expected a standalone public Ed25519 signature")
    return dict(version=version, build=int(build), filename=archive.name, bytes=archive.stat().st_size,
                sha256=hashlib.sha256(archive.read_bytes()).hexdigest(), edSignature=signature,
                minimumSystemVersion=".".join(system + ["0"] * (3 - len(system))))


def build(archive, signature, out):
    release = metadata(archive, signature)
    with tempfile.TemporaryDirectory() as d:
        config = Path(d, "release.json")
        config.write_text(json.dumps(release))
        # Existing builder checks host, extension, trusted updater key, URL, minimum OS,
        # SHA-256, byte length and Ed25519 on exactly the final notarized ZIP.
        subprocess.run(["node", SITE / "build-pages.mjs", archive, out, config], check=True,
                       env={k: os.environ[k] for k in ("PATH", "HOME")})
    return release


def parse_feed(xml):
    items = ET.fromstring(xml).findall("./channel/item")
    check(len(items) == 1, "Expected one production release in appcast")
    item = items[0]
    enc = item.find("enclosure")
    check(enc is not None, "Missing enclosure")
    url = enc.attrib["url"]
    filename = url.split("/")[-1]
    m = NAME.fullmatch(filename)
    check(m and url == ORIGIN + "/downloads/" + filename, "Unexpected appcast download URL")
    check(item.findtext(SPARKLE + "shortVersionString") == m[1] and
          item.findtext(SPARKLE + "version") == m[2], "Inconsistent feed release identity")
    return filename, int(m[2]), int(enc.attrib["length"]), enc.attrib[SPARKLE + "edSignature"]


def read_public(path, maximum=2 * 1024 * 1024, method="GET"):
    # Unique query avoids stale negative cache entries for freshly added R2 keys.
    url = ORIGIN + path + "?ci-check=" + str(time.time_ns())
    request = urllib.request.Request(url, method=method, headers={"Cache-Control": "no-cache", "User-Agent": USER_AGENT})
    with HTTP.open(request, timeout=60) as response:
        check(response.geturl() == url and response.status == 200, "Unexpected public response: " + path)
        if method == "HEAD":
            return int(response.headers["Content-Length"])
        data = response.read(maximum + 1)
        check(len(data) <= maximum, "Oversize public response: " + path)
        return data


def verify(archive, out):
    feed = (out / "appcast.xml").read_bytes()
    check(feed == read_public("/appcast.xml"), "Public appcast does not match the verified build")
    name, _, size, _ = parse_feed(feed)
    check(name == archive.name and size == archive.stat().st_size, "Unexpected ZIP or size")
    path = "/downloads/" + name
    check(read_public(path, method="HEAD") == size, "Public ZIP length mismatch")
    check(read_public(path, maximum=min(MAX_ZIP, size)) == archive.read_bytes(), "Public ZIP differs")
    for route, language in [("/", "en"), ("/zh/", "zh-CN"), ("/es/", "es")]:
        # Cloudflare can transform email links and inject analytics; check semantic markers.
        html = read_public(route).decode()
        for marker in [f'<html lang="{language}">', f'href="{path}"',
                       f'<link rel="canonical" href="{ORIGIN}{route}">',
                       f'"downloadUrl":"{ORIGIN}{path}"', 'application/ld+json']:
            check(marker in html, "Missing " + marker + " on " + route)
    check((ORIGIN + "/sitemap.xml").encode() in read_public("/robots.txt"), "robots.txt omits sitemap")
    check(read_public("/sitemap.xml") == (out / "sitemap.xml").read_bytes(), "Public sitemap differs")
    check(read_public("/site.css") == (out / "site.css").read_bytes(), "Public CSS differs")


def probe(commit):
    """No credentials or local artifacts: independently verify a previously live release."""
    check(re.fullmatch(r"[0-9a-f]{7}([0-9a-f]{33})?", commit), "Expected a Git commit")
    name, _, size, signature = parse_feed(read_public("/appcast.xml"))
    check(NAME.fullmatch(name)[3] == commit[:7], "Production does not serve this commit")
    with tempfile.TemporaryDirectory() as d:
        archive, out = Path(d, name), Path(d, "pages")
        archive.write_bytes(read_public("/downloads/" + name, maximum=min(size, MAX_ZIP)))
        build(archive, signature, out)
        verify(archive, out)


def check_binding(account, bucket, token):
    url = f"https://api.cloudflare.com/client/v4/accounts/{account}/pages/projects/{PROJECT}"
    request = urllib.request.Request(url, headers={"Authorization": "Bearer " + token, "User-Agent": USER_AGENT})
    with HTTP.open(request, timeout=30) as response:
        project = json.load(response)["result"]
    check(project["name"] == PROJECT and project["production_branch"] == "main",
          "Pages project/production branch mismatch")
    binding = project["deployment_configs"]["production"]["r2_buckets"]["RELEASES"]
    check(binding["name"] == bucket, "Production RELEASES binding is not the configured bucket")
    jurisdiction = binding.get("jurisdiction", "default") or "default"
    check(jurisdiction in ("default", "eu", "fedramp"), "Unknown R2 bucket jurisdiction")
    return "" if jurisdiction == "default" else "." + jurisdiction


def publish_archive(archive, bucket, endpoint, d):
    # Scope R2 credentials to the S3 process; do not pass Pages or signing tokens.
    env = {k: os.environ[k] for k in ("PATH", "HOME", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY")}
    env.update(AWS_EC2_METADATA_DISABLED="true", AWS_REGION="auto", AWS_PAGER="",
               AWS_REQUEST_CHECKSUM_CALCULATION="when_required")
    aws = ["aws", "--endpoint-url", endpoint, "s3api"]
    obj = ["--bucket", bucket, "--key", "downloads/" + archive.name]
    put = subprocess.run(aws + ["put-object", *obj, "--body", str(archive), "--if-none-match", "*",
                                "--content-type", "application/zip"], env=env, capture_output=True)
    if put.returncode and b"(PreconditionFailed)" not in put.stderr and b"(412)" not in put.stderr:
        raise ValueError("Conditional R2 upload failed; inspect credentials, bucket and aws CLI v2")
    # A 412 permits only an exact previous copy. Never replace or delete a release key.
    downloaded = Path(d, "r2-readback.zip")
    subprocess.run(aws + ["get-object", *obj, str(downloaded)], env=env, stdout=subprocess.DEVNULL, check=True)
    check(downloaded.read_bytes() == archive.read_bytes(), "Immutable R2 key contains different bytes")


def deploy(archive, out):
    e = os.environ
    check(e.get("GITHUB_ACTIONS") == "true" and e.get("GITHUB_EVENT_NAME") == "push" and
          e.get("GITHUB_REF") == "refs/heads/main" and e.get("GITHUB_REPOSITORY", "").lower() == "cobbcheng/mailpipe",
          "Only the upstream main push production job may deploy")
    commit, account, bucket = e["GITHUB_SHA"], e["CLOUDFLARE_ACCOUNT_ID"], e["MAILPIPE_RELEASE_BUCKET"]
    check(re.fullmatch(r"[0-9a-f]{32}", account), "Invalid Cloudflare account ID")
    feed = (out / "appcast.xml").read_bytes()
    name, candidate, size, signature = parse_feed(feed)
    check(name == archive.name and NAME.fullmatch(name)[3] == commit[:7] and size == archive.stat().st_size,
          "Release artifact does not match this push")
    old_name, previous, old_size, _ = parse_feed(read_public("/appcast.xml"))
    if candidate == previous and name == old_name:
        # Deployment already took effect. Do not retry the write.
        verify(archive, out)
        return
    check(candidate > previous, "Refusing a stale or conflicting release")
    check(read_public("/downloads/" + old_name, method="HEAD") == old_size, "Current download unhealthy")
    wrangler = SITE / "ci-tools/node_modules/.bin/wrangler"
    check(wrangler.is_file(), "Install pinned Wrangler using npm ci --prefix website/ci-tools first")
    token = e["CLOUDFLARE_API_TOKEN"]
    suffix = check_binding(account, bucket, token)
    with tempfile.TemporaryDirectory() as d:
        # Verify the exact bytes again before any write. Deploy only freshly rendered
        # output, never additional files from an input artifact or the repository root.
        fresh = Path(d, "pages")
        build(archive, signature, fresh)
        check(feed == (fresh / "appcast.xml").read_bytes(), "Regenerated feed differs")
        publish_archive(archive, bucket, f"https://{account}{suffix}.r2.cloudflarestorage.com", d)
        # Existing Pages config/binding, no creation or mutation of projects, buckets or DNS.
        env = {k: e[k] for k in ("PATH", "HOME", "CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ACCOUNT_ID")}
        env.update(CI="true", WRANGLER_SEND_METRICS="false")
        subprocess.run([wrangler, "pages", "deploy", fresh, "--project-name", PROJECT, "--branch", "main",
                        "--commit-hash", commit], cwd=d, env=env, check=True)
        # Retry read-only probes during edge propagation. Never re-submit a deployment.
        for attempt in range(6):
            try:
                verify(archive, fresh)
                check(read_public("/downloads/" + old_name, method="HEAD") == old_size,
                      "Previous release route no longer works")
                return
            except (ValueError, URLError) as exc:
                if attempt == 5:
                    raise
                print(f"Public readback pending ({exc}); checking again in 10s", flush=True)
                time.sleep(10)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    commands = p.add_subparsers(dest="command", required=True)
    for cmd in ("build", "deploy", "verify"):
        sub = commands.add_parser(cmd)
        sub.add_argument("archive", type=Path)
        if cmd == "build":
            sub.add_argument("signature", type=Path)
        sub.add_argument("output", type=Path)
    commands.add_parser("probe").add_argument("commit")
    args = p.parse_args()
    if args.command == "probe":
        probe(args.commit)
    elif args.command == "build":
        print(json.dumps(build(args.archive, args.signature.read_text().strip(), args.output), indent=2))
    else:
        {"deploy": deploy, "verify": verify}[args.command](args.archive.resolve(), args.output.resolve())


if __name__ == "__main__":
    main()
