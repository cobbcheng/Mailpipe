# MIME 正文提取审查修复

日期：2026-11-17。
PR：[#15](https://github.com/cobbcheng/Mailpipe/pull/15)。
审查基线：`619049c`。
修复版本：本记录所在提交。
状态：隔离回归和双架构构建通过。
Mail 实机 MIME 格式验收未验证。

## 问题与修复

| 问题 | 失败证据 | 修复 |
|---|---|---|
| macOS 未链接 iconv | 标准测试和 App 链接失败；`_iconv*` 未定义 | C target 在 macOS 显式链接 iconv |
| `.eml` 附件进入正文 | 合成附件 canary 出现在提取结果 | 解码、递归前检查附件 disposition |
| 隐藏图片吞掉后文 | 隐藏 img 后的合成请求丢失 | 空元素不压入隐藏栈 |

附件边界也覆盖 `message/global` 和 multipart。
附件只返回名称和类型。
内联转发仍可提取可读正文。
隐藏容器仍丢弃自身内容。

## 环境与授权

| 项目 | 范围 |
|---|---|
| 系统 | macOS 27.0.1，26A434，arm64 |
| Swift / SDK | Apple Swift 6.4.2 / macOS SDK 27.2 |
| 构建架构 | arm64、x86_64 |
| 邮箱账户 | 未连接 |
| 数据 | 合成 MIME，地址仅用 example.com |
| Harness / MailBridge | fake；不访问真实模型和邮箱 |
| 安装 / 签名 | 未安装；构建关闭签名 |

## 验证结果

| 检查 | 命令或证据 | 结果 |
|---|---|---|
| 标准隔离回归 | `./scripts/test.sh` | 79 项通过；真实 Harness 调用日志为空 |
| 正文新增回归 | `MailBodyTests` 新增 4 项 | 附件消息、附件容器、内联消息、隐藏空元素通过 |
| App 与扩展构建 | `./scripts/build-app.sh -quiet` | 通过，无临时链接参数 |
| 架构 | `lipo -archs` | 宿主与扩展均含 arm64、x86_64 |
| 动态依赖 | `otool -L` | 宿主调试库与扩展双架构均链接 libiconv |
| 差异 | `git diff --check` | 通过 |

79 项包含 Core 34、Runtime 23、Bridge 5、Adapter 17。
隐藏空元素用例覆盖 12 种标签及两种隐藏样式。
附件消息用例覆盖 rfc822 和 global。
只有附件时仍返回 `attachmentOnly`。

构建成功不代表 Mail 实机格式验收通过。
本轮未启动 Mail、未安装 App、未移动邮件。
未调用真实模型，未运行发送动作。
真实模型调用次数为 0。
真实模型输入、输出字符数均为 0。
真实模型 token 与实付金额均为 0。
