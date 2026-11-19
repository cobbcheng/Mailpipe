import { mkdir, cp, writeFile, readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { resolve, join } from 'node:path';
import worker from './worker.mjs';
import { release } from './release.mjs';

const [source, destination] = process.argv.slice(2);
if (!source || !destination) throw new Error('Usage: node build-pages.mjs <release.zip> <new-output-dir>');
const name = release.filename;
const bytes = await readFile(source);
if (bytes.length !== release.bytes || createHash('sha256').update(bytes).digest('hex') !== release.sha256) {
  throw new Error('Release ZIP does not match the published size and SHA-256');
}
const out = resolve(destination);
await mkdir(out); // Refuse an existing directory rather than publish stale assets.
await cp(fileURLToPath(new URL('./public/', import.meta.url)), out, {recursive:true});
for (const [route,file] of [['/','index.html'],['/robots.txt','robots.txt'],['/sitemap.xml','sitemap.xml']]) {
  await writeFile(join(out,file), await worker.fetch(new Request('https://mailpipeai.com'+route)).text());
}
await mkdir(join(out,'downloads'));
await writeFile(join(out,'downloads',name),bytes);
await writeFile(join(out,'404.html'),'<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>页面不存在</title><p>页面不存在。<a href="/">返回 Mailpipe 官网</a></p></html>');
await writeFile(join(out,'_headers'), '/*\n  X-Content-Type-Options: nosniff\n/downloads/'+name+'\n  Content-Type: application/zip\n  Content-Disposition: attachment; filename="'+name+'"\n');
