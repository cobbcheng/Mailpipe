"""Check the packaged plists against the release metadata and return the trusted public key."""

import io
import plistlib
import sys
import zipfile

source_plist, version, build, minimum_system, feed_url = sys.argv[1:]
with open(source_plist, "rb") as source:
    trusted_key = plistlib.load(source)["SUPublicEDKey"]

with zipfile.ZipFile(io.BytesIO(sys.stdin.buffer.read())) as archive:
    host = "Mailpipe.app/Contents"
    extension = host + "/PlugIns/MailpipeMailExtension.appex/Contents"
    app = plistlib.loads(archive.read(host + "/Info.plist"))
    plugin = plistlib.loads(archive.read(extension + "/Info.plist"))

for plist, identifier in [(app, "com.mailpipe.app"), (plugin, "com.mailpipe.app.MailExtension")]:
    for key, expected in [("CFBundleIdentifier", identifier), ("CFBundleVersion", build),
                          ("CFBundleShortVersionString", version)]:
        if plist[key] != expected:
            sys.exit(f"{identifier} {key} does not match release metadata")

if app["SUPublicEDKey"] != trusted_key or app["SUFeedURL"] != feed_url:
    sys.exit("Packaged updater key or feed URL does not match the release configuration")
actual_system = app["LSMinimumSystemVersion"].split(".")
if actual_system + ["0"] * (3 - len(actual_system)) != minimum_system.split("."):
    sys.exit("Packaged minimum macOS version does not match the appcast")
print(trusted_key)
