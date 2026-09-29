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
| ⚪ | **Usage Cursor** | % usage của gói trong chu kỳ thanh toán hiện tại. *Đang thử nghiệm.* |
| 🟢 | **Task đang chạy** | Số phiên Claude Code trên máy này đang làm việc. |
| 🔥 | **Token hôm nay** | Tổng token Claude Code đã dùng trong ngày, có chi tiết input, output và cache. Ngọn lửa cháy nhanh hơn khi có task đang chạy. |
| 👥 | **Nhiều tài khoản Claude** | Mỗi profile Claude Code phụ (`CLAUDE_CONFIG_DIR`) có một vòng gọn: vòng ngoài là limit 5 giờ, vòng trong là limit tuần, chữ cái đầu của tài khoản ở giữa. Token hết hạn được tự làm mới. |
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
| **Bấm** vào bộ đếm 🔥 | Mở biểu đồ token |
| **Rê chuột** lên vòng hoặc badge | Hiện tooltip: % đã dùng và còn lại, đếm ngược, giờ reset chính xác |

### Menu cài đặt

| Mục | Mô tả |
| --- | --- |
| Làm mới | Cập nhật số liệu ngay |
| Hiển thị % còn lại | Hiện % còn lại thay vì % đã dùng |
| Cập nhật limit mỗi | Tần suất gọi API usage: 1, 2, 5 (mặc định), 10, 15 hoặc 30 phút |
| Luôn nằm trên cửa sổ khác | Tab nằm trên các cửa sổ khác. Tắt đi thì tab chỉ hiện trên desktop. |
| Ngôn ngữ / Language | Tiếng Việt / English |
| Hiển thị trên màn hình | Chọn màn hình đặt tab. Chỉ hiện khi máy nối từ 2 màn hình trở lên. |
| Hiện token hôm nay | Bật/tắt bộ đếm token 🔥 |
| Hiện số task đang chạy | Bật/tắt badge task |
| Hiện Cursor | Bật/tắt vòng Cursor |
| Hiện trên menu bar | Bật/tắt icon trên menu bar |
| Thông báo | Chọn loại thông báo muốn nhận, gửi thông báo thử |
| Tự chạy khi mở máy | Tự khởi động AiUsage khi đăng nhập máy |
| Kiểm tra bản mới… | Kiểm tra GitHub Releases ngay. App cũng tự kiểm tra mỗi 6 giờ. |
| Thoát | Thoát AiUsage |

## Cách hoạt động

| Dữ liệu | Nguồn | Tần suất cập nhật |
| --- | --- | --- |
| Limit Claude | Gọi `api.anthropic.com/api/oauth/usage` bằng token OAuth của Claude Code trong Keychain. Nếu Keychain có nhiều mục trùng tên, app dùng mục được sửa gần nhất. | mỗi 5 phút (chỉnh được 1–30 phút) |
| Usage Cursor | Lấy access token trong file `state.vscdb` của Cursor, rồi gọi `cursor.com/api/usage-summary`. Gói cũ tính theo request thì dùng `/api/usage`. | mỗi 5 phút (chỉnh được 1–30 phút) |
| Task đang chạy | Đọc `~/.claude/sessions/*.json`. Một phiên được đếm khi `status` là `"busy"` và process của nó vẫn còn chạy. | 2 giây |
| Token hôm nay | Cộng các trường `usage` trong `~/.claude/projects/**/*.jsonl`. App chỉ đọc phần mới ghi thêm, mỗi câu trả lời chỉ tính một lần, và tổng về 0 lúc 0h theo giờ máy. | 30 giây |

**Phạm vi.** Limit tính theo tài khoản nên luôn đúng dù bạn dùng ở đâu. *Task đang chạy* và *token hôm nay* chỉ tính Claude Code trên máy này, gồm tab Code của app desktop, CLI và extension IDE. Không tính chat trên claude.ai hay các máy khác.

**Dự báo.** Tốc độ được tính từ mức thay đổi usage trong 1 giờ gần nhất (limit 5 giờ) hoặc 24 giờ gần nhất (limit tuần, tháng). Cần ít nhất 15 phút hoặc 2 giờ dữ liệu thì mới hiện dự báo.

**Khi máy thức dậy.** AiUsage làm mới toàn bộ số liệu vài giây sau khi mở nắp máy.

**Giới hạn tần suất.** Nếu API Claude trả lỗi HTTP 429, AiUsage vẫn hiện số liệu gần nhất và chờ lâu dần trước khi thử lại, bắt đầu từ 2 phút và tối đa 15 phút.

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

AiUsage tự tìm mọi lần đăng nhập trong Keychain. `~/.claude` là tài khoản chính và hiện đầy đủ các vòng. Mỗi profile còn lại có một vòng tài khoản. Nên đặt tên thư mục profile dạng `~/.claude-*` để AiUsage hiện được email của tài khoản.

Khi token của một profile hết hạn, AiUsage làm mới giống cách Claude Code làm, rồi ghi token mới lại vào mục Keychain của profile đó, nên Claude Code vẫn dùng bình thường. Nếu đang có phiên Claude Code chạy bằng profile đó, AiUsage để Claude Code tự làm mới.

## Quyền riêng tư & bảo mật

- **Chỉ đọc, trừ một ngoại lệ.** AiUsage không sửa dữ liệu của Claude Code hay Cursor. Việc ghi duy nhất là lưu token OAuth vừa làm mới trở lại đúng mục Keychain đã đọc, giống hệt việc Claude Code tự làm.
- **Không thu thập dữ liệu.** App chỉ gửi request tới hai endpoint usage ở trên, endpoint làm mới token OAuth của Claude, và API GitHub Releases để kiểm tra bản mới.
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
