import downloads from './downloads.mjs';
import { messages } from "./messages.mjs";
import { release } from "./release.mjs";
import { appcast } from "./appcast.mjs";

const origin = "https://mailpipeai.com";
const agents = [
  { name: "DeepSeek Harness", version: "0.2.2-rc.1", repo: "deepseek-ai/deepseek-harness", tagPrefix: "dsh-v", logo: "deepseek-harness.svg" },
  { name: "Claude Code", version: "2.1.296", repo: "anthropics/claude-code", command: "claude" },
  { name: "OpenCode", version: "2.3.0", repo: "anomalyco/opencode", logo: "opencode.svg" },
  { name: "OpenClaw", version: "2026.11.5", repo: "openclaw/openclaw", logo: "openclaw.svg" },
  { name: "Hermes Agent", version: "0.23.2", repo: "NousResearch/hermes-agent", logo: "hermes-agent.png" },
];
const downloadURL = `/downloads/${release.filename}`;
const fileSize = `${(release.bytes / 1_000_000).toFixed(2)} MB`;

const languages = { en: ["/", "English"], "zh-CN": ["/zh/", "中文"], es: ["/es/", "Español"] };
function homepage(language = "en") {
  const copy = messages[language];
  const screenshots = `/screenshots/${language === "zh-CN" ? "zh" : language}`;
  const previewImage = `${origin}${screenshots}/detail.jpg`;
  const pageURL = origin + languages[language][0];
  const description = copy.description.replace("{agents}", agents.map(agent => agent.name).join(", "));
  const app = {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: "Mailpipe",
    url: pageURL,
    description,
    applicationCategory: "ProductivityApplication",
    operatingSystem: "macOS 13+",
    softwareVersion: release.version,
    downloadUrl: origin + downloadURL,
    screenshot: previewImage,
    inLanguage: language,
  };
  return `<!doctype html>
<html lang="${language}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${copy.title}</title>
<meta name="description" content="${description}">
${Object.entries(languages).map(([id,[path]]) => `<link rel="alternate" hreflang="${id}" href="${origin}${path}">`).join("\n")}
<link rel="canonical" href="${pageURL}">
<link rel="icon" href="/icon.png">
<link rel="preload" href="/fonts/InterDisplay-SemiBold.woff2" as="font" type="font/woff2" crossorigin>
<link rel="preload" href="/fonts/Inter-Medium.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="/site.css?v=${release.build}-picker">
<meta property="og:type" content="website">
<meta property="og:locale" content="${({en:"en_US",es:"es_ES","zh-CN":"zh_CN"})[language]}">
<meta property="og:site_name" content="Mailpipe">
<meta property="og:title" content="${copy.title}">
<meta property="og:description" content="${description}">
<meta property="og:url" content="${pageURL}">
<meta property="og:image" content="${previewImage}">
<meta property="og:image:alt" content="${copy.previewAlt}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:image:alt" content="${copy.previewAlt}">
<script type="application/ld+json">${JSON.stringify(app)}</script>
</head>
<body>
<a class="skip" href="#content">${copy.skip}</a>
<header class="site-header">
  <div class="rails">
    <a class="brand" href="${languages[language][0]}"><img src="/icon.png" width="28" height="28" alt="">Mailpipe</a>
    <nav aria-label="${copy.nav}"><a href="#workbench">${copy.workbench}</a><a href="#agents">${language === "es" ? "Agentes" : "Agents"}</a><a href="#release">${copy.download}</a></nav>
    <select aria-label="${copy.language}" onchange="location.href=this.value+location.hash">
      ${Object.entries(languages).map(([id,[path,name]]) => `<option value="${path}" ${id === language ? "selected" : ""}>${name}</option>`).join("")}
    </select>
  </div>
</header>
<main id="content">
  <section class="hero" aria-labelledby="hero-title">
    <div class="rails hero-stack">
      <div class="hero-copy">
        <p class="platform">${copy.platform}</p>
        <h1 id="hero-title">${copy.slogan}</h1>
        <p class="lead">${copy.lead}</p>
        <div class="actions">
          <a class="button button-primary" download href="${downloadURL}">${copy.downloadMac}</a>
          <a class="button button-secondary" href="#workbench">${copy.example}</a>
        </div>
      </div>
      <figure id="workbench" class="showcase">
        <div class="app-window">
          <picture>
            <source media="(max-width: 600px)" srcset="${screenshots}/detail-mobile.jpg" width="838" height="790">
            <img src="${screenshots}/detail.jpg" width="1648" height="864" alt="${copy.detailAlt}" fetchpriority="high">
          </picture>
        </div>
        <figcaption>${copy.caption}</figcaption>
      </figure>
    </div>
  </section>
  <section class="band" aria-labelledby="scope-title">
    <div class="rails">
      <div class="band-body feature">
        <div class="stack">
          <h2 id="scope-title">${copy.scope}</h2>
          <p>${copy.scopeIntro}</p>
          <p>${copy.scopeAll}</p>
        </div>
        <figure>
          <img loading="lazy" src="${screenshots}/scope.jpg" width="960" height="884" alt="${copy.scopeAlt}">
        </figure>
      </div>
    </div>
  </section>
  <section class="band" aria-label="${copy.faq}">
    <div class="rails">
      <div class="band-body notes">
        <article>
          <h2>${copy.codes}</h2>
          <p>${copy.filter}</p>
        </article>
        <article>
          <h2>${copy.privacy}</h2>
          <p>${copy.privacyBody}</p>
        </article>
        <article>
          <h2>${copy.pr}</h2>
          <p>${copy.prBody}</p>
        </article>
      </div>
    </div>
  </section>
  <section id="agents" class="band" aria-labelledby="agents-title">
    <div class="rails">
      <div class="band-body agents-body">
        <h2 id="agents-title">${copy.agents}</h2>
        <p>${copy.versions}</p>
        <ul class="agent-wall">
          ${agents.map(({ name, version, repo, tagPrefix = "v", logo, command }) => `<li><a class="agent-link" href="https://github.com/${repo}/releases/tag/${tagPrefix}${version}">
            ${logo ? `<img src="/agents/${logo}" width="48" height="48" loading="lazy" alt="">` : `<code class="agent-command" aria-hidden="true">$ ${command}</code>`}
            <span class="agent-name" lang="en">${name}</span><small class="agent-version">v${version}</small>
          </a></li>`).join("\n          ")}
        </ul>
      </div>
    </div>
  </section>
  <section id="release" class="band" aria-labelledby="release-title">
    <div class="rails">
      <div class="band-body release">
        <div class="stack">
          <h2 id="release-title">${copy.install}</h2>
          <ol class="install-steps">
            <li>${copy.unzip}</li>
            <li>${copy.configure}</li>
            <li>${copy.enable}</li>
          </ol>
        </div>
        <div class="release-download">
          <a class="button button-primary" download href="${downloadURL}">${copy.downloadFull}</a>
          <span>${copy.version}${release.version} · ZIP · ${fileSize}</span>
          <span>${copy.requires}</span>
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
        <a class="brand" href="${languages[language][0]}">Mailpipe</a>
        <p>${copy.footer}</p>
      </div>
    </div>
    <div class="footer-contact">
      <p>${copy.support}</p>
      <a class="support" href="mailto:support@mailpipeai.com">support@mailpipeai.com</a>
    </div>
  </div>
</footer>
</body>
</html>`;
}

export default {
  fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (!["GET", "HEAD"].includes(request.method)) {
      return new Response(null, { status: 405, headers: { Allow: "GET, HEAD" } });
    }
    if (path.startsWith('/downloads/')) return downloads.fetch(request, env);
    const routes = {
      "/appcast.xml": ["application/xml", () => appcast(release)],
      "/": ["text/html", homepage],
      "/es/": ["text/html", () => homepage("es")],
      "/zh/": ["text/html", () => homepage("zh-CN")],
      "/robots.txt": ["text/plain", () => `User-agent: *\nAllow: /\nSitemap: ${origin}/sitemap.xml\n`],
      "/sitemap.xml": ["application/xml", () => `<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${Object.values(languages).map(([path]) => `<url><loc>${origin}${path}</loc></url>`).join("")}</urlset>`]
    };
    const route = routes[path];
    if (!route) return new Response("Page not found", { status: 404 });
    return new Response(request.method === "HEAD" ? null : route[1](), {
      headers: { "Content-Type": route[0] + "; charset=utf-8", "X-Content-Type-Options": "nosniff" }
    });
  }
};
