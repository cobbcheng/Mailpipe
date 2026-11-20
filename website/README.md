# Mailpipe 官网

从本目录运行 `npx wrangler@4 dev --local`。
本地开发时由 Worker 渲染首页。生产站发布预生成的静态文件。
正式地址为 https://mailpipeai.com/ 。

## 图片来源

- `compose-window-ready.png` 和 `compose-window-empty.png` 截自 Apple Mail 的回复窗口。
- 截图保留撰写工具栏以及从 Mailpipe 信封按钮展开的面板。
- 拍摄时使用合成邮件和测试草稿，分别展示已有回复及空态。
- 发件账户已遮盖。点击官网缩略图可查看原尺寸截图。
- 工作台和首次设置截图来自 0.1.0（build 34，源码 `f7589cd`）的隔离预览副本。
- `public/screenshots/` 按 en、zh、es 存放三种语言的实拍图。
- `detail.jpg` 展示工作台，`detail-mobile.jpg` 展示窄窗口的草稿详情。
- `scope.jpg` 展示首次设置时按完整主题限定来信的步骤。
- 工作台的每种语言使用独立队列、本地化合成邮件和 example.com 地址。
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

0.2.0（build 50）已通过 Apple 公证并装订票据。
官网与 Sparkle 通过同一个 `/downloads/` 地址从私有 R2 下载。
页面与构建脚本共用[发布信息](release.mjs)中的版本、文件名和校验值。

在仓库根目录执行 `node website/build-pages.mjs <含已公证App的ZIP> <全新输出目录>`。
脚本核对包大小与 SHA-256，生成三语首页和更新源。
输出还包括 robots.txt 和 sitemap.xml。
根路径默认英文。中文使用 /zh/，西班牙语使用 /es/。
将输出目录的内容部署到现有 Pages 生产项目 `mailpipe-official`。
发布流程与验收门槛见[部署方法](../docs/deployment.md)。

## 自更新发布

更新源固定为 `https://mailpipeai.com/appcast.xml`。
官网和更新源分发同一个 ZIP。
0.1.0 build 34 是首个自更新版本之前的安装包。
以该包构建官网时，生成的更新源为空。
已有用户需从官网安装带更新器的版本一次。

在仓库根目录运行 `node --test website/appcast.test.mjs`。
离线回归覆盖旧版空更新源、签名归档构建和错签拒绝。
测试使用临时目录和一次性密钥。

1. 递增宿主与扩展的 build，保持两者版本一致。
2. 按[部署方法](../docs/deployment.md)完成签名、公证和装订。
3. 用 `ditto` 归档已装订的 App。以下命令在仓库根目录运行。

   ```sh
   ditto -c -k --sequesterRsrc --keepParent "$MAILPIPE_RELEASE_APP" "$MAILPIPE_RELEASE_ZIP"
   SPARKLE_BIN=.build/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin
   "$SPARKLE_BIN/sign_update" --account com.mailpipe.app "$MAILPIPE_RELEASE_ZIP"
   shasum -a 256 "$MAILPIPE_RELEASE_ZIP"
   ```

4. 在[发布信息](release.mjs)填写此 ZIP 的版本、build、文件名和 SHA-256。
   将签名输出的 `sparkle:edSignature` 填入 `edSignature`，`length` 填入 `bytes`。
   `minimumSystemVersion` 使用三段系统版本，如 `13.0.0`。
   私钥保存在发布机钥匙串，构建官网只需公钥。
5. 构建并核对静态文件。输出目录必须是新路径。

   ```sh
   node website/build-pages.mjs "$MAILPIPE_RELEASE_ZIP" "$MAILPIPE_PAGES_OUTPUT"
   xmllint --noout "$MAILPIPE_PAGES_OUTPUT/appcast.xml"
   ```

   构建使用 Node.js 和 Python 3 标准库。
   它核对 ZIP 内宿主及扩展的标识与版本。
   它还核对宿主的系统下限、更新地址和公钥。
   最后用源码中的 `SUPublicEDKey` 验证归档签名。
6. 在 Pages 项目 `mailpipe-official` 的生产环境绑定私有 R2 桶，变量名设为 `RELEASES`。
   桶内 `downloads/` 前缀只存放已批准公开的版本包。
   首次切换时，先将当前 build 34 和需保留的历史 ZIP 放入此前缀。
   每个版本使用唯一文件名。获得发布授权后，在仓库根目录上传并回读核验。

   ```sh
   filename=$(node --input-type=module -e "import { release } from './website/release.mjs'; console.log(release.filename)")
   key="$MAILPIPE_RELEASE_BUCKET/downloads/$filename"
   npx wrangler@4 r2 object put "$key" --remote --file "$MAILPIPE_RELEASE_ZIP"
   npx wrangler@4 r2 object get "$key" --remote --file "$MAILPIPE_READBACK_ZIP"
   cmp "$MAILPIPE_RELEASE_ZIP" "$MAILPIPE_READBACK_ZIP"
   ```

7. 回读一致后，将输出目录部署到 Pages。该目录包含更新清单及下载处理程序。
   官网下载按钮和更新器均请求 `/downloads/<文件名>`，处理程序从 R2 流式返回 ZIP。
   回读线上更新源和其中的 ZIP，分别与本地产物比对。
   用上一版带更新器的 App 验收安装和重启。

归档格式与签名参数见 [Sparkle 发布说明](https://sparkle-project.org/documentation/publishing/)。
