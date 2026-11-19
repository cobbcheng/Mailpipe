# Mailpipe 官网

从本目录运行 `npx wrangler@4 dev --local`。
Worker 在服务器生成中文首页、robots.txt 和 sitemap.xml。
正式地址为 https://mailpipeai.com/ 。

## 图片来源

- `public/workbench.jpg` 来自基线 `18998c3` 的实机工作台。使用独立队列和三条手写合成记录，仅捕获指定进程的窗口。
- `public/detail.jpg` 来自[草稿详情实机验收](../docs/validation/2026-11-17-draft-detail-v12.md)中的 `toolbar-restored.jpg`。该次验收使用独立合成来信与草稿。
- 图标来自仓库的 `design/icon/png/icon_128.png`。

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

0.0.2（build 23）使用 Developer ID 签名并通过 Apple 公证。私有 R2 只归档；公开下载由现有 Pages 静态托管，不触发 Worker 或 R2 读取。

在仓库根目录执行 `node website/build-pages.mjs <含已公证App的ZIP> <全新输出目录>`，脚本会检查 SHA-256，并在发布之前生成完整首页 HTML、robots.txt 和 sitemap.xml。将输出目录的内容部署到现有 Pages 生产项目 mailpipe-official；不要额外添加 Worker、Functions 或 R2 公共端点。
发布流程与验收门槛见[部署方法](../docs/deployment.md)。
