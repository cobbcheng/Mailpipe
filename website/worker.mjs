const origin = "https://mailpipeai.com";
const slogan = "让你的 Agent，帮你回邮件";
const title = `Mailpipe · ${slogan}`;
const description = "Mailpipe 在你的 Mac 上保存来信和草稿。你授权的来信只交给你接入的 Agent 起草回复，由你在 Apple Mail 中审阅、发送。当前支持的 DeepSeek Harness 会调用 DeepSeek 云端模型。";

function homepage() {
  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title>
<meta name="description" content="${description}">
<link rel="canonical" href="${origin}/">
<link rel="icon" href="/icon.png">
<link rel="preload" href="/fonts/InterDisplay-SemiBold.woff2" as="font" type="font/woff2" crossorigin>
<link rel="preload" href="/fonts/Inter-Medium.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="/site.css">
<meta property="og:type" content="website">
<meta property="og:locale" content="zh_CN">
<meta property="og:title" content="${title}">
<meta property="og:description" content="${description}">
<meta property="og:url" content="${origin}/">
<meta property="og:image" content="${origin}/detail.jpg">
<meta name="twitter:card" content="summary_large_image">
</head>
<body>
<a class="skip" href="#content">跳到主要内容</a>
<header class="site-header">
  <div class="rails">
    <a class="brand" href="/"><img src="/icon.png" width="28" height="28" alt="">Mailpipe</a>
    <nav aria-label="主导航"><a href="#workbench">工作台</a><a href="#release">下载</a></nav>
  </div>
</header>
<main id="content">
  <section class="hero" aria-labelledby="hero-title">
    <div class="rails hero-stack">
      <div class="hero-copy">
        <p class="pill"><span class="pill-mark" aria-hidden="true"></span>适用于 Mac 上的 Apple Mail</p>
        <h1 id="hero-title">${slogan}</h1>
        <p class="lead">来信和草稿保存在你的 Mac 上。<br>Mailpipe 只把你授权的来信交给你的 Agent 起草回复，<br>最后由你在 Apple Mail 发送。</p>
        <div class="actions">
          <a class="button button-secondary" href="#workbench">看看回复草稿</a>
          <a class="button button-primary" href="#release">下载</a>
        </div>
        <p class="note">版本 0.0.3 · build 25 · 已通过 Apple 公证。</p>
      </div>
      <figure class="showcase">
        <div class="app-window">
          <img src="/detail.jpg" width="2120" height="1480" alt="示例来信询问项目进度。下方的回复草稿留下了待补充的进展和待确认的发布条件。" fetchpriority="high">
        </div>
      </figure>
    </div>
  </section>
  <section id="workbench" class="band">
    <div class="rails">
      <div class="band-body feature">
        <div class="stack">
          <p class="kicker">菜单栏工作台</p>
          <h2>Agent 写初稿，<br>你来定稿</h2>
          <p>从菜单栏打开一封来信，就能对照原文修改回复。补上只有你知道的细节，改成自己平常会说的话。</p>
        </div>
        <figure>
          <img loading="lazy" src="/workbench.jpg" width="2120" height="1480" alt="工作台里的三封示例来信，分别讨论设计评审、展览手册和校对稿。">
        </figure>
      </div>
    </div>
  </section>
  <section class="band" aria-label="关于 Agent 和邮件隐私的常见问题">
    <div class="rails">
      <div class="band-body notes">
        <article>
          <h3>哪些来信交给 Agent？</h3>
          <p>你可以授权自动处理所有账户今后的新邮件，也可以按主题限定范围。想逐封决定，就手动粘贴主题和正文，确认后再交给 Agent。</p>
        </article>
        <article>
          <h3>邮件内容会去哪儿？</h3>
          <p>邮件不经过 Mailpipe 的服务器。当前支持的 Agent 是你 Mac 上的 DeepSeek Harness，它会把授权的主题和正文发给 DeepSeek 云端模型。</p>
        </article>
        <article>
          <h3>谁来发送回复？</h3>
          <p>由你发送。在工作台改好草稿后，到 Apple Mail 的撰写窗口核对收件人和正文，再点发送。你也可以只复制回复。</p>
        </article>
      </div>
    </div>
  </section>
  <section id="release" class="band">
    <div class="rails">
      <div class="band-body stack release-copy">
        <h2>下载 Mac 版 Mailpipe</h2>
        <p>版本 0.0.3（build 25），7.06 MB。解压后将 Mailpipe 拖入「应用程序」。App 已通过 Developer ID 签名和 Apple 公证。</p>
        <p><a class="button button-primary" download href="/downloads/Mailpipe-0.0.3-build25-b7a83cc.zip">下载 macOS 安装包</a></p>
      </div>
    </div>
  </section>
</main>
<footer class="site-footer">
  <div class="rails">
    <a class="brand" href="/">Mailpipe</a>
    <span>Apple Mail 回复助手</span>
  </div>
</footer>
</body>
</html>`;
}

export default {
  fetch(request) {
    const path = new URL(request.url).pathname;
    if (!["GET", "HEAD"].includes(request.method)) {
      return new Response(null, { status: 405, headers: { Allow: "GET, HEAD" } });
    }
    const routes = {
      "/": ["text/html", homepage],
      "/robots.txt": ["text/plain", () => `User-agent: *\nAllow: /\nSitemap: ${origin}/sitemap.xml\n`],
      "/sitemap.xml": ["application/xml", () => `<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>${origin}/</loc></url></urlset>`]
    };
    const route = routes[path];
    if (!route) return new Response("页面不存在", { status: 404 });
    return new Response(request.method === "HEAD" ? null : route[1](), {
      headers: { "Content-Type": route[0] + "; charset=utf-8", "X-Content-Type-Options": "nosniff" }
    });
  }
};
