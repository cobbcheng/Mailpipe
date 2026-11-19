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

0.0.5（build 32）使用 Developer ID 签名并通过 Apple 公证。
私有 R2 保存归档。官网通过 Pages 提供静态下载。
页面与构建脚本共用[发布信息](release.mjs)中的版本、文件名和校验值。

在仓库根目录执行 `node website/build-pages.mjs <含已公证App的ZIP> <全新输出目录>`。
脚本核对包大小与 SHA-256，并生成首页、robots.txt 和 sitemap.xml。
将输出目录的内容部署到现有 Pages 生产项目 `mailpipe-official`。
发布流程与验收门槛见[部署方法](../docs/deployment.md)。
