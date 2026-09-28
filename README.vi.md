<p align="center">
  <img src="icon_1024.png" width="128" alt="AiUsage icon">
</p>

<h1 align="center">AiUsage</h1>

<p align="center">
  Widget nhỏ gọn trên macOS, hiển thị realtime mức sử dụng các công cụ AI lập trình.<br>
  <a href="README.md">English</a> · <b>Tiếng Việt</b>
</p>

---

AiUsage gắn một tab đen mảnh vào mép phải màn hình và luôn hiển thị các số liệu sau:

| | Hiển thị gì |
| --- | --- |
| 🟠 **Limit Claude** | % đã dùng (hoặc còn lại) của phiên 5 giờ và giới hạn tuần. Nếu gói của bạn có giới hạn tuần riêng cho Opus/Sonnet thì hiện thêm. Rê chuột vào vòng để xem khi nào reset. |
| ⚪ **Cursor** | % usage của gói trong chu kỳ thanh toán hiện tại. Chỉ hiện khi máy có cài và đăng nhập Cursor. *Đang thử nghiệm.* |
| 🟢 **Task đang chạy** | Số phiên Claude Code trên máy này đang làm việc. Rê chuột để xem tên từng phiên. |
| 🔥 **Token hôm nay** | Tổng số token Claude Code đã dùng hôm nay trên máy này. Rê chuột để xem chi tiết input, output và cache. Ngọn lửa cháy nhanh hơn khi có task đang chạy. |

App cũng có một icon trên menu bar (✦ kèm % phiên 5 giờ).

## Yêu cầu

- macOS 14 Sonoma trở lên (chip Apple hoặc Intel)
- Đã cài [Claude Code](https://code.claude.com) và đăng nhập bằng tài khoản Pro/Max/Team/Enterprise (`claude` → `/login`)
- Không bắt buộc: Cursor đã đăng nhập

## Cài đặt

1. Tải `AiUsage.dmg` ở mục [Releases](https://github.com/RYG-Labs/AiUsage/releases), hoặc tự build (xem bên dưới).
2. Mở file DMG và kéo **AiUsage** vào **Applications**.
3. App chưa được Apple notarize nên macOS sẽ chặn lần mở đầu tiên. Bạn có hai cách:
   - Mở app một lần, sau đó vào **System Settings → Privacy & Security** và bấm **Open Anyway**.
   - Hoặc chạy lệnh:

     ```bash
     xattr -dr com.apple.quarantine /Applications/AiUsage.app
     ```

4. Nếu macOS hỏi quyền truy cập Keychain để đọc thông tin đăng nhập Claude Code, bấm **Always Allow**.
5. Không bắt buộc: thêm AiUsage vào **System Settings → General → Login Items** để app tự chạy khi mở máy.

## Cách dùng

- **Bấm vào tab** để mở menu.
- **Kéo tab** lên hoặc xuống để đổi vị trí dọc mép màn hình. App nhớ vị trí này.
- **Rê chuột** lên vòng hoặc badge để xem chi tiết.

Các mục trong menu:

| Mục | Tác dụng |
| --- | --- |
| Làm mới | Cập nhật số liệu ngay |
| Hiển thị % còn lại | Hiện % còn lại thay vì % đã dùng |
| Luôn nằm trên cửa sổ khác | Tab nằm trên các cửa sổ khác. Tắt đi thì tab chỉ nằm trên desktop. |
| Hiện token hôm nay | Bật/tắt bộ đếm token 🔥 |
| Hiện số task đang chạy | Bật/tắt badge task |
| Hiện Cursor | Bật/tắt vòng Cursor |
| Hiện trên menu bar | Bật/tắt icon trên menu bar |
| Thoát | Thoát app |

## Build từ mã nguồn

```bash
./build.sh      # tạo AiUsage.app (universal: arm64 + x86_64)
./package.sh    # tạo AiUsage.dmg để cài trên máy khác
```

Muốn đổi icon app thì sửa `make_icon.swift`. Cách tạo lại `icon_1024.png` được ghi ở dòng chú thích đầu file đó.

## Cách hoạt động

| Dữ liệu | Nguồn | Tần suất cập nhật |
| --- | --- | --- |
| Limit Claude | Gọi `https://api.anthropic.com/api/oauth/usage` bằng token OAuth của Claude Code lưu trong Keychain | mỗi 90 giây |
| Cursor | Lấy token trong `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, rồi gọi `cursor.com/api/usage-summary`. Với gói cũ tính theo request thì dùng `/api/usage`. | mỗi 90 giây |
| Task đang chạy | Đọc `~/.claude/sessions/*.json`, đếm các phiên có `status: "busy"` và process vẫn còn chạy | mỗi 2 giây |
| Token hôm nay | Cộng các trường `usage` trong `~/.claude/projects/**/*.jsonl`. App chỉ đọc phần mới ghi thêm và reset lúc 0h theo giờ máy. | mỗi 30 giây |

Lưu ý:

- **Chỉ đọc.** AiUsage không ghi gì vào Keychain hay dữ liệu của Claude/Cursor. App không gửi dữ liệu đi đâu ngoài hai API usage ở trên.
- **Endpoint không chính thức.** API usage của Claude và Cursor là endpoint nội bộ, có thể thay đổi bất cứ lúc nào.
- **Giới hạn tần suất.** Nếu API Claude trả lỗi HTTP 429, widget vẫn hiện số liệu gần nhất và chờ lâu hơn trước khi thử lại, từ 2 đến tối đa 15 phút.
- **Phạm vi đếm.** Task đang chạy và token hôm nay chỉ tính Claude Code trên máy này, gồm tab Code của app Claude desktop, CLI và extension VS Code/Cursor. Không tính chat trên claude.ai hay các máy khác. Còn limit tính theo tài khoản nên luôn đúng.
- **Tổng token có tính cache đọc.** Cache đọc thường chiếm phần lớn số token, nhưng rẻ hơn nhiều so với input/output thông thường.

## Giấy phép

[MIT](LICENSE) © RYG.Labs
