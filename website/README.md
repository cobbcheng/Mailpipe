# Mailpipe 官网

从本目录运行 `npx wrangler@4 dev --local`。
本地开发时由 Worker 渲染首页。生产站发布预生成的静态文件。
正式地址为 https://mailpipeai.com/ 。

## 图片来源

- 0.0.5（build 32）的截图来自源码 `fa5e337` 构建的原生界面。
- `public/detail.jpg` 展示工作坊设备来信和逐项回复的示例草稿。`public/detail-mobile.jpg` 来自缩窄后重拍的详情区。
- `public/workbench.jpg` 展示首次设置时填入完整主题的步骤。
- 预览使用独立队列、五封合成来信和 example.com 地址。
- 图标来自仓库的 `design/icon/png/icon_128.png`。

### Agent 标识

下列图形来自各项目的官方仓库。站点本地提供原文件。
四个项目的许可随图片发布，见[版权声明](public/agents/NOTICES.txt)。

| 名称 | 图形来源 |
|---|---|
| DeepSeek Harness | [项目官网的蓝鲸图标](https://github.com/deepseek-ai/deepseek-harness/blob/2e39e70496aa02986ca6a820c5d497e816b69d7e/website/public/favicon.svg) |
| OpenCode | [官方品牌包的浅色背景标识](https://github.com/anomalyco/opencode/blob/d33b5783338b8b350aafc09f7dc2701eeba52a9a/services/site/public/brand/files/opencode-logo-transparent-light.svg) |
| OpenClaw | [官方界面的龙虾图标](https://github.com/openclaw/openclaw/blob/fcd7eb6130ed0d3de4a850bda6434f6a8b67664f/ui/public/favicon.svg) |
| Hermes Agent | [Nous Research 文档站图标](https://github.com/NousResearch/hermes-agent/blob/502009cc3fe7be2d7bb9a42c1670c14ac0ad9e7b/website/static/img/apple-touch-icon.png) |

Claude Code 使用普通文字和真实命令 `claude`。
Anthropic 对兼容性说明和图形使用有不同要求。见[官方使用说明](https://code.claude.com/docs/en/legal-and-compliance)。

## 字体

标题绑定 Inter Display，正文绑定 Inter。
文件是 rsms/inter 4.1 的拉丁子集，许可为 SIL OFL 1.1。
许可全文见 `public/fonts/LICENSE.txt`。
中文不在这两套字体中，由系统无衬线中文字体承接。

## 展示底板

Hero 里的产品窗使用上面的实机截图。
Framer 模板的照片底板只有未随仓库提供的库存图引用。
页面用表面色 `#F4F5F7` 代替，不把该照片当作 Mailpipe 素材。

## 下载状态

0.0.6（build 33）使用 Developer ID 签名并通过 Apple 公证。
私有 R2 保存归档。官网通过 Pages 提供静态下载。
页面与构建脚本共用[发布信息](release.mjs)中的版本、文件名和校验值。

在仓库根目录执行 `node website/build-pages.mjs <含已公证App的ZIP> <全新输出目录>`。
脚本核对包大小与 SHA-256，并生成首页、robots.txt 和 sitemap.xml。
将输出目录的内容部署到现有 Pages 生产项目 `mailpipe-official`。
发布流程与验收门槛见[部署方法](../docs/deployment.md)。
