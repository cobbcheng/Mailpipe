# Mailpipe

**English** | [简体中文](README.zh-CN.md)

**Let your agent draft replies in Apple Mail.**

Keep using Apple Mail for your inbox. Choose an agent to draft replies, edit them on your Mac, and send them yourself from Mail.

Mailpipe stores incoming messages and drafts on your Mac. Only incoming content you authorize goes to your chosen agent for drafting. Messages never pass through a Mailpipe server. Choose from Codex CLI, DeepSeek Harness, Claude Code, OpenCode, OpenClaw, or Hermes Agent. OpenClaw and Hermes Agent use the official DeepSeek Flash model. Claude Code uses your local CLI’s default model. OpenCode uses the model you confirm after testing the connection.

**[Download for Mac](https://mailpipeai.com/)**

Mailpipe’s own code is available under the [MIT License](LICENSE). Third-party components, assets, and brand marks remain subject to their respective licenses and rights. See the notices for the [Lottie animation](Mailpipe/App/OnboardingArt/Lottie-LICENSE.txt), [fonts](website/public/fonts/LICENSE.txt), and [agent logos](website/public/agents/NOTICES.txt).

## Product scope

| Area | Design goal |
|---|---|
| Who it’s for | Mac users who use Apple Mail and have installed and signed in to a supported agent harness |
| What it does | Your existing agent drafts replies to incoming mail. You review and send them. |
| P0 | L0 (organize silently), L1 (flag for reply), L2 (prepare a draft), per-message data destination labels, and triage to decide whether a reply is needed |
| Model access | Six agents can draft replies. |
| Interface | A pending queue in the menu bar, a separate workbench, and system notifications. Compose windows never open automatically. |
| Mail organization | MailKit captures incoming mail. Apple Events locate messages, carry out actions, and verify results. |
| Data destinations | Each message identifies the harness and model provider. Unknown destinations are labeled as such. |
| When it runs | When Mail is running and downloads new messages. Processing is not guaranteed with the lid closed. |
| P1 | Mail history search, agent-assisted create/read/update/delete operations, a daily digest, and user-initiated drafting |
| P2 | Delayed automatic sending for an L3 allowlist. Not implemented, requires separate permission, and is outside the current development scope. |

The app does not call model APIs directly, store model credentials, or relay messages through Mailpipe servers. You still receive and send mail in Apple Mail.

L2 is the default. Drafts go only to the menu bar’s pending queue. Mailpipe will not write to Mail’s Drafts mailbox until that path passes testing on a real Mac. The send action opens a draft; it does not call `send`.

P1 history search requires separate, read-only authorization. Its design has not yet been verified on a real Mac. When an agent proposes creating, updating, or deleting something, it returns only the intended action. Mailpipe is responsible for carrying it out through Apple Events.

Mailpipe can skip recognizable newsletters, promotions, and payment receipts locally. The agent reads other authorized messages and drafts replies only when needed. DeepSeek Harness can check GitHub pull request changes with read-only access. Codex CLI, Claude Code, OpenCode, OpenClaw, and Hermes Agent draft from the incoming message alone. This restriction does not apply to searches you start yourself; an incoming message cannot trigger them.

## Getting started

During setup, select a drafting agent you’ve already configured on your Mac. The connection test makes one model call using a sample email. If you close setup, it resumes where you left off.

Enable the Mailpipe extension in Apple Mail. Choose which incoming messages the agent may process: all future messages across accounts, or only messages matching an exact subject. Review the scope in the final step. If processing was paused, it stays paused.

For common message formats, Mailpipe extracts plain text locally, subject to size limits. Encrypted messages, attachment-only messages, and raw messages over 4 MiB are set aside for review. You can view and edit drafts in the workbench. Before sending, check the recipients and message body in Apple Mail. For the tested scope, see the [compact onboarding checks](docs/validation/2026-11-19-compact-onboarding.md) and [manual intake removal checks](docs/validation/2026-11-19-remove-manual-intake.md).

### Use a draft in Apple Mail

When replying to or forwarding a message, click **Mailpipe** in the compose window’s toolbar. If a draft exists, you can edit it in the panel or click **Regenerate**. Otherwise, click **Generate Draft**. When you’re ready, click **Copy reply**, paste it into the message body, then review and send in Mail. When you reopen a saved forward, you can also click **Choose Existing Draft**.

### Customize your reply instructions

After setup, open **Settings → Replies**, enter your instructions, and save. For example: “Reply in the language of the incoming message. Answer the question first and end with the next step.”

These instructions apply to all authorized accounts and are sent to your selected agent with each drafting request. They take effect for new drafts and drafts you manually regenerate. To restore the default style, clear the instructions and save.

### Daily reply reminder

Under **Settings → General → Daily reply reminder**, allow notifications and choose a time. By default, Mailpipe checks once a day at 10 a.m. local time.

The notification shows only the number of pending replies still eligible for handoff to Mail. Opening a draft does not remove it from the count; discarding it or handing it off to Mail does. The menu bar shows the same count. Click it or the notification to view the latest pending reply in the workbench.

If your Mac is asleep or Mailpipe isn’t running, the check runs when Mailpipe resumes later that day. There’s no notification if the queue is empty, processing is paused, or authorization has been revoked.

### App updates

Starting with version 0.1.1, Mailpipe checks for updates automatically. You can also select **Check for Updates…** in the menu bar. Quit Apple Mail before installing the update, then reopen it to load the updated extension. If you use 0.1.0, install the first updater-enabled version manually from the website. See the [self-update test results](docs/validation/2026-11-20-self-update.md) for the status of release candidates.

## Documentation

The linked project documents are in Chinese.

| Topic | Read |
|---|---|
| Getting started as a coding agent | [AGENTS.md](AGENTS.md) |
| Architecture and responsibilities | [DESIGN.md](DESIGN.md) |
| Find documentation by task | [Agent maintenance reference](docs/agent-reference.md) |
| Product scope and PRD v0.5 | [Product plan](docs/product.md) |
| Revised roadmap against PRD v0.5 | [Revised roadmap](docs/product/roadmap-v0.5.md) |
| Confirmed assumptions and wording changes | [Assumptions and wording](docs/product/assumptions-and-wording.md) |
| Reply quality and harness memory prompts | [What makes a good reply](docs/product/good-reply-standard.md) |
| Full documentation index | [docs/README.md](docs/README.md) |
| Screens, flows, and error states | [Interaction design](docs/interaction-design.md) |
| Setup and the first draft | [Onboarding PRD](docs/onboarding.md) |
| MailKit and Apple Events responsibilities | [Mail integration](docs/mail-integration.md) |
| Model calls and routing | [Harness contract](docs/harness-adapter.md) |
| Queues, actions, and receipts | [Data contracts](docs/data-contracts.md) |
| Privacy, permissions, and security | [Security design](docs/security.md) |
| Validation and development order | [Test plan](docs/testing.md) and [milestones](docs/roadmap.md); the latter has been superseded by the [revised roadmap](docs/product/roadmap-v0.5.md). |
| Installation, signing, and upgrades | [Deployment](docs/deployment.md) |
| Risks and open questions | [Known limitations](docs/known-issues.md) |
| Source material and scope of verification | [Sources](docs/sources.md) |

## Local development

You need the full Xcode installation and Swift 6. The project targets macOS 13 and later; compatibility has not yet been verified on real Macs across OS versions.

```sh
./scripts/swift.sh build
./scripts/test.sh
./scripts/swift.sh run mailpipe-m0 discover
./scripts/build-app.sh
```

Open `Mailpipe.xcodeproj` in Xcode and select the `Mailpipe` scheme. Build products are written to `.build/xcode/Build/Products/Debug/`. The build script does not sign or install the app or enable the Mail extension.

After changing project targets, run `python3 scripts/generate-project.py`. Maintain project configuration in the generator rather than editing generated files by hand.

The menu bar icon lives in `Mailpipe/Assets.xcassets`. The app uses `design/icon/AppIcon.icon`. The icon sources and build script are in `design/icon/`. To regenerate the icon, install CairoSVG and the Cairo shared library, then run `python3 design/icon/build.py`. The background and envelope are separate layers; the system mask supplies the rounded corners. The PNG and ICNS files are retained as legacy design exports.

`inspect <dsh|claude|opencode|openclaw|hermes|codex> /absolute/path` checks only the tool’s version and help output. Diagnostics discover local tools and inspect their arguments without calling a model. Codex CLI uses your existing sign-in to draft with GPT-6.2 Sol.

## Verification status

Triage, drafts, service levels, and data destination contracts are implemented. Persisted work has resumed successfully across processes and after an app restart. One synthetic incoming message was verified end to end, from MailKit capture to a draft in the workbench. Pausing processing or revoking authorization preserves existing drafts and stops further processing. See the [persistent reply pipeline tests](docs/validation/2026-11-16-persistent-reply-pipeline.md).

Independent click handling in the menu bar popover and broad MIME and mailbox compatibility remain unverified. MIME tests on build 8 found problems with size-limit notices and leftover candidates. Build 9 fixed both and passed a limited Google IMAP retest. See the [MIME retest](docs/validation/2026-11-17-mime-fix-retest.md) and [earlier reply contract tests](docs/validation/2026-11-16-reply-contracts.md).

Live tests covered repeated callbacks for the same message body and single-message capture after the host quit and Mail restarted. Moving a single message, reading it back independently through the host, and moving it back also passed. The writes went through the Mail UI; the production bridge is not yet connected.

Codex passed the fixed classification test and two canary challenges. Early DeepSeek tests passed synthetic classification and confirmed no tool calls. See the [DeepSeek validation record](docs/validation/2026-11-16-deepseek-harness.md). Full identity verification, conditional undo, and restricted tool use remain open. See the [detailed validation results](docs/validation/2026-11-16-m0-move-harness.md).

Live tests also covered the signed host app, extension activation, and Apple Events. See the [M0 engineering record](docs/validation/2026-11-15-m0-scaffold.md) for project setup and early isolated tests. Subscription terms, cross-version compatibility, and user conversion have not yet been verified.

## Keeping the documentation current

`README.md` records the current state; `DESIGN.md` describes the design. Keep each detailed contract in its topic document. When a design changes, update that document first, then its index entries and summaries. Reference records should contain general findings, never private mail.

### Onboarding implementation notes (2026-11-16)

The local implementation included a five-step wizard, a separate draft of the setup choices, and the ability to resume after a restart. L2 was the default. Choices took effect only at final confirmation, and any existing pause remained in place. DeepSeek synthetic tests were isolated from the live intake queue. See the [onboarding checks](docs/validation/2026-11-16-onboarding.md).

Signed build 4 passed a limited live test with Google IMAP. It covered final authorization, the system denying permission (error `-1743`), and the first L2 draft. The permission-denied message was corrected, and users could retry confirmation after restoring permission. The test record includes extension instance conflicts during updates and samples that failed. See the [live onboarding test](docs/validation/2026-11-16-onboarding-live.md).

In that version, step four let users select multiple mail accounts and used each selected account’s inbox. Selections were saved as a draft; only final confirmation authorized the set. See the [account inbox tests](docs/validation/2026-11-16-account-inboxes.md).
