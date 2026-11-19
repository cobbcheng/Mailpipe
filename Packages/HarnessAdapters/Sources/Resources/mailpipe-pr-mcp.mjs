// A single-resource MCP server. The host supplies the resource; tool calls take no URL or command.
import {createInterface} from 'node:readline';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {existsSync} from 'node:fs';

const [target, access] = process.argv.slice(2);
const match = /^https:\/\/github\.com\/([A-Za-z0-9-]+)\/([A-Za-z0-9_.-]+)\/pull\/([1-9][0-9]*)$/.exec(target);
if (!match || ['.', '..'].includes(match[2])) process.exit(2);
const endpoint = `repos/${match[1]}/${match[2]}/pulls/${match[3]}/files?per_page=30`;
const tool = {name: 'read_pr_diff', description: 'Read changed filenames and patch hunks from the GitHub pull request linked in this email. An unavailable or partial result must be reported as such.',
  inputSchema: {type: 'object', properties: {}, additionalProperties: false}, annotations: {readOnlyHint: true}};
async function readDiff() {
  let files;
  if (access === 'confirmed') {
    const gh = ['/opt/homebrew/bin/gh', '/usr/local/bin/gh'].find(existsSync);
    if (!gh) throw Error('GitHub CLI unavailable');
    const {stdout} = await promisify(execFile)(gh, ['api', '--hostname', 'github.com', endpoint], {timeout: 15000, maxBuffer: 2097152});
    files = JSON.parse(stdout);
  } else {
    const res = await fetch('https://api.github.com/' + endpoint, {redirect: 'error', signal: AbortSignal.timeout(15000)});
    if (!res.ok) throw Error('PR unavailable');
    const reader = res.body.getReader();
    const chunks = [];
    let bytes = 0;
    for (;;) {
      const {value, done} = await reader.read();
      if (done) break;
      bytes += value.length;
      if (bytes > 2097152) { await reader.cancel(); throw Error('response too large'); }
      chunks.push(value);
    }
    files = JSON.parse(Buffer.concat(chunks).toString());
  }
  let budget = 32000;
  const changes = files.map(file => {
    const patch = (file.patch ?? '').slice(0, budget);
    budget -= patch.length;
    return {file: file.filename, patch, incomplete: !patch || patch.length !== file.patch.length};
  });
  const receipt = changes.some(change => change.patch.length > 0) ? 'MAILPIPE_PR_PATCH_READ' : 'MAILPIPE_PR_NO_PATCH';
  return receipt + '\n' + JSON.stringify({target, possiblyMoreFiles: files.length === 30, changes});
}
for await (const line of createInterface({input: process.stdin})) {
  let r;
  try { r = JSON.parse(line); } catch { continue; }
  if (r.id == null) continue;
  let result, error;
  if (r.method === 'initialize') result = {protocolVersion: '2025-11-25', capabilities: {tools: {}}, serverInfo: {name: 'mailpipe-pr', version: '1'}};
  else if (r.method === 'ping') result = {};
  else if (r.method === 'tools/list') result = {tools: [tool]};
  else if (r.method === 'tools/call' && r.params?.name === tool.name && Object.keys(r.params.arguments ?? {}).length === 0) {
    try { result = {content: [{type: 'text', text: await readDiff()}]}; }
    catch { result = {content: [{type: 'text', text: 'PR diff unavailable. State that the changes could not be verified.'}], isError: true}; }
  } else error = {code: -32601, message: 'Unsupported request'};
  console.log(JSON.stringify({jsonrpc: '2.0', id: r.id, ...(error ? {error} : {result})}));
}
