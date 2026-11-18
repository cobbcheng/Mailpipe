const origin = "https://mailpipeai.com";
const title = "Mailpipe · 给 Apple Mail 的回复工作台";
const description = "在 Mac 菜单栏查看待回复来信，对照原文修改草稿，再复制回 Apple Mail 发送。你决定处理哪些账户，以及何时暂停。";

function homepage() {
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title><meta name="description" content="${description}">
<link rel="canonical" href="${origin}/"><link rel="icon" href="/icon.png"><link rel="stylesheet" href="/site.css">
<meta property="og:type" content="website"><meta property="og:locale" content="zh_CN"><meta property="og:title" content="${title}"><meta property="og:description" content="${description}"><meta property="og:url" content="${origin}/"><meta property="og:image" content="${origin}/detail.jpg"><meta name="twitter:card" content="summary_large_image">
</head><body><header><a class="brand" href="/"><img src="/icon.png" width="38" height="38" alt="">Mailpipe</a><nav aria-label="主导航"><a href="#workbench">工作台</a><a href="#release">下载</a></nav></header>
<main><section class="hero"><div><p class="eyebrow">APPLE MAIL 的菜单栏伴侣</p><h1>来信有了下文。</h1><p class="intro">打开菜单栏，找到需要回复的来信。<br>对照原文，把第一稿改成自己的话。</p><a class="button" href="#workbench">看看工作台 <span aria-hidden="true">↓</span></a></div>
<figure class="stage"><img src="/detail.jpg" alt="Mailpipe 的草稿详情窗口，左侧为合成来信列表，右侧展示原文、回复编辑器和复制按钮。" fetchpriority="high"></figure></section>
<section id="workbench" class="feature"><div><p class="eyebrow">回复工作台</p><h2>该回的邮件，<br>放在一起。</h2><p>从待处理列表选一封来信。原文和回复在同一个窗口，改稿时随时回看对方怎么说。</p></div><figure><img loading="lazy" src="/workbench.jpg" alt="运行中的原生工作台，侧边栏列出设计评审、手册页数和校对稿三封合成来信。"></figure></section>
<section class="notes"><article><h3>保留自己的措辞</h3><p>编辑会保存。重新生成后，可以采用候选稿，也可以保留手上的版本。</p></article><article><h3>选择处理范围</h3><p>按账户选择收件箱，或逐封确认交给模型的内容。需要安静时，在设置里暂停新任务。</p></article><article><h3>亲手发出最后一稿</h3><p>确认事实，复制回复，再到 Apple Mail 粘贴发送。带有待补充内容的草稿会提醒你核对。</p></article></section>
<section id="release"><p class="eyebrow">MACOS 下载</p><h2>公开安装包尚在准备中。</h2><p>通过 Developer ID 签名和 Apple 公证的 DMG 准备好后，将在这里提供下载。</p></section></main>
<footer><a class="brand" href="/">Mailpipe</a><span>为 Apple Mail 而作</span></footer></body></html>`;
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
