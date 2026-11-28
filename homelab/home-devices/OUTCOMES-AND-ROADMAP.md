# Kết quả, ưu nhược điểm và lộ trình thay thế thiết bị

> Áp dụng cho toàn hệ thống: homelab (`homelab/README.md`) + thiết bị trong nhà (`home-devices/README.md`).
> Trạng thái thiết bị theo kiểm kê 22/11/2026. Giá là **ước lượng AUD** để lập ngân sách, cần kiểm lại khi mua.
> Năm sản xuất/tuổi là ước tính theo model, không phải ngày mua thật — 👤 bổ sung ngày mua vào `devices.json`.

---

## 1. Kết quả đạt được sau khi thực hiện

### 1.1 Theo lĩnh vực

| Lĩnh vực | Trước (11/2026) | Sau khi làm xong | Đo bằng gì |
|---|---|---|---|
| **Dữ liệu gốc** | 1 HDD desktop đơn trong server + ảnh Immich trên 1 SSD rẻ | NAS RAID1 + Btrfs (✅ đã xong 22/11) | `cutover.sh status`, Storage UGOS |
| **Số bản sao** | 2 (server + Mac, rsync ghi đè có lịch sử 90 ngày) | 3: NAS + HDD restic + Mac restic, có phiên bản 7 ngày/4 tuần/12 tháng | `restic snapshots` 2 kho |
| **Khôi phục 1 file xoá nhầm** | Tìm trong `_history` trên Mac, thủ công | < 5 phút: `restic restore` từ kho local | Diễn tập quý (`restore-drill.sh`) |
| **Kiểm tra toàn vẹn backup** | Không có | Mỗi tuần đọc 5% dữ liệu backup + diễn tập SHA-256 mỗi quý | Healthchecks `homelab-maintain`, Telegram |
| **Bí mật dạng chữ thường** | Mật khẩu/token trong script, tài liệu, log | 0 (✅ đã xong), quét tự động mỗi CN, hook chặn trước commit | `secret_scan.py --all` = 0 |
| **Quyền của agent (Hermes)** | Sudo bằng mật khẩu, admin Kuma/Beszel, MK NAS | Root chỉ qua `homelab-ops.sh`; không giữ MK nào (✅ đã xong) | `sudo -l` của namdo |
| **Truy cập từ Internet** | Không rõ UPnP/port-forward | UPnP tắt, không port-forward, chỉ Tailscale | App Deco, `tailscale status` |
| **IP thiết bị quan trọng** | DHCP tự do, đã có IP bị đổi | ~25 thiết bị có DHCP reservation | `devices.json` cột `ip_reserved` |
| **Thiết bị lạ vào mạng** | Không biết | Cảnh báo ≤ 7 ngày (cron tuần) | Telegram bot cảnh báo |
| **Điều khiển nhà** | 7 app riêng (Tapo, Meross, BroadLink, Tuya, Sonos, Google Home, Apple Home) | 1 app chính: Apple Home + Siri (qua Home Assistant), app hãng làm dự phòng | Bài test D4 |
| **Tự động hoá** | Không có (HA đã gỡ) | Có, chạy cục bộ trên Home Assistant | Danh sách automation đã duyệt |
| **Camera** | 6/9 xem tập trung, 1 offline, MK chung đã lộ | 9/9 trong go2rtc, MK mới chỉ ở 1 file, xem trong app Nhà | go2rtc `:1984`, Kuma TCP 554 |
| **Giám sát** | Rời rạc, có báo động giả | NAS (UGOS SMART + thông báo), mount NFS, container, camera, HA, Deco — 1 bot cảnh báo riêng | Kuma, Healthchecks, watchdog |
| **Mất điện** | Mọi thứ tắt đột ngột, phải bật tay | NAS tự bật, server chờ NAS 5 phút; (sau UPS) tắt có thứ tự | Thử rút điện UPS |
| **Cách ly IoT** | Mạng phẳng /22 | IoT + camera ở mạng riêng (nếu Deco cho phép, GĐ C) | Bài test C: IoT không tới được NAS |

### 1.2 Điểm lỗi đơn (single point of failure) — trước và sau

| Thành phần | Nếu hỏng thì… | Sau khi làm xong |
|---|---|---|
| HDD 3TB trong server | Mất ảnh gốc | ✅ Không còn là bản gốc — chỉ là 1 bản backup |
| SSD BX500 | Mất ảnh Immich mới tải lên | ✅ Ảnh lên NAS; SSD còn OS, Postgres (có dump hằng đêm), thumbnail (tạo lại được) |
| **homeserver** | Mất Immich, Pi-hole (DNS), go2rtc, Home Assistant, backup | ⚠️ **Vẫn là điểm lỗi lớn nhất** — giảm bằng DNS dự phòng, UPS, thiết bị Matter gốc; giải quyết dứt điểm ở lộ trình mục 4 |
| NAS | Mất dữ liệu gốc | ✅ RAID1 + 2 bản backup ở 2 máy khác |
| Router Deco | Mất mạng toàn nhà | ⚠️ Chấp nhận (mesh 3 node, thiết bị mới) |
| Điện lưới | Tắt đột ngột | ⚠️ Cho tới khi có UPS |
| Nhà (cháy, trộm) | Mất cả 3 bản | ❌ Chưa có offsite — mục 4 |

---

## 2. Ưu điểm của thiết kế

| # | Ưu điểm | Vì sao quan trọng |
|---|---|---|
| 1 | **Giữ nguyên đường dẫn và IP** khi chuyển đổi (`/srv/nas`, DHCP reservation theo IP cũ) | Không phải sửa cấu hình hàng loạt → ít lỗi |
| 2 | **Mỗi bước có cổng dừng và đường lui** (rollback, `.bak`, ổ cũ chỉ đọc 14 ngày) | Đã chứng minh thực tế: sự cố 13:13 ngày cutover không mất dữ liệu |
| 3 | **Bí mật chỉ ở 1 nơi** (`.env` 600, go2rtc là nơi duy nhất giữ MK camera) | Đổi MK chỉ sửa 1 chỗ; HA không giữ MK camera |
| 4 | **Chạy cục bộ là chính** (HA local, go2rtc, Matter) | Mất Internet hoặc hãng đóng cloud vẫn dùng được |
| 5 | **Giao diện quen thuộc cho gia đình** (Apple Home, Siri) | Người nhà không phải học hệ thống mới |
| 6 | **Thiết bị dùng lại được:** HDD cũ thành ổ backup, Pi VN thành giám sát ngoài nhà | Không tốn tiền cho phần chưa cần |
| 7 | **Tự giám sát chính nó:** fail-closed (thiếu sentinel → không backup; scanner không đọc được → báo lỗi) | Lỗi kêu to, không âm thầm |

## 3. Nhược điểm còn lại và cách khắc phục

| # | Nhược điểm | Mức độ | Khắc phục ngắn hạn (0 đồng) | Khắc phục dứt điểm | Khi nào |
|---|---|---|---|---|---|
| 1 | **homeserver gánh quá nhiều vai trò** (Immich, HA, go2rtc, Pi-hole, backup, Hermes, 19 container) | Cao | DNS dự phòng trên Deco; HA backup hằng ngày; thiết bị quan trọng chọn Matter gốc | Tách HA (+ Pi-hole phụ) sang thiết bị nhỏ riêng; thay server (mục 4) | 2027 |
| 2 | **Không có UPS** | Cao | NAS/server tự bật lại; `/srv/nas` chờ NAS | UPS line-interactive ~1000VA, ưu tiên sóng sin chuẩn | Khi có tiền — ưu tiên số 1 |
| 3 | **2 ổ WD Red ~6 năm, cùng lô** | Cao | SMART UGOS hằng tuần + thông báo | Thay từng ổ (cách 2–3 tháng), hoặc thêm hot spare | Ưu tiên số 2 |
| 4 | **Chưa có offsite** | Trung bình | — | restic → Pi VN + ổ USB, hoặc Backblaze B2 (~6 USD/TB/tháng) | 2027 |
| 5 | **Ổ backup là HDD desktop cũ trong hộp USB** (Seagate ST3000DM003) | Trung bình | SMART + cảnh báo `/srv/backup` không mount; dán nhãn "không rút" | Thay ổ gắn ngoài mới (CMR) khi SMART xấu hoặc khi đầy 80% | Theo tình trạng |
| 6 | **SSD BX500 (DRAM-less, độ bền thấp)** chứa OS + Postgres + thumbnail | Trung bình | Cảnh báo ID 202 < 20% (đã có) | NVMe TLC có DRAM khi thay server | Cùng server |
| 7 | **Deco có thể không cách ly IoT đủ mức** (không có quy tắc firewall theo chiều) | Trung bình | Bài test C trước khi chuyển; NFS/SMB của NAS đã giới hạn IP | Router có VLAN + firewall (Deco chuyển sang chế độ AP) | Nếu C không đạt |
| 8 | **Phụ thuộc cloud hãng** (Tapo, Meross khi thêm; Tuya; Ring hoàn toàn cloud) | Thấp–TB | HA tích hợp cục bộ khi có thể | Thay dần bằng thiết bị Matter / API cục bộ khi hỏng | Theo vòng đời |
| 9 | **HA là thêm 1 hệ thống phải bảo trì** | Thấp | Ghim phiên bản, nâng ≤ 1 lần/tháng có backup | — | Liên tục |
| 10 | **Agent (Hermes) từng làm lộ bí mật 3 lần** | Trung bình | Quyền tối thiểu, không đọc file bí mật, hook + quét tuần | Tách bot/cảnh báo; agent không bao giờ có quyền admin dịch vụ | Đã áp dụng |
| 11 | **1GbE giới hạn tốc độ NAS** (~110 MB/s) | Thấp | Đủ cho ảnh/video gia đình | 2.5GbE khi thay server + switch | Cùng server |
| 12 | **UGOS hạn chế** (không SSH khoá, không scrub RAID1 tự động) | Thấp | Scrub tay 3 tháng/lần; thông báo UGOS | Cân nhắc TrueNAS/Unraid nếu sau này thay NAS | Không gấp |

---

## 4. Lộ trình thay thế thiết bị lỗi thời

### 4.1 Bảng vòng đời thiết bị

Trạng thái: 🟢 tốt (> 3 năm nữa) · 🟡 theo dõi (1–3 năm) · 🟠 lên kế hoạch thay (< 1 năm) · 🔴 thay ngay

| Thiết bị | Ước tính đời | Trạng thái | Dấu hiệu cần thay | Hướng thay thế (tiêu chí) | Ước chi |
|---|---|---|---|---|---|
| **Server** Lenovo ThinkCentre M700 Tiny, i5-6400T (2015–16) | ~10 năm | 🟠 | CPU quá tải khi chạy HA + Frigate + Immich ML; lỗi phần cứng; hết hỗ trợ BIOS | Mini PC Intel thế hệ 12+ (Quick Sync mới cho Frigate/Immich), NVMe, **2.5GbE**, RAM ≥ 32GB | 500–900 |
| SSD Crucial BX500 1TB | — | 🟡 | ID 202 < 20%, lỗi I/O | NVMe TLC có DRAM (theo server mới) | 100–150 |
| HDD Seagate ST3000DM003 + hộp USB (ổ backup) | ~9–10 năm | 🟠 | SMART 5/197/198 tăng; ổ đầy > 80% | Ổ gắn ngoài mới 6–8TB CMR, hoặc chuyển backup local sang ổ trong server mới | 200–300 |
| **2 × WD Red 4TB WD40EFRX** (NAS) | ~6 năm | 🟠 | SMART tăng, RAID degraded | WD Red Plus / IronWolf / N300 **CMR** 8TB, thay từng ổ | 400–600 (2 ổ) |
| NAS UGREEN DXP4800GT | ~2 năm | 🟢 | Hết cập nhật UGOS | Giữ; dùng 2 khay trống (hot spare / mở rộng) | — |
| Router Deco BE65 ×3 (Wi-Fi 7) | ~2 năm | 🟢 | Hết firmware | Giữ; nếu cần VLAN → thêm router riêng, Deco làm AP | (300–600) |
| Mac mini M2 / M4 | 2–3 năm | 🟢 | — | Giữ | — |
| **iMac 27" 2017** (iMac18,3) | ~9 năm | 🔴 về bảo mật | Không còn bản vá bảo mật macOS | Không dùng cho tài khoản quan trọng/ngân hàng; dùng làm màn hình/máy phụ hoặc thay | (tuỳ) |
| Apple TV 4K 2022, HomePod mini | 2–4 năm | 🟢 | — | Giữ (là home hub + Thread border router cho Matter) | — |
| Google Home (đời đầu) | ~8–10 năm | 🟡 | Google ngừng cập nhật | Thay bằng HomePod mini hoặc loa Sonos khi hỏng | 150 |
| Loa Sonos (Beam, One, Move, Sub Mini, SYMFONISK) | 2–7 năm | 🟢/🟡 | Sonos đưa vào danh sách "legacy" | Theo dõi danh sách legacy của Sonos; One/Move đời đầu sẽ tới lượt trước | — |
| TV Hisense 55A7NA | ~2 năm | 🟢 | — | Giữ | — |
| Camera Tapo C125/C225/C325WB/C545D | 1–3 năm | 🟢 | Hết firmware, mất RTSP | Khi thay/thêm: **PoE + RTSP/ONVIF cục bộ** (không phụ thuộc Wi-Fi, ổn định hơn cho Frigate) | 80–200/cam |
| Hub Tapo H500 | ~1–2 năm | 🟢 | — | Giữ | — |
| Ổ cắm/đèn Tapo P100, L510E | 3–5 năm | 🟡 | Hỏng | Thay bằng thiết bị **Matter** (vd. P110M đã là Matter) | 20–40/cái |
| Meross MSS210, MSH400 | ? | 🟡 | Hỏng / cần cloud | Thay bằng Matter khi hỏng | 20–40/cái |
| BroadLink (hồng ngoại) | ? | 🟢 | — | Giữ (HA tích hợp cục bộ tốt) | — |
| Tuya (.70), ESP32 ×2 | ? | 🟡 | Chưa xác định | Xác định trước; Tuya cloud-only → thay Matter | — |
| Robot Tapo RV20 Max Plus | ~1–2 năm | 🟢 | — | Giữ | — |
| Chuông cửa Ring (offline) | ? | 🟠 | Đang offline; hoàn toàn cloud | Sửa, hoặc thay chuông **PoE/RTSP** tích hợp HA + Frigate | 150–250 |
| Pi VN (vn-relay, Kuma) | ? | 🟡 | Thẻ SD hỏng (hay gặp ở Pi) | Boot từ SSD USB; ghi lại cấu hình Kuma (export backup) | 50–80 |
| **UPS** | — chưa có | 🔴 | — | Line-interactive ~1000VA, USB, ưu tiên sóng sin chuẩn | 150–250 |

### 4.2 Nguyên tắc chọn thiết bị mới (áp dụng cho mọi lần mua)

| Loại | Bắt buộc | Nên có | Tránh |
|---|---|---|---|
| Nhà thông minh | **Matter** (Wi-Fi hoặc Thread) hoặc API cục bộ được HA hỗ trợ | Thread cho cảm biến chạy pin (HomePod mini/Apple TV làm border router) | Chỉ chạy qua cloud; Tuya cloud-only |
| Camera | **RTSP + ONVIF cục bộ** | PoE, luồng phụ độ phân giải thấp (cho Frigate) | Chỉ xem qua app/cloud (như Ring) |
| Ổ cứng NAS | **CMR**, dòng NAS (Red Plus, IronWolf, N300) | Mua khác lô, khác thời điểm | SMR (WD Red không "Plus") |
| Ổ hệ thống | NVMe **TLC có DRAM** | Độ bền TBW cao | QLC/DRAM-less cho database |
| Máy chủ | Tiết kiệm điện (< 15W idle), **2.5GbE** | Intel iGPU thế hệ mới (Quick Sync, OpenVINO) | CPU không có iGPU (mất tăng tốc video) |
| Mạng | Hỗ trợ VLAN nếu mua router/switch mới | PoE cho camera | Thiết bị hết hỗ trợ firmware |
| Chung | Hãng cam kết cập nhật ≥ 5 năm | Có export cấu hình | Thiết bị bắt buộc tài khoản cloud để dùng cơ bản |

### 4.3 Kiến trúc hướng tới (2–3 năm)

```
              Internet
                 │
   Router có VLAN + firewall  ◀── (chỉ khi Deco không cách ly đủ)
     │  VLAN Tin cậy │ VLAN IoT │ VLAN Camera (PoE) │ VLAN Khách
     │
   Switch 2.5GbE + PoE ── camera PoE (RTSP) · chuông PoE
     │
   ├ Server mới (mini PC 2.5GbE, NVMe): Immich · Frigate · go2rtc · backup · Hermes
   ├ Thiết bị HA riêng (mini PC nhỏ / HA Green): Home Assistant · Matter · Pi-hole phụ
   │     → server chết, nhà thông minh + DNS vẫn chạy
   ├ NAS (4 ổ: RAID1 2×8TB + hot spare): dữ liệu gốc · ghi hình camera
   ├ UPS: server · HA · NAS · router/switch
   └ Offsite: restic → Pi VN + ổ USB  hoặc  Backblaze B2
```

### 4.4 Ngân sách theo năm (ước lượng, AUD)

| Năm | Hạng mục | Ước chi | Lý do thứ tự |
|---|---|---|---|
| 2026–27 | UPS | 150–250 | Bảo vệ RAID, thay ổ an toàn |
| 2027 | 2 ổ NAS 8TB CMR (từng ổ) | 400–600 | Ổ 6 năm tuổi giữ dữ liệu gốc |
| 2027 | Offsite (ổ USB cho Pi VN hoặc B2) | 100–200 hoặc ~10/tháng | Hoàn thành 3-2-1 |
| 2027–28 | Server mới (mini PC 2.5GbE, NVMe) | 500–900 | Giảm điểm lỗi, đủ sức Frigate |
| 2027–28 | Thiết bị HA riêng | 150–300 | Tách nhà thông minh khỏi server |
| Theo nhu cầu | Switch 2.5GbE PoE + camera PoE | 200 + 100–200/cam | Thay camera Wi-Fi khi hỏng |
| Tuỳ chọn | Router VLAN | 300–600 | Chỉ khi GĐ C không đạt |

---

## 5. Lịch bảo trì định kỳ

| Tần suất | Việc | Ai |
|---|---|---|
| Hằng ngày | Backup restic 2 kho, dump DB, SMART server, watchdog | 🤖 tự động |
| Hằng tuần | SMART nhanh (UGOS), prune + check 5% restic, quét bí mật, quét thiết bị lạ | 🤖 tự động |
| Hằng tháng | SMART toàn bộ (UGOS), xem báo cáo Healthchecks/Kuma, cập nhật HA (có backup) | 🤖 + 👤 duyệt |
| Hằng quý | Diễn tập khôi phục, scrub Btrfs bằng tay, kiểm tra pin UPS (khi có) | 🤖 + 👤 |
| Hằng năm | Rà bảng vòng đời mục 4.1, cập nhật `devices.json` (ngày mua, bảo hành), đổi MK thiết bị quan trọng, xoá node Tailscale cũ | 👤 |
