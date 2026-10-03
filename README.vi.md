<div align="center">

<img src="icon_1024.png" width="112" alt="AiUsage">

# AiUsage

**Mức sử dụng AI lập trình, luôn trong tầm mắt.**<br>
Widget macOS native theo dõi limit Claude Code, số task đang chạy và lượng token dùng trong ngày.

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
- [Nhiều tài khoản](#nhiều-tài-khoản)
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
| 🟢 | **Task đang chạy** | Số phiên Claude Code trên máy này đang làm việc. |
| 🔥 | **Token hôm nay** | Tổng token Claude Code đã dùng trong ngày, có chi tiết input, output và cache. Ngọn lửa cháy nhanh hơn khi có task đang chạy. |
| 👥 | **Nhiều tài khoản Claude** | Mỗi profile Claude Code phụ (`CLAUDE_CONFIG_DIR`) có một vòng gọn: vòng ngoài là limit 5 giờ, vòng trong là limit tuần, chữ cái đầu của tài khoản ở giữa. |
| 🔔 | **Thông báo thông minh** | Báo khi limit chạm 80% / 95%, khi limit vừa reset, cảnh báo sớm khi với tốc độ hiện tại sẽ hết trước giờ reset, và báo khi một task Claude Code chạy xong (kèm tên phiên và thời gian chạy). |
| 📈 | **Dự báo tốc độ** | Ước tính tốc độ tiêu thụ và thời điểm chạm 100%, ví dụ *"~20%/giờ → chạm 100% lúc 16:40, trước reset 1g"*. |
| 📊 | **Biểu đồ token** | Biểu đồ nhiệt kiểu GitHub cho token Claude Code: theo giờ trong 14 ngày gần nhất và theo ngày trong 6 tháng. Bấm vào bộ đếm 🔥 để mở. Có thể bỏ phần cache đọc. |
| 🪟 | **Gọn, không vướng** | Tab rộng 40 px bám mép màn hình. Kéo lên xuống để đổi vị trí, chọn màn hình, hoặc chỉ hiện trên desktop. |
| 🌐 | **Song ngữ** | Giao diện tiếng Việt và tiếng Anh, không phụ thuộc ngôn ngữ của macOS. |
| ⚡️ | **Nhẹ** | Viết bằng SwiftUI + Core Animation, không dùng thư viện ngoài. CPU gần 0% khi rảnh. Chỉ một file thực thi universal khoảng 1 MB. |

App còn có icon trên menu bar, hiện ✦ kèm % phiên 5 giờ.

## Yêu cầu

- macOS 14 Sonoma trở lên, chip Apple hoặc Intel
- Đã cài [Claude Code](https://code.claude.com) và đăng nhập bằng tài khoản Pro, Max, Team hoặc Enterprise (`claude` → `/login`)

## Cài đặt

1. Tải **`AiUsage.dmg`** ở mục [Releases](https://github.com/RYG-Labs/AiUsage/releases), hoặc [tự build](#build-từ-mã-nguồn).
2. Mở file DMG và kéo **AiUsage** vào **Applications**.
3. Cho phép app chạy ở lần mở đầu tiên. App chưa được Apple notarize nên bạn làm một trong hai cách:
   - Mở app một lần, rồi vào **System Settings → Privacy & Security** và bấm **Open Anyway**.
   - Hoặc chạy lệnh:
     ```bash
     xattr -dr com.apple.quarantine /Applications/AiUsage.app
     ```
4. Bấm vào tab, mở **Cài đặt** và chọn **Kết nối Claude Code**. Sau đó gửi một tin nhắn trong Claude Code để có số liệu đầu tiên.
5. *Không bắt buộc:* muốn app tự chạy khi mở máy thì thêm AiUsage vào **System Settings → General → Login Items**.

## Cách dùng

| Thao tác | Kết quả |
| --- | --- |
| **Bấm** vào tab | Mở menu cài đặt, trong đó có cả số liệu chi tiết |
| **Kéo** tab lên hoặc xuống | Đổi vị trí dọc mép màn hình. App nhớ vị trí này. |
| **Bấm** vào bộ đếm 🔥 | Mở biểu đồ token |
| **Rê chuột** lên vòng hoặc badge | Hiện tooltip: % đã dùng và còn lại, đếm ngược, giờ reset chính xác |

### Menu cài đặt

| Mục | Mô tả |
| --- | --- |
| Làm mới | Cập nhật số liệu ngay |
| Hiển thị % còn lại | Hiện % còn lại thay vì % đã dùng |
| Kết nối Claude Code | Đăng ký AiUsage làm status line của Claude Code cho mọi profile (xem [Cách hoạt động](#cách-hoạt-động)) |
| Luôn nằm trên cửa sổ khác | Tab nằm trên các cửa sổ khác. Tắt đi thì tab chỉ hiện trên desktop. |
| Ngôn ngữ / Language | Tiếng Việt / English |
| Hiển thị trên màn hình | Chọn màn hình đặt tab. Chỉ hiện khi máy nối từ 2 màn hình trở lên. |
| Hiện token hôm nay | Bật/tắt bộ đếm token 🔥 |
| Hiện số task đang chạy | Bật/tắt badge task |
| Hiện trên menu bar | Bật/tắt icon trên menu bar |
| Thông báo | Chọn loại thông báo muốn nhận, gửi thông báo thử |
| Tự chạy khi mở máy | Tự khởi động AiUsage khi đăng nhập máy |
| Kiểm tra bản mới… | Kiểm tra GitHub Releases ngay. App cũng tự kiểm tra mỗi 6 giờ. |
| Thoát | Thoát AiUsage |

## Cách hoạt động

| Dữ liệu | Nguồn | Tần suất cập nhật |
| --- | --- | --- |
| Limit Claude | Lấy từ [dữ liệu status line](https://code.claude.com/docs/en/statusline) mà Claude Code tự cung cấp (`rate_limits.five_hour`, `rate_limits.seven_day`). AiUsage được đăng ký làm lệnh status line (`AiUsage --statusline`). Sau mỗi phản hồi, lệnh này lưu số liệu vào `~/Library/Application Support/AiUsage/limits/`, rồi app đọc thư mục đó. | sau mỗi phản hồi của Claude Code |
| Task đang chạy | Đọc `~/.claude/sessions/*.json`. Một phiên được đếm khi `status` là `"busy"` và process của nó vẫn còn chạy. | 2 giây |
| Token hôm nay | Cộng các trường `usage` trong `~/.claude/projects/**/*.jsonl`. App chỉ đọc phần mới ghi thêm, mỗi câu trả lời chỉ tính một lần, và tổng về 0 lúc 0h theo giờ máy. | 30 giây |

**Phạm vi.** Limit tính theo tài khoản nên luôn đúng dù bạn dùng ở đâu. *Task đang chạy* và *token hôm nay* chỉ tính Claude Code trên máy này, gồm tab Code của app desktop, CLI và extension IDE. Không tính chat trên claude.ai hay các máy khác.

**Dự báo.** Tốc độ được tính từ mức thay đổi usage trong 1 giờ gần nhất (limit 5 giờ) hoặc 24 giờ gần nhất (limit tuần, tháng). Cần ít nhất 15 phút hoặc 2 giờ dữ liệu thì mới hiện dự báo.

**Khi máy thức dậy.** AiUsage làm mới toàn bộ số liệu vài giây sau khi mở nắp máy.

**Không dùng token, không gọi API.** AiUsage không đọc, không làm mới và không gửi thông tin đăng nhập Claude của bạn. Số liệu chỉ cập nhật khi bạn dùng Claude Code, cũng là lúc limit thay đổi. Khi qua giờ reset của một khung, AiUsage hiện khung đó trống lại.

## Nhiều tài khoản

Claude Code lưu mỗi thư mục cấu hình một lần đăng nhập. Muốn nhiều tài khoản cùng đăng nhập một lúc, cho mỗi tài khoản phụ một thư mục riêng:

```bash
mkdir -p ~/.claude-2 ~/.claude-3
CLAUDE_CONFIG_DIR=$HOME/.claude-2 claude   # rồi /login bằng tài khoản 2
CLAUDE_CONFIG_DIR=$HOME/.claude-3 claude   # rồi /login bằng tài khoản 3
```

Có thể thêm lệnh tắt vào `~/.zshrc` (không bắt buộc):

```bash
alias claude2='CLAUDE_CONFIG_DIR=$HOME/.claude-2 claude'
alias claude3='CLAUDE_CONFIG_DIR=$HOME/.claude-3 claude'
```

**Kết nối Claude Code** thêm status line cho `~/.claude` và mọi profile `~/.claude-*`. `~/.claude` là tài khoản chính và hiện đầy đủ các vòng. Mỗi profile còn lại có một vòng tài khoản sau lần phản hồi đầu tiên. Nên đặt tên thư mục profile dạng `~/.claude-*` để AiUsage tìm thấy.

Nếu một profile đã có status line riêng, AiUsage không đụng vào. Mỗi file settings được sao lưu một lần thành `settings.json.aiusage-backup`.

## Quyền riêng tư & bảo mật

- **Không đụng tới đăng nhập.** AiUsage không đọc Keychain và không dùng token Claude nào. Thay đổi duy nhất với Claude Code là dòng `statusLine` do **Kết nối Claude Code** thêm vào.
- **Không thu thập dữ liệu.** Request mạng duy nhất là tới API GitHub Releases để kiểm tra bản mới.
- **Dễ kiểm tra.** Toàn bộ app nằm trong một file Swift ([`AiUsage.swift`](AiUsage.swift)).

## Xử lý sự cố

| Hiện tượng | Cách xử lý |
| --- | --- |
| *"AiUsage can't be opened"* | Xem bước 3 ở phần [Cài đặt](#cài-đặt). |
| Vòng đỏ **!** | AiUsage chưa kết nối, hoặc Claude Code chưa báo số liệu nào. Chọn **Cài đặt → Kết nối Claude Code**, rồi gửi một tin nhắn trong Claude Code. |
| Số liệu có vẻ cũ | Số liệu cập nhật sau mỗi phản hồi của Claude Code. Rê chuột lên **Làm mới** để xem lần cập nhật gần nhất. |
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

AiUsage là dự án độc lập, không liên kết, không được bảo trợ hay tài trợ bởi Anthropic. "Claude" là thương hiệu của Anthropic. App dựa vào dữ liệu status line chính thức của Claude Code, các trường dữ liệu có thể thay đổi giữa các phiên bản Claude Code.

## Giấy phép

[MIT](LICENSE) © RYG.Labs
