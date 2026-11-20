// Copied to the Pages output as _worker.js. Only release packages under downloads/
// are addressable; the bucket itself stays private.
export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (!path.startsWith('/downloads/')) return env.ASSETS.fetch(request);
    if (!['GET', 'HEAD'].includes(request.method)) {
      return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
    }
    const filename = path.slice('/downloads/'.length);
    const legacyDMG = filename === 'Mailpipe-0.0.1-build18-77be446.dmg';
    if (!legacyDMG && !/^[A-Za-z0-9][A-Za-z0-9._-]*\.zip$/.test(filename)) return new Response(null, { status: 404 });
    const key = 'downloads/' + filename;
    const object = request.method === 'HEAD' ? await env.RELEASES.head(key) : await env.RELEASES.get(key);
    if (!object) return new Response(null, { status: 404 });
    return new Response(request.method === 'HEAD' ? null : object.body, {
      headers: {
        'Content-Type': legacyDMG ? 'application/x-apple-diskimage' : 'application/zip',
        'Content-Disposition': `attachment; filename="${filename}"`,
        'Content-Length': String(object.size),
        'ETag': object.httpEtag,
        'X-Content-Type-Options': 'nosniff',
      },
    });
  },
};
