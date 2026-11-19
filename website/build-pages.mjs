import { mkdir, cp, writeFile, readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { resolve, join } from 'node:path';
import worker from './worker.mjs';

const [source, destination] = process.argv.slice(2);
if (!source || !destination) throw new Error('Usage: node build-pages.mjs <release.zip> <new-output-dir>');
const name = 'Mailpipe-0.0.3-build25-b7a83cc.zip';
const sha = 'cbdc8b0d5d16d154258bd2e396d7fc117e27da1d32e4be118a307b27378821dd';
const bytes = await readFile(source);
if (createHash('sha256').update(bytes).digest('hex') !== sha) throw new Error('Unexpected release SHA-256');
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
