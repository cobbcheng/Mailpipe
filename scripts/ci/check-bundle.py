"""Verify the deliverable, not just the values passed to xcodebuild."""
import plistlib
import re
import subprocess
import sys
from pathlib import Path

app, version, build = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
team = sys.argv[4] if len(sys.argv) == 5 else None


def check_code(binary):
    arches = subprocess.check_output(["lipo", "-archs", binary], text=True).split()
    if not {"arm64", "x86_64"} <= set(arches):
        sys.exit(f"{binary.name}: missing universal slice: {arches}")
    if team:
        raw = subprocess.check_output(["codesign", "-dv", "--verbose=4", binary], stderr=subprocess.STDOUT).decode()
        for pattern in ["^Authority=Developer ID Application:", "^TeamIdentifier=" + re.escape(team) + "$",
                        "^Timestamp=", r"flags=.*\bruntime\b"]:
            if not re.search(pattern, raw, re.MULTILINE):
                sys.exit(f"{binary.name}: unexpected Developer ID signature, team, timestamp or hardened runtime")


host = app / "Contents"
plugin = host / "PlugIns/MailpipeMailExtension.appex/Contents"
for root, identifier in [(host, "com.mailpipe.app"), (plugin, "com.mailpipe.app.MailExtension")]:
    info = plistlib.loads((root / "Info.plist").read_bytes())
    actual = (info["CFBundleIdentifier"], info["CFBundleShortVersionString"], info["CFBundleVersion"])
    if actual != (identifier, version, build):
        sys.exit(f"{identifier}: unexpected bundle ID or versions: {actual}")
    check_code(root / "MacOS" / info["CFBundleExecutable"])
    if team:
        ent = plistlib.loads(subprocess.check_output(["codesign", "-d", "--entitlements", "-", "--xml", root.parent]))
        required = "com.apple.security.app-sandbox" if root == plugin else "com.apple.security.automation.apple-events"
        if (ent.get("com.apple.security.application-groups") != [team + ".com.mailpipe.validation"]
                or not ent.get(required) or ent.get("com.apple.security.get-task-allow")):
            sys.exit(f"{identifier}: unexpected signing entitlements")

# A valid signature on the outer bundle doesn't prove its updater's helpers have
# our Developer ID. Verify exactly the components trusted to install updates.
frameworks = host / "Frameworks"
sparkle = frameworks / "Sparkle.framework/Versions/Current"
for binary in [frameworks / "Lottie.framework/Lottie", sparkle / "Sparkle", sparkle / "Autoupdate",
               sparkle / "Updater.app/Contents/MacOS/Updater",
               sparkle / "XPCServices/Installer.xpc/Contents/MacOS/Installer",
               sparkle / "XPCServices/Downloader.xpc/Contents/MacOS/Downloader"]:
    check_code(binary)
print(f"Verified universal host, extension, frameworks and updater helpers for {version} ({build})")
