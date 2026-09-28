# AiUsage

Widget macOS nhỏ gọn bám mép phải màn hình, hiển thị realtime:

- **Limit Claude** còn/đã dùng: phiên 5 giờ, tuần (và Opus/Sonnet nếu có), kèm thời gian reset.
- **Cursor**: % usage trong chu kỳ tháng (nếu máy có cài và đăng nhập Cursor).
- **Số task Claude Code đang chạy** (badge xanh).
- **Tổng token Claude Code đã dùng hôm nay** (🔥).

Kèm icon trên menu bar. Bấm vào tab để mở cài đặt, kéo lên/xuống để đổi vị trí.

## Yêu cầu

- macOS 14+ (Apple Silicon hoặc Intel)
- Claude Code đã cài và đăng nhập (`claude` → `/login`)

## Build

```bash
./build.sh        # tạo AiUsage.app
./package.sh      # tạo AiUsage.dmg để cài máy khác
```

Cài: kéo `AiUsage.app` vào `/Applications`. App chưa notarize nên lần đầu cần
**System Settings → Privacy & Security → Open Anyway**, hoặc:

```bash
xattr -dr com.apple.quarantine /Applications/AiUsage.app
```

## Nguồn dữ liệu

| Mục | Nguồn |
| --- | --- |
| Limit Claude | `https://api.anthropic.com/api/oauth/usage` với token OAuth Claude Code trong Keychain (endpoint nội bộ, có thể thay đổi) |
| Cursor | Token trong `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` → `cursor.com/api/usage-summary` |
| Task đang chạy | `~/.claude/sessions/*.json` (`status: busy`) |
| Token hôm nay | `~/.claude/projects/**/*.jsonl` (trường `usage`) |

App chỉ đọc, không ghi gì vào Keychain hay dữ liệu của Claude/Cursor.
