<div align="center">

<img src="icon_1024.png" width="112" alt="AiUsage">

# AiUsage

**Mức sử dụng AI lập trình, luôn trong tầm mắt.**<br>
Widget macOS native theo dõi limit Claude Code và Cursor, số task đang chạy và lượng token dùng trong ngày.

[![macOS](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](#yêu-cầu)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](AiUsage.swift)
[![Universal](https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-555555)](#build-từ-mã-nguồn)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

[English](README.md) · **Tiếng Việt**

<img src="docs/preview.png" width="360" alt="Widget AiUsage nằm ở mép phải màn hình">

</div>

## Mục lục

- [Tính năng](#tính-năng)
- [Yêu cầu](#yêu-cầu)
- [Cài đặt](#cài-đặt)
- [Cách dùng](#cách-dùng)
- [Cách hoạt động](#cách-hoạt-động)
- [Quyền riêng tư & bảo mật](#quyền-riêng-tư--bảo-mật)
- [Xử lý sự cố](#xử-lý-sự-cố)
- [Build từ mã nguồn](#build-từ-mã-nguồn)
- [Miễn trừ trách nhiệm](#miễn-trừ-trách-nhiệm)
- [Giấy phép](#giấy-phép)

## Tính năng

| | Tính năng | Chi tiết |
| :-: | --- | --- |
| 🟠 | **Limit Claude** | Mức dùng của phiên 5 giờ và giới hạn tuần. Nếu gói của bạn có giới hạn tuần riêng cho Opus/Sonnet thì hiện thêm. Có đếm ngược và giờ reset chính xác theo GMT+7. |
| ⚪ | **Usage Cursor** | % usage của gói trong chu kỳ thanh toán hiện tại. *Đang thử nghiệm.* |
| 🟢 | **Task đang chạy** | Số phiên Claude Code trên máy này đang làm việc. |
| 🔥 | **Token hôm nay** | Tổng token Claude Code đã dùng trong ngày, có chi tiết input, output và cache. Ngọn lửa cháy nhanh hơn khi có task đang chạy. |
| 🪟 | **Gọn, không vướng** | Tab rộng 40 px bám mép màn hình. Kéo lên xuống để đổi vị trí, chọn màn hình, hoặc chỉ hiện trên desktop. |
| 🌐 | **Song ngữ** | Giao diện tiếng Việt và tiếng Anh, không phụ thuộc ngôn ngữ của macOS. |
| ⚡️ | **Nhẹ** | Viết bằng SwiftUI + Core Animation, không dùng thư viện ngoài. CPU gần 0% khi rảnh. Chỉ một file thực thi universal khoảng 1 MB. |

App còn có icon trên menu bar, hiện ✦ kèm % phiên 5 giờ.

## Yêu cầu

- macOS 14 Sonoma trở lên, chip Apple hoặc Intel
- Đã cài [Claude Code](https://code.claude.com) và đăng nhập bằng tài khoản Pro, Max, Team hoặc Enterprise (`claude` → `/login`)
- *Không bắt buộc:* [Cursor](https://cursor.com) đã đăng nhập

## Cài đặt

1. Tải **`AiUsage.dmg`** ở mục [Releases](https://github.com/RYG-Labs/AiUsage/releases), hoặc [tự build](#build-từ-mã-nguồn).
2. Mở file DMG và kéo **AiUsage** vào **Applications**.
3. Cho phép app chạy ở lần mở đầu tiên. App chưa được Apple notarize nên bạn làm một trong hai cách:
   - Mở app một lần, rồi vào **System Settings → Privacy & Security** và bấm **Open Anyway**.
   - Hoặc chạy lệnh:
     ```bash
     xattr -dr com.apple.quarantine /Applications/AiUsage.app
     ```
4. Nếu macOS hỏi quyền truy cập Keychain để đọc thông tin đăng nhập Claude Code, bấm **Always Allow**.
5. *Không bắt buộc:* muốn app tự chạy khi mở máy thì thêm AiUsage vào **System Settings → General → Login Items**.

## Cách dùng

| Thao tác | Kết quả |
| --- | --- |
| **Bấm** vào tab | Mở menu cài đặt, trong đó có cả số liệu chi tiết |
| **Kéo** tab lên hoặc xuống | Đổi vị trí dọc mép màn hình. App nhớ vị trí này. |
| **Rê chuột** lên vòng hoặc badge | Hiện tooltip: % đã dùng và còn lại, đếm ngược, giờ reset chính xác |

### Menu cài đặt

| Mục | Mô tả |
| --- | --- |
| Làm mới | Cập nhật số liệu ngay |
| Hiển thị % còn lại | Hiện % còn lại thay vì % đã dùng |
| Luôn nằm trên cửa sổ khác | Tab nằm trên các cửa sổ khác. Tắt đi thì tab chỉ hiện trên desktop. |
| Ngôn ngữ / Language | Tiếng Việt / English |
| Hiển thị trên màn hình | Chọn màn hình đặt tab. Chỉ hiện khi máy nối từ 2 màn hình trở lên. |
| Hiện token hôm nay | Bật/tắt bộ đếm token 🔥 |
| Hiện số task đang chạy | Bật/tắt badge task |
| Hiện Cursor | Bật/tắt vòng Cursor |
| Hiện trên menu bar | Bật/tắt icon trên menu bar |
| Thoát | Thoát AiUsage |

## Cách hoạt động

| Dữ liệu | Nguồn | Tần suất cập nhật |
| --- | --- | --- |
| Limit Claude | Gọi `api.anthropic.com/api/oauth/usage` bằng token OAuth của Claude Code trong Keychain. Nếu Keychain có nhiều mục trùng tên, app dùng mục được sửa gần nhất. | 90 giây |
| Usage Cursor | Lấy access token trong file `state.vscdb` của Cursor, rồi gọi `cursor.com/api/usage-summary`. Gói cũ tính theo request thì dùng `/api/usage`. | 90 giây |
| Task đang chạy | Đọc `~/.claude/sessions/*.json`. Một phiên được đếm khi `status` là `"busy"` và process của nó vẫn còn chạy. | 2 giây |
| Token hôm nay | Cộng các trường `usage` trong `~/.claude/projects/**/*.jsonl`. App chỉ đọc phần mới ghi thêm, mỗi câu trả lời chỉ tính một lần, và tổng về 0 lúc 0h theo giờ máy. | 30 giây |

**Phạm vi.** Limit tính theo tài khoản nên luôn đúng dù bạn dùng ở đâu. *Task đang chạy* và *token hôm nay* chỉ tính Claude Code trên máy này, gồm tab Code của app desktop, CLI và extension IDE. Không tính chat trên claude.ai hay các máy khác.

**Giới hạn tần suất.** Nếu API Claude trả lỗi HTTP 429, AiUsage vẫn hiện số liệu gần nhất và chờ lâu dần trước khi thử lại, bắt đầu từ 2 phút và tối đa 15 phút.

## Quyền riêng tư & bảo mật

- **Chỉ đọc.** AiUsage không sửa gì trong Keychain hay dữ liệu của Claude Code và Cursor.
- **Không thu thập dữ liệu.** App chỉ gửi request tới hai endpoint usage ở trên.
- **Token chỉ nằm trong bộ nhớ.** Thông tin đăng nhập được đọc khi cần, không bao giờ ghi ra ổ đĩa hay log.
- **Dễ kiểm tra.** Toàn bộ app nằm trong một file Swift ([`AiUsage.swift`](AiUsage.swift)).

## Xử lý sự cố

| Hiện tượng | Cách xử lý |
| --- | --- |
| *"AiUsage can't be opened"* | Xem bước 3 ở phần [Cài đặt](#cài-đặt). |
| Vòng trống hoặc hiện **!** | Mở menu để đọc dòng ⚠︎. Nếu token hết hạn, mở Claude Code một lần để nó làm mới token. |
| ⚠︎ "giới hạn tần suất" | App vẫn hiện số liệu gần nhất và tự hồi phục sau 2–15 phút. Tránh tắt mở app liên tục. |
| Không thấy vòng Cursor | Kiểm tra Cursor đã đăng nhập và mục **Hiện Cursor** đang bật. |
| Finder hoặc Launchpad còn icon cũ | Chạy `killall Dock`. |

## Build từ mã nguồn

```bash
git clone git@github.com:RYG-Labs/AiUsage.git && cd AiUsage
./build.sh      # tạo AiUsage.app (universal: arm64 + x86_64)
./package.sh    # tạo AiUsage.dmg
```

| File | Vai trò |
| --- | --- |
| `AiUsage.swift` | Toàn bộ app: lấy dữ liệu, giao diện widget, menu, đa ngôn ngữ |
| `build.sh` | Biên dịch file thực thi universal và đóng gói thành `.app` |
| `package.sh` | Đóng gói app thành file DMG kéo-thả để cài |
| `make_icon.swift` | Vẽ `icon_1024.png`. Cách dùng ghi ở dòng chú thích đầu file. |

Cần cài Xcode Command Line Tools (`xcode-select --install`).

## Miễn trừ trách nhiệm

AiUsage là dự án độc lập, không liên kết, không được bảo trợ hay tài trợ bởi Anthropic hoặc Anysphere (Cursor). "Claude" và "Cursor" là thương hiệu của các chủ sở hữu tương ứng. Các endpoint usage không có tài liệu chính thức và có thể thay đổi hoặc ngừng hoạt động bất cứ lúc nào.

## Giấy phép

[MIT](LICENSE) © RYG.Labs
