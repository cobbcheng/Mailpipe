// Application-owned classification boundary; never reads credentials or mail.
export const inject = ['tools', 'llm'];
export function apply(ctx) {
  let requests = 0;
  ctx.tools.guard(() => 'Mailpipe classification denies all tools');
  ctx.on('llm/stream', async function* (options, next) {
    const registry = ctx.tools.definitions().map(tool => tool.name);
    const advertised = (options.tools ?? []).map(tool => tool.name);
    if (++requests !== 1 || registry.length || advertised.length ||
        options.provider !== 'deepseek-official' || options.model !== 'deepseek-flash') {
      throw new Error('Mailpipe unexpected model request or tool exposure');
    }
    process.stdout.write(JSON.stringify({type: 'mailpipe_safety', registry, advertised,
      provider: options.provider, model: options.model}) + '\n');
    yield* next();
  });
  ctx.provide('mailpipeAudit', true);
}
