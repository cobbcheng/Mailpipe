import { mkdir, cp, writeFile, readFile } from 'node:fs/promises';
import { createHash, createPublicKey, verify } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { resolve, join } from 'node:path';
import { render } from './worker.mjs';
import { release as publishedRelease } from './release.mjs';
import { appcast, feedURL, predatesUpdater } from './appcast.mjs';

const [source, destination, metadata] = process.argv.slice(2);
if (!source || !destination) throw new Error('Usage: node build-pages.mjs <release.zip> <new-output-dir> [release.json]');
const release = metadata ? JSON.parse(await readFile(metadata, 'utf8')) : publishedRelease;
const bytes = await readFile(source);
if (bytes.length !== release.bytes || createHash('sha256').update(bytes).digest('hex') !== release.sha256) {
  throw new Error('Release ZIP does not match the published size and SHA-256');
}
const feed = appcast(release);
if (!predatesUpdater(release)) {
  const publicKeyText = execFileSync('python3', [
    fileURLToPath(new URL('./release-public-key.py', import.meta.url)),
    fileURLToPath(new URL('../Mailpipe/App/Info.plist', import.meta.url)),
    release.version, String(release.build), release.minimumSystemVersion, feedURL,
  ], { input: bytes, encoding: 'utf8' }).trim();
  const rawKey = Buffer.from(publicKeyText, 'base64');
  if (rawKey.length !== 32 || rawKey.toString('base64') !== publicKeyText) {
    throw new Error('Invalid SUPublicEDKey in the host Info.plist');
  }
  const publicKey = createPublicKey({
    format: 'jwk', key: { kty: 'OKP', crv: 'Ed25519', x: rawKey.toString('base64url') },
  });
  if (!verify(null, bytes, publicKey, Buffer.from(release.edSignature, 'base64'))) {
    throw new Error('Release ZIP failed Sparkle Ed25519 signature verification');
  }
}
const out = resolve(destination);
await mkdir(out); // Refuse an existing directory rather than publish stale assets.
await cp(fileURLToPath(new URL('./public/', import.meta.url)), out, {recursive:true});
await writeFile(join(out, 'appcast.xml'), feed);
for (const [route,file] of [['/','index.html'],['/zh/','zh/index.html'],['/es/','es/index.html'],['/robots.txt','robots.txt'],['/sitemap.xml','sitemap.xml']]) {
  await mkdir(resolve(out,file,".."),{recursive:true});
  await writeFile(join(out,file), await render(new Request('https://mailpipeai.com'+route), {}, release).text());
}
await cp(fileURLToPath(new URL('./downloads.mjs', import.meta.url)), join(out, '_worker.js'));
await writeFile(join(out, '_routes.json'), JSON.stringify({ version: 1, include: ['/downloads/*'], exclude: [] }));
await writeFile(join(out,'404.html'),'<!doctype html><html lang="en"><meta charset="utf-8"><title>Page not found</title><p>Page not found. <a href="/">Return to Mailpipe</a></p></html>');
await writeFile(join(out,'_headers'), '/*\n  X-Content-Type-Options: nosniff\n/appcast.xml\n  Content-Type: application/xml; charset=utf-8\n  Cache-Control: no-cache\n');
