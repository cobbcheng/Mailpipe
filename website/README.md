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

启用 CI 前的基线为 0.2.0（build 50），已通过 Apple 公证并装订票据。
官网与 Sparkle 通过同一个 `/downloads/` 地址从私有 R2 下载。
线上自更新清单是当前版本的依据。
仓库中的 [release.mjs](release.mjs) 保留为本地预览默认值。
CI 从最终 ZIP 和其公共签名构建，不改写仓库或手填版本。

## 自更新发布

CI 在上游 main 收到 push 后运行。PR 检查不发布。
生产环境名为 `mailpipe-production`。
下列步骤不创建项目、桶、公开桶地址或 DNS 记录，不修改套餐。

1. 在 macOS 签名任务中完成 Developer ID 签名、Apple 公证、装订、Gatekeeper 和 Sparkle 签名。
2. 将最终 ZIP 和单行公签名 `signature.txt` 传给网站任务。
   文件名必须是 `Mailpipe-<版本>-build<号>-<7位提交>.zip`。
3. 离线构建，从两个 plist 核对宿主及扩展标识、版本、系统下限、更新 URL 和源码公钥。
   静态生成器验证 SHA-256、长度和最终 ZIP 的 Ed25519 签名。
   三语下载按钮、结构化数据、CSS 版本和更新清单使用同一份发布信息。
4. 核对线上清单未前进、Pages 项目 `mailpipe-official` 生产分支为 `main`，
   以及生产 `RELEASES` 绑定对应目标桶。通过 S3 条件写入新版本路径。
   如果路径已存在，只接受与原包完全一致的对象；不删除、不覆盖旧包。
   从私有桶下载并比较完整字节，再将预生成目录上传至 Pages。
   目录中的 `_worker.js` 仍从 R2 提供下载。官网和 Sparkle 共用同一 URL。
5. 回读官网清单和 ZIP 全文、HEAD 长度、三语下载按钮和结构化数据、robots、sitemap 及 CSS。
   另测上一版下载 URL。回读重试不重复发布。部署状态不代表已在干净 Mac 上完成升级。

### 离线检查与公开回读

在仓库根目录运行。输出目录必须不存在。前两条命令无需网络、凭据或 Apple 签名服务。

```sh
node --test website/appcast.test.mjs
python3 scripts/ci/publish-site.py build "$ZIP" "$SIGNATURE_TXT" "$NEW_OUTPUT"
python3 scripts/ci/publish-site.py verify "$ZIP" "$NEW_OUTPUT"
python3 scripts/ci/publish-site.py probe "$PUBLISHED_GIT_SHA"
```

`probe` 独立下载线上公签名和 ZIP，核验源码中的 Sparkle 公钥及三语页面。
如果站点已前进，它拒绝将其他提交的发布当作成功。
本地预览旧版仍可用 `node website/build-pages.mjs "$ZIP" "$NEW_OUTPUT"`。

### 发布环境输入

| 名称 | 类型与用途 |
|---|---|
| `CLOUDFLARE_ACCOUNT_ID` | 环境变量：现有 Pages 与 R2 账户 ID |
| `MAILPIPE_RELEASE_BUCKET` | 环境变量：现有 Pages 生产绑定 `RELEASES` 的桶名，不是本地开发桶 |
| `CLOUDFLARE_API_TOKEN` | 环境 secret：限定目标账户的 Cloudflare Pages Edit |
| `AWS_ACCESS_KEY_ID`、`AWS_SECRET_ACCESS_KEY` | 环境 secrets：限定此 R2 桶的 S3 Object Read & Write 密钥对，不使用 AWS 账户密钥 |

工具为 Node 22.12+、Python 3、支持条件写的 AWS CLI v2 和锁定版本的 Wrangler。
在没有生产凭据的步骤运行 `npm ci --ignore-scripts --prefix website/ci-tools`。
真实发布只在受保护的 main push 步骤调用 `publish-site.py deploy "$ZIP" "$NEW_OUTPUT"`。
Apple 材料不传给网站任务；PR 不获得生产环境。
若 R2 写入后 Pages 上传失败，保留同一 run 的原 ZIP，重试失败任务，
不要重新公证并以同名覆盖。若回读失败，先验证线上状态，不直接重复发布。

参考：[Pages Direct Upload](https://developers.cloudflare.com/pages/get-started/direct-upload/)、
[R2 条件写](https://developers.cloudflare.com/r2/api/s3/conditional-operations/)、
[Sparkle 签名](https://sparkle-project.org/documentation/publishing/)。
