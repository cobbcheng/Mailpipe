const origin = "https://mailpipeai.com";
const title = "Mailpipe · 给 Apple Mail 的回复工作台";
const description = "在 Mac 菜单栏查看待回复来信，对照原文修改草稿，再复制回 Apple Mail 发送。你决定处理哪些账户，以及何时暂停。";

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
        <p class="pill"><span class="pill-mark" aria-hidden="true"></span>APPLE MAIL 的菜单栏伴侣</p>
        <h1 id="hero-title">来信有了下文。</h1>
        <p class="lead">打开菜单栏，找到需要回复的来信。<br>对照原文，把第一稿改成自己的话。</p>
        <div class="actions">
          <a class="button button-secondary" href="#workbench">看看工作台</a>
          <a class="button button-primary" href="#release">下载</a>
        </div>
        <p class="note">版本 0.0.3 · build 25 · 已通过 Apple 公证。</p>
      </div>
      <figure class="showcase">
        <div class="app-window">
          <img src="/detail.jpg" width="2120" height="1480" alt="Mailpipe 的草稿详情窗口，左侧为合成来信列表，右侧展示原文、回复编辑器和复制按钮。" fetchpriority="high">
        </div>
      </figure>
    </div>
  </section>
  <section id="workbench" class="band">
    <div class="rails">
      <div class="band-body feature">
        <div class="stack">
          <p class="kicker">回复工作台</p>
          <h2>该回的邮件，<br>放在一起。</h2>
          <p>从待处理列表选一封来信。原文和回复在同一个窗口，改稿时随时回看对方怎么说。</p>
        </div>
        <figure>
          <img loading="lazy" src="/workbench.jpg" width="2120" height="1480" alt="运行中的原生工作台，侧边栏列出设计评审、手册页数和校对稿三封合成来信。">
        </figure>
      </div>
    </div>
  </section>
  <section class="band" aria-label="使用方式">
    <div class="rails">
      <div class="band-body notes">
        <article>
          <h3>保留自己的措辞</h3>
          <p>编辑会保存。重新生成后，可以采用候选稿，也可以保留手上的版本。</p>
        </article>
        <article>
          <h3>选择处理范围</h3>
          <p>按账户选择收件箱，或逐封确认交给模型的内容。需要安静时，在设置里暂停新任务。</p>
        </article>
        <article>
          <h3>亲手发出最后一稿</h3>
          <p>按需编辑或复制回复，再到 Apple Mail 发送。</p>
        </article>
      </div>
    </div>
  </section>
  <section id="release" class="band">
    <div class="rails">
      <div class="band-body stack release-copy">
        <p class="kicker">MACOS 下载</p>
        <h2>下载 Mailpipe for Mac</h2>
        <p>版本 0.0.3（build 25），7.06 MB。解压后将 Mailpipe 拖入「应用程序」。App 已通过 Developer ID 签名和 Apple 公证。</p>
        <p><a class="button button-primary" download href="/downloads/Mailpipe-0.0.3-build25-b7a83cc.zip">下载 macOS 安装包</a></p>
      </div>
    </div>
  </section>
</main>
<footer class="site-footer">
  <div class="rails">
    <a class="brand" href="/">Mailpipe</a>
    <span>为 Apple Mail 而作</span>
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
