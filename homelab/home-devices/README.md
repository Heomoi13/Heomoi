# Thiết kế cải thiện hệ thống thiết bị trong nhà

> Dựa trên kiểm kê của Hermes ngày 22/11/2026 (`~/projects/device-inventory/devices.json`): ~60 thiết bị,
> 41 host sống — 9 camera Tapo, ~23 IoT (Tapo, Meross, BroadLink, Tuya, ESP32), 8 loa/TV, server, NAS, Mac.
> Quy tắc chung cho Hermes giống `homelab/README.md` mục 2 (cổng ⛔, 👤 việc của người, không in bí mật).

## Quy tắc riêng cho phần này (bắt buộc)

1. **Hermes không bao giờ đọc nội dung file chứa bí mật**: `go2rtc.yaml`, `~/homeassistant/config/secrets.yaml`,
   `.storage/` của Home Assistant, mọi `*.env`. Chỉ `ls -l`, `stat`, đếm dòng, so hash.
2. **Tài khoản cloud của hãng (Tapo, Meross, Tuya…) do 👤 chủ nhà tự nhập** vào giao diện Home Assistant.
   Hermes không nhận, không lưu, không đọc lại.
3. **Tài khoản chủ (owner) Home Assistant do 👤 chủ nhà tạo.** Nếu Hermes cần gọi API, chủ nhà tạo một
   user **không phải admin** và một long-lived token, tự dán vào `~/.config/ha.env` (600).
4. **Không đổi IP thiết bị đang chạy.** Chỉ đặt DHCP reservation cho IP hiện tại.
5. Mỗi tích hợp mới = 1 bước riêng, có kiểm tra, không làm nhiều hãng một lúc.

## Kiến trúc đích

```
                    Internet
                       │
              Deco BE65 (router + 2 vệ tinh)   UPnP TẮT · không port-forward · DNS → Pi-hole (+ dự phòng)
       ┌───────────────┼──────────────────┬─────────────────┐
  MẠNG CHÍNH         MẠNG IoT            MẠNG KHÁCH        Tailscale (từ xa)
  ├ homeserver       ├ 9 camera Tapo + hub H500
  │  ├ Home Assistant├ ổ cắm/đèn Tapo, Meross
  │  ├ go2rtc        ├ BroadLink, Tuya, ESP32
  │  └ Pi-hole       ├ robot hút bụi
  ├ NAS              └ Ring
  ├ Mac, iPhone, iPad
  ├ Sonos, HomePod mini, Apple TV, TV Hisense, Google Home   (cần AirPlay/mDNS)
        │
  Home Assistant ──HomeKit Bridge──▶ Apple Home (HomePod mini / Apple TV làm home hub) ──▶ iPhone, Siri
```

## Lộ trình

| GĐ | Nội dung | Chi phí | Phụ thuộc |
|---|---|---|---|
| A | Việc nhanh: UPnP, port-forward, DHCP reservation, MK camera, dọn Tailscale, DNS dự phòng | 0 | — |
| B | Kiểm kê sống + cảnh báo thiết bị lạ hằng tuần | 0 | A |
| **D** | **Home Assistant + HomeKit Bridge** (chi tiết bên dưới) | 0 | A |
| C | Tách mạng IoT (thử 1 ổ cắm + 1 camera trước) | 0 | D (để có bài test HA ↔ IoT) |
| E | Ghi hình camera (Frigate → NAS) — tuỳ chọn | 0 | quyết định riêng tư của gia đình |
| F | UPS, thay ổ NAS, router có VLAN nếu C không đủ | có | tiền |

D làm trước C: tách mạng xong mới cài HA thì không phân biệt được lỗi do HA hay do mạng.

---

## Giai đoạn A — việc nhanh (1 buổi tối)

| # | Việc | Ai | Ở đâu |
|---|---|---|---|
| A1 | Tắt UPnP | 👤 | App Deco → More → Advanced → NAT Forwarding → UPnP |
| A2 | Port Forwarding phải trống | 👤 | Cùng chỗ |
| A3 | DHCP reservation cho: homeserver, NAS, 9 camera, hub H500, Mac mini, iMac, HomePod, Apple TV, Sonos | 👤 | App Deco → Clients → thiết bị → Reserved Address (giữ IP hiện tại) |
| A4 | Đổi MK camera Tapo (chỉ chữ + số), sửa `go2rtc.yaml` bằng lệnh `read -s` | 👤 | App Tapo → camera → Advanced → Camera Account |
| A5 | Sửa camera carport (.59) và chuông Ring (.87) đang offline | 👤 | Nguồn điện / Wi-Fi |
| A6 | Xoá node Tailscale không dùng (apple-tv, iPhone/iPad cũ) | 👤 | login.tailscale.com → Machines |
| A7 | DNS phụ trên Deco | 👤 | App Deco → Advanced → DHCP Server → Secondary DNS |
| A8 | Cập nhật `devices.json`: cột `ip_reserved`, `network`, `owner`, `location` | 🤖 | sau A3 |

## Giai đoạn B — kiểm kê sống

- 🤖 Cron tuần (CN 10:00): quét ARP + ping toàn dải, so với `devices.json`.
  - MAC chưa có trong kiểm kê → Telegram (bot cảnh báo): `🆕 thiết bị mới: <hãng theo OUI> <IP>`.
  - Thiết bị có `critical: true` mất > 24 giờ → cảnh báo.
  - Chỉ in hãng/IP/MAC, không thăm dò dịch vụ của thiết bị lạ.
- 🤖 Kuma (👤 thêm monitor vì Hermes không còn quyền admin): TCP 554 cho 9 camera, ping 3 node Deco, hub H500, HTTP 8123 Home Assistant.

---

## Giai đoạn D — Home Assistant + Apple Home

### D0. Chuẩn bị (🤖, chỉ đọc)

- Kiểm tra cổng trống trên homeserver: `8123` (HA), `5580` (Matter server), `21063`–`21070` (HomeKit Bridge),
  `5353/udp` (mDNS, có thể đã dùng bởi avahi — HA dùng chung được). `ss -lntup | grep -E ':(8123|5580|2106[3-9]|21070)\b'`.
- Xác nhận go2rtc đang restream RTSP trên `127.0.0.1:8554` (HA sẽ đọc camera **qua go2rtc**, không chứa MK camera).
- Ghi lại bản HA stable mới nhất để **ghim phiên bản** (không dùng `:latest`).

### D1. Triển khai (🤖 soạn, ⛔ 👤 duyệt rồi chạy)

File mẫu: `compose/docker-compose.yml` cạnh tài liệu này → đặt tại `~/homeassistant/docker-compose.yml`.

```bash
mkdir -p ~/homeassistant/{config,matter}
cd ~/homeassistant && docker compose up -d && docker compose logs -f homeassistant   # đợi "Home Assistant initialized"
```

👤 Mở `http://192.168.0.88:8123` → tạo **tài khoản owner của chính anh** (MK lưu trình quản lý MK).
Bật xác thực 2 lớp: Profile → Security → Multi-factor authentication.

### D2. Tích hợp từng hãng (mỗi dòng một buổi, kiểm tra xong mới sang dòng sau)

| # | Hãng / thiết bị | Tích hợp | Chạy | Ghi chú |
|---|---|---|---|---|
| D2.1 | Sonos (6 loa) | **Sonos** (có sẵn, tự phát hiện) | cục bộ | Thử trước vì dễ nhất — kiểm tra mDNS/SSDP ổn |
| D2.2 | Tapo P100, P110M, L510E, hub H500 | **TP-Link Smart Home** (có sẵn) | cục bộ, cần tài khoản TP-Link khi thêm | 👤 nhập tài khoản. P110M có thể thêm qua **Matter** thay thế |
| D2.3 | 9 camera Tapo | **Generic Camera** trỏ vào go2rtc: `rtsp://127.0.0.1:8554/<tên>` | cục bộ | HA **không** giữ MK camera. Snapshot: `http://127.0.0.1:1984/api/frame.jpeg?src=<tên>` |
| D2.4 | BroadLink (.91) | **Broadlink** (có sẵn) | cục bộ | Học lệnh hồng ngoại → script → nút trong Apple Home |
| D2.5 | Meross MSS210 ×2, MSH400, 3 thiết bị chưa rõ | **Meross LAN** (qua HACS) | cục bộ | Cần cài HACS trước; 👤 nhập tài khoản Meross để lấy key một lần |
| D2.6 | Tuya (.70) | **Tuya** (chính hãng, cloud) → sau này **tuya-local** | cloud → cục bộ | Thấp ưu tiên |
| D2.7 | Robot hút bụi Tapo RV20 | TP-Link (nếu đã hỗ trợ ở bản HA đang ghim) | cục bộ | Không hỗ trợ → bỏ qua, dùng app Tapo |
| D2.8 | Bluetooth (TP-Link UB500 trên server) | **Bluetooth** (có sẵn) | cục bộ | Tuỳ chọn, cho cảm biến BLE sau này |
| D2.9 | ESP32 ×2 (.64, .76) | Xác định là gì trước (ESPHome? Tasmota?) | — | Chưa rõ → không làm |

Kiểm tra mỗi bước: thiết bị hiện trong HA, bật/tắt được, trạng thái cập nhật trong < 5 giây, khởi động lại HA vẫn còn.

### D3. HomeKit Bridge → Apple Home (🤖 cấu hình, 👤 ghép đôi)

- Settings → Devices & Services → Add → **HomeKit Bridge**, mode **bridge**, chỉ chọn các domain:
  `switch, light, fan, script, scene, sensor, binary_sensor, media_player` (loại trừ entity Sonos — Sonos có AirPlay riêng).
- Mỗi **camera** thêm một HomeKit Bridge riêng, mode **accessory** (Apple yêu cầu).
- 👤 Ghép đôi: app Nhà → Thêm phụ kiện → quét mã QR trong thông báo của HA.
- Đặt tên/phòng trong Apple Home theo `location` trong `devices.json`.
- Không có HomeKit Secure Video qua HA. Nếu sau này cần ghi hình iCloud → cân nhắc Scrypted cho riêng camera.

### D4. Kiểm tra ⛔ (bắt buộc trước khi dùng hằng ngày)

| # | Bài thử | Đạt khi |
|---|---|---|
| 1 | Bật/tắt 1 ổ cắm từ Apple Home (trong nhà) | < 2 giây |
| 2 | Tắt Wi-Fi iPhone, dùng 4G, bật/tắt lại | Chạy (qua home hub) |
| 3 | Siri: "tắt đèn phòng khách" | Chạy |
| 4 | Xem camera trong app Nhà | Có hình trong < 5 giây |
| 5 | `docker stop homeassistant` | Thiết bị qua bridge báo "Không phản hồi", thiết bị Matter gốc vẫn chạy; `docker start` → tự hồi phục |
| 6 | Khởi động lại homeserver | HA tự lên, Apple Home tự kết nối lại, không phải ghép đôi lại |

### D5. Tự động hoá (👤 chọn, 🤖 soạn YAML, ⛔ duyệt từng cái)

Gợi ý khởi đầu (ít, chắc chắn đúng, dễ tắt):
- Camera ngoài trời phát hiện người sau 22:00 → bật đèn + gửi ảnh qua bot cảnh báo.
- Cả nhà vắng (dựa vào iPhone trong Apple Home hoặc companion app HA) → tắt ổ cắm không cần thiết.
- Nút "Đi ngủ" → tắt loa, tắt đèn, bật camera trong nhà chế độ riêng tư (nếu Tapo hỗ trợ).

### D6. Backup và giám sát

- Bật **Backup tự động** của HA (hằng ngày, giữ 7) → `~/homeassistant/config/backups/`.
- Thêm vào `BACKUP_PATHS` của restic: `~/homeassistant/config/backups` và `~/homeassistant/docker-compose.yml`.
  **Không** backup thô `home-assistant_v2.db` (SQLite đang chạy) — bản backup của HA đã chứa nó an toàn.
- `mount_guard`/watchdog: thêm kiểm tra `http://127.0.0.1:8123/manifest.json` trả 200.
- Cập nhật HA: tối đa 1 lần/tháng, đọc release notes phần "Breaking changes" trước, backup trước, đổi tag ghim.

### Rủi ro và cách giảm

| Rủi ro | Giảm thiểu |
|---|---|
| Server chết → Apple Home "Không phản hồi" | UPS (GĐ F); thiết bị quan trọng ưu tiên Matter gốc; app hãng vẫn dùng được |
| HA cập nhật làm hỏng tích hợp | Ghim phiên bản; backup trước khi nâng; nâng có cổng duyệt |
| Tài khoản cloud hãng trong HA | Do 👤 nhập; nằm trong `.storage/` — Hermes không đọc; HA bật MFA |
| Tách mạng IoT (GĐ C) chặn HA | Bài test C bắt buộc gồm cả HA ↔ IoT; không đạt thì không chuyển |
