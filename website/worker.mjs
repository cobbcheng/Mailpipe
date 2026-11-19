import { release } from "./release.mjs";

const origin = "https://mailpipeai.com";
const slogan = "让你的 Agent，帮你回邮件";
const title = `Mailpipe · ${slogan}`;
const description = "Mailpipe 用你连接的 DeepSeek Harness 为 Apple Mail 的新来信起草回复。你可以限定邮件主题，在 Mac 上对照原文编辑草稿，再到 Apple Mail 发送。";
const downloadURL = `/downloads/${release.filename}`;
const fileSize = `${(release.bytes / 1_000_000).toFixed(2)} MB`;

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
<link rel="stylesheet" href="/site.css?v=${release.build}-footer2">
<meta property="og:type" content="website">
<meta property="og:locale" content="zh_CN">
<meta property="og:title" content="${title}">
<meta property="og:description" content="${description}">
<meta property="og:url" content="${origin}/">
<meta property="og:image" content="${origin}/detail.jpg?v=${release.build}">
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
        <p class="platform">适用于 Mac 上的 Apple Mail</p>
        <h1 id="hero-title">${slogan}</h1>
        <p class="lead">授权后，DeepSeek 会为 Apple Mail 的新来信起草回复。<br>从菜单栏打开草稿，对照原文改好，再到 Apple Mail 发送。</p>
        <div class="actions">
          <a class="button button-primary" download href="${downloadURL}">下载 Mac 版</a>
          <a class="button button-secondary" href="#workbench">看一封示例回复</a>
        </div>
      </div>
      <figure id="workbench" class="showcase">
        <div class="app-window">
          <picture>
            <source media="(max-width: 600px)" srcset="/detail-mobile.jpg?v=${release.build}" width="838" height="724">
            <img src="/detail.jpg?v=${release.build}" width="1648" height="864" alt="工作台在工作坊设备询问下方显示回复草稿，逐项回应投影转接线和两支麦克风的安排。" fetchpriority="high">
          </picture>
        </div>
        <figcaption>来信问到投影和麦克风。对照上方原文修改回复，或点圆形箭头重新起草。</figcaption>
      </figure>
    </div>
  </section>
  <section class="band" aria-labelledby="scope-title">
    <div class="rails">
      <div class="band-body feature">
        <div class="stack">
          <h2 id="scope-title">从一个主题开始</h2>
          <p>想先试试工作坊的来信？在设置里填入它的完整主题。授权后，只有主题完全相同的新来信会交给 Agent 起草。</p>
          <p>把主题留空，就能处理 Apple Mail 所有账户、所有主题的新来信。你随时可以在设置里暂停处理或撤销授权。</p>
        </div>
        <figure>
          <img loading="lazy" src="/workbench.jpg?v=${release.build}" width="960" height="884" alt="Mailpipe 来信范围设置，主题栏填入「周五工作坊：投影和麦克风」。">
        </figure>
      </div>
    </div>
  </section>
  <section class="band" aria-label="关于来信和回复的常见问题">
    <div class="rails">
      <div class="band-body notes">
        <article>
          <h2>验证码也会生成草稿吗？</h2>
          <p>Mailpipe 会先在 Mac 上跳过能识别的验证码通知、自动回复和促销邮件。其余符合你设置范围的新来信，才会交给 Agent 起草。</p>
        </article>
        <article>
          <h2>DeepSeek 会收到什么？</h2>
          <p>来信和草稿保存在你的 Mac 上。你连接的 DeepSeek Harness 会把获准处理的主题和正文发给 DeepSeek 云端模型，使用你的额度。附件内容不在授权范围内。</p>
        </article>
        <article>
          <h2>能帮我核对代码改动吗？</h2>
          <p>来信附有 GitHub 拉取请求（PR）链接时，Agent 可以查看公开的代码差异，再起草回复。需要用你的 GitHub 账户查看时，先由你确认。</p>
        </article>
      </div>
    </div>
  </section>
  <section id="release" class="band" aria-labelledby="release-title">
    <div class="rails">
      <div class="band-body release">
        <div class="stack">
          <h2 id="release-title">安装 Mailpipe</h2>
          <ol class="install-steps">
            <li>下载并解压，把 Mailpipe 拖进「应用程序」后打开。</li>
            <li>按引导连接负责起草回复的 <a href="https://github.com/deepseek-ai/deepseek-harness/blob/master/README.zh.md">DeepSeek Harness</a>。需要先在本机装好它的命令行工具 dsh，并配置好模型。</li>
            <li>在 Apple Mail 的「设置」→「扩展」中勾选 Mailpipe，再回到 Mailpipe 确认来信范围。</li>
          </ol>
        </div>
        <div class="release-download">
          <a class="button button-primary" download href="${downloadURL}">下载 Mac 版 Mailpipe</a>
          <span>版本 ${release.version} · ZIP · ${fileSize}</span>
          <span>适用于 macOS 13 及以上版本</span>
        </div>
      </div>
    </div>
  </section>
</main>
<footer class="site-footer">
  <div class="rails">
    <div class="footer-identity">
      <img src="/icon.png" width="40" height="40" alt="">
      <div>
        <a class="brand" href="/">Mailpipe</a>
        <p>Apple Mail 回复助手</p>
      </div>
    </div>
    <div class="footer-contact">
      <p>联系支持</p>
      <a class="support" href="mailto:support@mailpipeai.com">support@mailpipeai.com</a>
    </div>
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
