"""Allocate from this push-only workflow's stable run number; reject collisions with the live feed."""
import re
import sys
from pathlib import Path
from xml.etree import ElementTree as ET

BASE_BUILD = 50
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
ORIGIN = "https://mailpipeai.com/downloads/"


def plan(number, sha, xml):
    if not re.fullmatch(r"[1-9][0-9]*", number) or not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("Invalid workflow run number or Git commit")
    build = BASE_BUILD + int(number)
    version = f"0.2.{int(number)}"
    filename = f"Mailpipe-{version}-build{build}-{sha[:7]}.zip"
    items = ET.fromstring(xml).findall("./channel/item")
    if not items:
        raise ValueError("Empty production feed: refusing to bootstrap or roll back")
    latest = max(items, key=lambda item: int(item.findtext(SPARKLE + "version")))
    live_build = int(latest.findtext(SPARKLE + "version"))
    live_version = latest.findtext(SPARKLE + "shortVersionString")
    if not live_version or not re.fullmatch(r"\d+\.\d+\.\d+", live_version):
        raise ValueError("Malformed production version")
    semver = lambda s: tuple(map(int, s.split(".")))
    live, target = (live_build, semver(live_version)), (build, semver(version))
    if live[0] < target[0] and live[1] < target[1]:
        state = "new"
    elif live == target and latest.find("enclosure").get("url") == ORIGIN + filename:
        state = "published"
    else:
        raise ValueError("Newer release or conflicting version/source is already live; refusing to deploy")
    return dict(state=state, version=version, build=str(build), filename=filename)


if __name__ == "__main__":
    for key, value in plan(sys.argv[1], sys.argv[2], Path(sys.argv[3]).read_bytes()).items():
        print(f"{key}={value}")
