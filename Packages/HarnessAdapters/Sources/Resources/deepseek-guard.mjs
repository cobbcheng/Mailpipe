// Application-owned tool boundary for one mail task.
export const inject = ['tools', 'llm'];
export function apply(ctx) {
  let requests = 0;
  const allowed = process.env.MAILPIPE_PR_REVIEW === '1' ? ['mcp__mailpipe__read_pr_diff'] : [];
  ctx.tools.guard(exec => {
    const args = exec.arguments ?? {};
    if (!allowed.includes(exec.name) || typeof args !== 'object' || Array.isArray(args) || Object.keys(args).length) {
      return 'Outside the read-only scope of this Mailpipe request';
    }
  });
  ctx.on('llm/stream', async function* (options, next) {
    const registry = ctx.tools.definitions().map(tool => tool.name);
    const advertised = (options.tools ?? []).map(tool => tool.name);
    if (++requests > (allowed.length ? 3 : 1) ||
        JSON.stringify(registry) !== JSON.stringify(allowed) || JSON.stringify(advertised) !== JSON.stringify(allowed) ||
        options.provider !== 'deepseek-official' || options.model !== 'deepseek-flash') {
      throw new Error('Mailpipe unexpected model request or tool exposure');
    }
    process.stdout.write(JSON.stringify({type: 'mailpipe_safety', registry, advertised,
      provider: options.provider, model: options.model}) + '\n');
    yield* next();
  });
  ctx.provide('mailpipeAudit', true);
}
