<p align="center">
  <img src="icon_1024.png" width="128" alt="AiUsage icon">
</p>

<h1 align="center">AiUsage</h1>

<p align="center">
  A tiny macOS side widget that shows your AI coding usage in real time.<br>
  <b>English</b> · <a href="README.vi.md">Tiếng Việt</a>
</p>

---

AiUsage docks a slim black tab to the right edge of your screen and keeps these numbers in view:

| | What it shows |
| --- | --- |
| 🟠 **Claude limits** | Used (or remaining) % of the 5-hour session and the weekly limit, plus the Opus/Sonnet weekly limits if your plan has them. Hover a ring to see when it resets. |
| ⚪ **Cursor** | % of the included plan usage in the current billing cycle. Only shown if Cursor is installed and signed in. *Experimental.* |
| 🟢 **Running tasks** | How many Claude Code sessions on this Mac are busy right now. Hover to see their names. |
| 🔥 **Tokens today** | Total Claude Code tokens used today on this Mac. Hover for input, output and cache breakdown. The flame flickers faster while a task is running. |

A menu bar item (✦ with the 5-hour %) is also available.

## Requirements

- macOS 14 Sonoma or later (Apple Silicon or Intel)
- [Claude Code](https://code.claude.com) installed and signed in with a Pro/Max/Team/Enterprise account (`claude` → `/login`)
- Optional: Cursor, signed in

## Install

1. Download `AiUsage.dmg` from [Releases](https://github.com/RYG-Labs/AiUsage/releases), or build it yourself (see below).
2. Open the DMG and drag **AiUsage** into **Applications**.
3. The app is not notarized, so macOS blocks it the first time. Either open it once and click **System Settings → Privacy & Security → Open Anyway**, or run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/AiUsage.app
   ```

4. If macOS asks for Keychain access to read the Claude Code credentials, click **Always Allow**.
5. Optional: add AiUsage to **System Settings → General → Login Items** so it starts with your Mac.

## Usage

- **Click the tab** to open the menu.
- **Drag the tab** up or down to move it along the screen edge. The position is remembered.
- **Hover** a ring or badge for details.

The menu has these toggles:

| Menu item | Effect |
| --- | --- |
| Làm mới | Refresh now |
| Hiển thị % còn lại | Show remaining % instead of used % |
| Luôn nằm trên cửa sổ khác | Keep the tab above other windows. Turn off to keep it on the desktop only. |
| Hiện token hôm nay | Show or hide the 🔥 token counter |
| Hiện số task đang chạy | Show or hide the running-task badge |
| Hiện Cursor | Show or hide the Cursor ring |
| Hiện trên menu bar | Show or hide the menu bar item |
| Thoát | Quit |

> The UI is currently in Vietnamese.

## Build from source

```bash
./build.sh      # builds AiUsage.app (universal: arm64 + x86_64)
./package.sh    # builds AiUsage.dmg for installing on other Macs
```

To change the app icon, edit `make_icon.swift`. The comment at the top of that file shows how to regenerate `icon_1024.png`.

## How it works

| Data | Source | Refresh |
| --- | --- | --- |
| Claude limits | `https://api.anthropic.com/api/oauth/usage`, called with the Claude Code OAuth token from the login Keychain | every 90 s |
| Cursor usage | Token from `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, then `cursor.com/api/usage-summary` (falls back to `/api/usage` on legacy request-based plans) | every 90 s |
| Running tasks | `~/.claude/sessions/*.json`, where `status: "busy"` and the process is still alive | every 2 s |
| Tokens today | `usage` fields in `~/.claude/projects/**/*.jsonl`, read incrementally and reset at local midnight | every 30 s |

Notes:

- **Read-only.** AiUsage never writes to the Keychain or to Claude or Cursor data. Nothing is sent anywhere except the two usage APIs above.
- **Unofficial endpoints.** The Claude and Cursor usage endpoints are internal and may change without notice.
- **Rate limiting.** If the Claude API returns HTTP 429, the widget keeps showing the last known numbers and backs off, from 2 up to 15 minutes.
- **Scope.** Running tasks and tokens today only count Claude Code on this Mac. They include the Claude desktop app's Code tab, the CLI and the VS Code/Cursor extensions. claude.ai chats and remote machines are not counted. Limits are account-wide, so they are always accurate.
- **Token totals include cache reads.** Cache reads are usually the vast majority of tokens and are much cheaper than regular input or output.

## License

[MIT](LICENSE) © RYG.Labs
