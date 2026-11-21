"""Verify the deliverable, not just the values passed to xcodebuild."""
import plistlib
import re
import subprocess
import sys
from pathlib import Path

app, version, build = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
team = sys.argv[4] if len(sys.argv) == 5 else None
host = app / "Contents"
plugin = host / "PlugIns/MailpipeMailExtension.appex/Contents"
for root, identifier in [(host, "com.mailpipe.app"), (plugin, "com.mailpipe.app.MailExtension")]:
    info = plistlib.loads((root / "Info.plist").read_bytes())
    actual = (info["CFBundleIdentifier"], info["CFBundleShortVersionString"], info["CFBundleVersion"])
    if actual != (identifier, version, build):
        sys.exit(f"{identifier}: unexpected bundle ID or versions: {actual}")
    arches = subprocess.check_output(["lipo", "-archs", root / "MacOS" / info["CFBundleExecutable"]], text=True).split()
    if not {"arm64", "x86_64"} <= set(arches):
        sys.exit(f"{identifier}: missing universal slice: {arches}")
    if team:
        # Verify the expected Developer ID distribution signature, timestamp, runtime and App Group.
        raw = subprocess.check_output(["codesign", "-dv", "--verbose=4", root.parent], stderr=subprocess.STDOUT).decode()
        for pattern in ["^Authority=Developer ID Application:", "^TeamIdentifier=" + re.escape(team) + "$",
                        "^Timestamp=", "flags=.*\\bruntime\\b"]:
            if not re.search(pattern, raw, re.MULTILINE):
                sys.exit(f"{identifier}: release signature does not match {pattern}")
        ent = plistlib.loads(subprocess.check_output(["codesign", "-d", "--entitlements", "-", "--xml", root.parent]))
        required = "com.apple.security.app-sandbox" if root == plugin else "com.apple.security.automation.apple-events"
        if (ent.get("com.apple.security.application-groups") != [team + ".com.mailpipe.validation"]
                or not ent.get(required) or ent.get("com.apple.security.get-task-allow")):
            sys.exit(f"{identifier}: unexpected signing entitlements")
print(f"Verified universal host and extension {version} ({build})")
