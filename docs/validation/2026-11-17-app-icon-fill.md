# 应用图标灰边修复

日期：2026-11-17。
状态：构建与 Finder 实机预览通过；未安装。

## 问题与方案

旧图把圆角黑底和信封合为一张图片。
黑底在 1024 画布内只占 824 像素。
本机系统将它放入灰色底板，形成宽灰边。

| 方案 | 本机结果 | 结论 |
| --- | --- | --- |
| 旧位图背景铺满 | 仍有灰底板，并露出方角 | 不采用 |
| 原生分层资源 | 黑底充满系统圆角区域 | 采用 |

新增 `design/icon/AppIcon.icon`。
背景为不透明深黑色，前景为原信封 SVG。
工程生成器将资源加入宿主与扩展。
菜单栏模板图保持原样。
旧 PNG、ICNS 留作设计导出。
Xcode 从原生资源生成旧系统兼容图。

## 验证范围

| 项目 | 结果 |
| --- | --- |
| 系统 | macOS 27.0.1（26A434） |
| 工具 | Xcode 27.2（27B52） |
| 构建版本 | 0.0.1，build 7 |
| 图标生成 | `python3 design/icon/build.py` 通过 |
| 工程生成 | `python3 scripts/generate-project.py` 通过 |
| App 构建 | `scripts/build-app.sh` 通过 |
| 资源集成 | 宿主与扩展均编译原生图标 |
| 系统显示 | Finder 简介中宽灰边消失 |
| 授权范围 | 仅构建及查看测试产物；未启动宿主 |
| 账户与邮件 | 未访问；无模型调用 |
| 签名与安装 | 未开发签名；未替换已安装 App |
| 旧系统与其他外观 | 未验证 |

本轮未运行邮件行为回归。
未修改运行逻辑、用户数据与权限。
未发布或部署。

## 来源

- [Apple 图标设计规范](https://developer.apple.com/design/human-interface-guidelines/app-icons)：背景与系统遮罩。
- [Icon Composer 资源集成](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)：原生资源与旧系统兼容图。
