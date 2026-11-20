import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { appcast, feedURL } from './appcast.mjs';

test('the unsigned build 34 publishes an empty channel', () => {
  const feed = appcast({
    version: '0.1.0', build: 34,
    sha256: 'f076181f021a75ed133f9f4c048e0463558b08c2b746b36e06ecfd36a789dbf9',
  });
  assert.match(feed, /<channel>/);
  assert.doesNotMatch(feed, /<item>/);
});

test('Pages builds a signed release and rejects a ZIP signed by another key', async t => {
  const root = await mkdtemp(join(tmpdir(), 'mailpipe-appcast-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const site = join(root, 'website');
  await mkdir(join(site, 'public'), { recursive: true });
  await mkdir(join(root, 'Mailpipe/App'), { recursive: true });
  // Exercise the real CLI with isolated metadata and plist files at its normal relative paths.
  for (const file of ['build-pages.mjs', 'appcast.mjs', 'release-public-key.py', 'worker.mjs', 'messages.mjs']) {
    await symlink(new URL(file, import.meta.url), join(site, file));
  }
  const filename = 'Mailpipe-test.zip';
  const archive = join(root, filename);
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const rawKey = Buffer.from(publicKey.export({ format: 'jwk' }).x, 'base64url').toString('base64');
  execFileSync('python3', ['-c', `
import plistlib, sys, zipfile
from pathlib import Path
root, filename, feed, public_key = sys.argv[1:]
version = {"CFBundleVersion": "35", "CFBundleShortVersionString": "0.1.1"}
app = dict(version, CFBundleIdentifier="com.mailpipe.app", SUFeedURL=feed,
           SUPublicEDKey=public_key, LSMinimumSystemVersion="13.0")
plugin = dict(version, CFBundleIdentifier="com.mailpipe.app.MailExtension")
Path(root, "Mailpipe/App/Info.plist").write_bytes(plistlib.dumps(app))
with zipfile.ZipFile(Path(root, filename), "w") as archive:
    archive.writestr("Mailpipe.app/Contents/Info.plist", plistlib.dumps(app, fmt=plistlib.FMT_BINARY))
    archive.writestr("Mailpipe.app/Contents/PlugIns/MailpipeMailExtension.appex/Contents/Info.plist",
                     plistlib.dumps(plugin))
`, root, filename, feedURL, rawKey]);
  const bytes = await readFile(archive);
  const release = {
    version: '0.1.1', build: 35, minimumSystemVersion: '13.0.0', filename,
    bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex'),
    edSignature: sign(null, bytes, privateKey).toString('base64'),
  };
  async function build(metadata, output) {
    await writeFile(join(site, 'release.mjs'), 'export const release = ' + JSON.stringify(metadata));
    execFileSync(process.execPath, [
      '--preserve-symlinks-main', '--preserve-symlinks', join(site, 'build-pages.mjs'), archive, output,
    ], { stdio: 'pipe' });
  }
  const out = join(root, 'good');
  await build(release, out);
  const feed = await readFile(join(out, 'appcast.xml'), 'utf8');
  assert.match(feed, /<sparkle:version>35<\/sparkle:version>/);
  assert.ok(feed.includes('<sparkle:shortVersionString>0.1.1</sparkle:shortVersionString>'));
  assert.ok(feed.includes('<sparkle:minimumSystemVersion>13.0.0</sparkle:minimumSystemVersion>'));
  assert.ok(feed.includes(`sparkle:edSignature="${release.edSignature}"`));
  assert.ok(feed.includes(`url="https://mailpipeai.com/downloads/${filename}" length="${bytes.length}"`));
  assert.deepEqual(await readFile(join(out, 'downloads', filename)), bytes);
  assert.ok((await readFile(join(out, 'index.html'), 'utf8')).includes(`href="/downloads/${filename}"`));

  const wrongKey = generateKeyPairSync('ed25519').privateKey;
  const bad = join(root, 'bad');
  await assert.rejects(build({ ...release, edSignature: sign(null, bytes, wrongKey).toString('base64') }, bad),
    /failed Sparkle Ed25519 signature verification/);
  await assert.rejects(readFile(join(bad, 'appcast.xml')), { code: 'ENOENT' });
});
