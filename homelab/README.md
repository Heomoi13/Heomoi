# Kế hoạch nâng cấp homelab — chỉ dẫn thực hiện cho Hermes

> Tài liệu này là **kịch bản thực hiện** cho Hermes Agent (chạy trên homeserver) và cho chủ nhà.
> Mọi lệnh đều chạy trên **homeserver** (192.168.0.88) bằng `sudo`, trừ khi ghi rõ.

## 1. Mục tiêu và phạm vi

**Vấn đề hiện tại** (theo sơ đồ homelab 21/11/2026):

| Rủi ro | Hậu quả |
|---|---|
| Dữ liệu gốc (26k ảnh, 10k video, sách, Data) nằm trên **1 ổ HDD desktop** Seagate ST3000DM003 | Hỏng ổ là mất bản gốc |
| Backup lên NAS **chưa bật** | Thực tế chỉ có 2 bản |
| rsync sang Mac M2 **ghi đè**, không có phiên bản | File hỏng / bị mã hoá sẽ chép đè lên bản tốt |
| Không có UPS | Mất điện đột ngột có thể hỏng RAID / Btrfs |
| 2 ổ WD Red trong NAS ~6 năm, cùng đợt | Dễ hỏng gần nhau, nhất là lúc rebuild |

**Đích đến:**

```
   NAS UGREEN (DỮ LIỆU GỐC)  RAID1 + Btrfs + snapshot
          │ NFS, mount tại /srv/nas (giữ nguyên đường dẫn → container không phải sửa)
          ▼
   Homeserver ── Immich / Syncthing / Calibre (Postgres + thumbnail trên NVMe)
          │ restic (có lịch sử phiên bản)
          ├──▶ HDD 3TB trong server  /srv/backup   hằng đêm 02:30   (bản 2)
          └──▶ Mac M2 /Volumes/Backup              hằng đêm 04:00   (bản 3)
```

**Ngoài phạm vi (chủ nhà đã quyết định):** không nâng card mạng 2,5G; chưa làm backup ngoài nhà (offsite).

**Thay đổi so với đề xuất ban đầu:** Syncthing **vẫn chạy trên server** (đọc/ghi qua NFS) thay vì chuyển sang NAS — ít thay đổi hơn,
và vì server là nơi duy nhất ghi vào thư mục đó nên cơ chế theo dõi thay đổi của Syncthing vẫn hoạt động.

## 2. Quy tắc bắt buộc cho Hermes

1. **Làm tuần tự từng giai đoạn.** Không nhảy cóc, không gộp giai đoạn.
2. **⛔ = CỔNG DỪNG.** Đến đó phải dừng, gửi báo cáo cho chủ nhà, và **chỉ tiếp tục khi có xác nhận rõ ràng**.
3. **👤 = việc của người** (thao tác trên giao diện UGOS, cắm dây, mua đồ). Hermes chỉ hướng dẫn và kiểm tra kết quả.
4. **Không bao giờ** in, gửi hay commit giá trị bí mật: token Telegram, URL Healthchecks, mật khẩu restic/NUT/DB.
5. **Không bao giờ** chạy `rm -rf`, `mkfs`, `wipefs`, `dd of=/dev/...` ngoài đúng bước được ghi trong tài liệu này.
6. Khi một script báo **KHÔNG ĐẠT** hoặc lỗi: **dừng lại và báo cáo**, không tự sáng tạo cách khác.
7. Không chạy các bước dừng dịch vụ (cutover, thay ổ) trong khung **01:30–05:30** (lịch backup) trừ khi chủ nhà yêu cầu.
8. Sau mỗi giai đoạn, ghi một báo cáo ngắn: đã làm gì, kết quả kiểm tra, bất thường. Log nằm ở `/var/log/homelab/`.

## 3. Cấu trúc thư mục

```
homelab/
├── README.md                     ← tài liệu này
├── install.sh                    ← cài script/unit, không bật gì
├── bin/
│   ├── lib.sh                    ← hàm dùng chung (log, Telegram, Healthchecks, khoá)
│   ├── 00-discover.sh            ← GĐ0: khảo sát, chỉ đọc
│   ├── setup-nfs.sh              ← GĐ1: kiểm tra và tạo automount NFS
│   ├── seed-to-nas.sh            ← GĐ1: sao lưu mồi hằng tuần lên NAS
│   ├── immich-db-dump.sh         ← dump Postgres của Immich
│   ├── nut-shutdown.sh           ← GĐ2: tắt máy có thứ tự khi UPS yếu pin
│   ├── nut-notify.sh             ← GĐ2: báo sự kiện UPS lên Telegram
│   ├── nas-precheck.sh           ← GĐ3/6: kiểm tra trước/sau thay ổ NAS
│   ├── cutover.sh                ← GĐ4: chuyển dữ liệu gốc sang NAS (+ rollback)
│   ├── prepare-backup-disk.sh    ← GĐ5: format HDD cũ thành ổ backup
│   ├── restic-init.sh / restic-backup.sh / restic-maintain.sh  ← GĐ5
│   ├── monitor.sh                ← GĐ5: giám sát mount, dung lượng, RAID, SMART NAS
│   └── restore-drill.sh          ← GĐ7: diễn tập khôi phục
├── config/                       ← mẫu cấu hình (→ /etc/homelab/)
├── systemd/                      ← service + timer (→ /etc/systemd/system/)
├── nut/                          ← cấu hình UPS (→ /etc/nut/)
└── compose/immich/               ← mẫu override thumbnail lên NVMe
```

## 4. Tổng quan tiến độ

| GĐ | Nội dung | Ai | Thời điểm | Dừng dịch vụ? |
|---|---|---|---|---|
| 0 | Khảo sát hiện trạng | 🤖 | Ngay | Không |
| 1 | Bật NFS + sao lưu mồi lên NAS | 👤 + 🤖 | Tuần 1 | Không |
| 2 | UPS + NUT | 👤 + 🤖 | Tuần 1–2 | Không |
| 3 | Thay ổ WD Red **thứ nhất** | 👤 + 🤖 | Tuần 2 (trước GĐ4) | Không |
| 4 | Cutover: dữ liệu gốc lên NAS | 🤖 (⛔) | Tuần 3, buổi tối | Immich ~1–4 giờ |
| 4b | Thumbnail Immich về NVMe | 🤖 | Sau GĐ4 ~1 tuần | Immich ~30 phút |
| 5 | restic + snapshot + giám sát | 👤 + 🤖 | Sau GĐ4 ≥ 14 ngày | Không |
| 6 | Thay ổ WD Red **thứ hai** | 👤 + 🤖 | 2–3 tháng sau GĐ3 | Không |
| 7 | Diễn tập khôi phục | 🤖 tự động | Mỗi quý | Không |

---

## Giai đoạn 0 — Khảo sát hiện trạng

**Vì sao:** kế hoạch giả định nhiều thứ (đường dẫn Immich, vị trí Postgres, dung lượng, quyền SSH vào NAS).
Phải biết chính xác trước khi đụng vào dữ liệu.

**0.1 🤖 Cài công cụ và script**

```bash
sudo apt update
sudo apt install -y rsync nfs-common wakeonlan smartmontools jq hdparm curl
cd ~/heomoi && git pull        # hoặc nơi Hermes clone repo này
sudo ./homelab/install.sh
```

restic: kiểm tra `restic version`. Nếu < 0.16 (bản apt của Ubuntu thường cũ), cài bản chính thức:

```bash
RV=0.17.3
curl -fsSL -o /tmp/restic.bz2 "https://github.com/restic/restic/releases/download/v${RV}/restic_${RV}_linux_amd64.bz2"
bunzip2 -f /tmp/restic.bz2 && sudo install -m 0755 /tmp/restic /usr/local/bin/restic && restic version
```

**0.2 🤖 SSH không mật khẩu từ root của server** (script chạy bằng root):

```bash
sudo test -f /root/.ssh/id_ed25519 || sudo ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519
sudo ssh-copy-id nando@192.168.1.123        # 👤 nhập mật khẩu NAS một lần
sudo ssh-copy-id <user-mac>@192.168.0.77    # 👤 nhập mật khẩu Mac một lần (Mac: bật Remote Login)
```

Thêm vào `/root/.ssh/config` để restic/ssh không bao giờ treo chờ mật khẩu:

```
Host 192.168.1.123 192.168.0.77
    BatchMode yes
    ConnectTimeout 10
    ServerAliveInterval 30
```

**0.3 🤖 Chạy khảo sát**

```bash
sudo /opt/homelab/bin/00-discover.sh
```

Báo cáo: `/var/lib/homelab/reports/discovery-*.md` (đã che bí mật).

**0.4 🤖 Điền cấu hình** `/etc/homelab/homelab.env` từ báo cáo — mọi dòng `CHANGE_ME`:
`MAC_M2_USER`, `RESTIC_REPO_MAC`, `OLD_HDD_PART` (đường dẫn `/dev/disk/by-id/ata-ST3000DM003-…-part1`),
`IMMICH_COMPOSE_DIR`, `IMMICH_UPLOAD_HOST`, `IMMICH_DB_CONTAINER`. Đề xuất bổ sung `BACKUP_PATHS`
(thư mục compose của các stack, config Home Assistant, config Calibre…).

`/etc/homelab/secrets.env`: lấy token Telegram từ script cảnh báo SMART hiện có. Để trống `HC_*` cho đến khi 👤 tạo check.

⛔ **CỔNG 0 — gửi chủ nhà:** báo cáo khảo sát + mục 12 "Việc cần người quyết định" + cấu hình đề xuất. Đặc biệt:
- Dung lượng dữ liệu so với: chỗ trống trên NAS, ổ Mac 1,8TB, ổ backup 3TB.
- Postgres của Immich có nằm trong `/srv/nas` không (nếu có → bước 4.1 bắt buộc).
- Danh sách file SQLite trong `/srv/nas` và đề xuất xử lý từng file.
- Danh sách container sẽ bị dừng khi cutover.
- NAS có `SUDO_NOPASSWD=yes` không (cần cho SMART và lệnh tắt NAS khi mất điện).

---

## Giai đoạn 1 — Bật NFS và sao lưu mồi lên NAS

**Vì sao:** có ngay bản sao thứ 3 trước khi làm bất cứ thay đổi nào, và bản này là "mồi" để GĐ4 chỉ phải chép
phần chênh lệch (vài phút thay vì 5–6 giờ trong lúc dừng dịch vụ).
Dùng NFS thay SMB vì NFS giữ đúng chủ sở hữu/quyền file Linux mà container cần.

**1.1 👤 Trên UGOS** (tên menu có thể khác đôi chút theo phiên bản):
- Bảng điều khiển → Dịch vụ file → **bật NFS** (bật NFSv4.1 nếu có lựa chọn).
- Thư mục chia sẻ `data` → Quyền NFS → thêm quy tắc:
  máy khách `192.168.0.88` · đọc/ghi · **squash: không ánh xạ (no mapping / no_root_squash)** · đồng bộ (sync).
- Bật SSH (nếu chưa bật lâu dài).
- (Khuyến nghị) Cho user `nando` chạy `smartctl` và `shutdown` bằng sudo không mật khẩu.
  Nếu UGOS không cho phép: bật thông báo sức khoẻ ổ đĩa của UGOS (email/app) thay thế.

**1.2 🤖 Kiểm tra NFS** (chỉ mount thử rồi gỡ):

```bash
showmount -e 192.168.1.123            # xác nhận đường dẫn export, sửa NAS_NFS_EXPORT nếu khác
sudo /opt/homelab/bin/setup-nfs.sh test
```

Đạt khi: ghi được, root đổi được chủ sở hữu file, tốc độ ~100+ MB/s. Nếu `vers=4.1` lỗi, thử `NFS_OPTS` với `vers=3`.

**1.3 🤖 Tạo automount + thư mục + sentinel**

```bash
sudo /opt/homelab/bin/setup-nfs.sh apply
```

**1.4 👤 Healthchecks.io:** tạo check `homelab-seed` (chu kỳ 7 ngày, ân hạn 1 ngày), dán URL vào `HC_SEED`.

**1.5 🤖 Chạy lần đầu bằng tay** (có thể mất 5–6 giờ, chạy buổi tối):

```bash
sudo systemctl start --no-block homelab-seed.service
journalctl -fu homelab-seed.service          # theo dõi
```

**1.6 🤖 Kiểm tra và bật lịch tuần:**

```bash
sudo rsync -aHn --numeric-ids -i --exclude-from=/etc/homelab/excludes.txt /srv/nas/ /mnt/nas-data/homelab/ | grep -v '^\.d\.\.t' | wc -l   # nên = 0 hoặc rất nhỏ
sudo systemctl enable --now homelab-seed.timer
```

Xoá hoặc comment dòng cron cũ "CN 03:00 → NAS /mnt/nas-ugreen (chưa bật)" nếu có, để không trùng.

✅ **Xong khi:** `/var/lib/homelab/seed.last_ok` có ngày hôm nay, Healthchecks xanh.

---

## Giai đoạn 2 — UPS và tắt máy có thứ tự

**Vì sao:** mất điện lúc mdadm/Btrfs đang ghi là cách nhanh nhất để hỏng RAID, và GĐ3 (rebuild 7–8 giờ) rất nhạy cảm.
Sau GĐ4, Immich ghi qua NFS lên NAS → **server phải tắt trước NAS**, nên server điều khiển thứ tự tắt.

**2.1 👤 Phần cứng:**
- UPS line-interactive ~1000VA, có cổng USB, ưu tiên sóng sin chuẩn (pure sine) nếu PSU server có Active PFC.
- Cắm vào UPS: **homeserver, NAS, router Deco** (Deco giữ Internet để còn gửi được Telegram). Tải ~100–150W → ~10–15 phút.
- Cáp USB của UPS → **homeserver**.
- Trong UGOS: nếu có mục UPS mạng / NUT client → trỏ về `192.168.0.88` (xem 2.4). Nếu không, đặt NAS tự tắt khi mất điện quá 10 phút làm lớp dự phòng.

**2.2 🤖 Cài NUT:**

```bash
sudo apt install -y nut
sudo nut-scanner -U                     # xác nhận driver (thường usbhid-ups)
sudo cp homelab/nut/{nut.conf,ups.conf,upsd.conf,upsd.users,upsmon.conf} /etc/nut/
P=$(openssl rand -hex 16)
sudo sed -i "s/CHANGE_ME_LOCAL/$P/" /etc/nut/upsd.users /etc/nut/upsmon.conf
sudo chown root:nut /etc/nut/upsd.users /etc/nut/upsmon.conf && sudo chmod 640 /etc/nut/upsd.users /etc/nut/upsmon.conf
# File Telegram riêng cho NOTIFYCMD (chạy bằng user nut):
sudo sh -c 'grep -E "^TELEGRAM_(BOT_TOKEN|CHAT_ID)=" /etc/homelab/secrets.env > /etc/homelab/telegram.env'
sudo chown root:nut /etc/homelab/telegram.env && sudo chmod 640 /etc/homelab/telegram.env
sudo chmod 711 /etc/homelab
sudo systemctl restart nut-driver.target nut-server nut-monitor 2>/dev/null || sudo systemctl restart nut-driver nut-server nut-monitor
upsc ups@localhost                      # phải thấy battery.charge, ups.status = OL
```

Nếu UPS không chấp nhận `override.battery.charge.low`, bỏ 3 dòng `ignorelb/override.*` trong `ups.conf`.

**2.3 🤖 Chạy thử thứ tự tắt (KHÔNG tắt thật):**

```bash
sudo /opt/homelab/bin/nut-shutdown.sh --dry-run
```

Kết quả phải liệt kê: dừng container → gỡ mount → lệnh tắt NAS (báo `sudo shutdown: OK`) → tắt server.

**2.4 (Tuỳ chọn) NAS tự theo dõi UPS qua mạng:** đổi `MODE=netserver`, bỏ comment `LISTEN 192.168.0.88` và user `[monuser]`
(mật khẩu riêng), khởi động lại `nut-server`, rồi nhập thông tin vào UGOS.

⛔ **CỔNG 2 — 👤 thử thật:** vào lúc rảnh, rút điện UPS khỏi ổ cắm 1–2 phút → phải nhận Telegram "ONBATT", cắm lại → "ONLINE".
(Không cần để cạn pin; thứ tự tắt đã kiểm ở 2.3.)

---

## Giai đoạn 3 — Thay ổ WD Red thứ nhất (trước khi chuyển dữ liệu gốc)

**Vì sao:** rebuild RAID1 bắt ổ còn lại đọc liên tục 7–8 giờ — lúc dễ hỏng ổ già nhất.
Làm **bây giờ**, khi NAS mới chỉ giữ bản mồi, thì nếu ổ còn lại chết cũng không mất dữ liệu gốc.
Thay so le 2 ổ để chúng không cùng tuổi.

**Chọn ổ:** ổ NAS loại **CMR** (WD Red Plus, Seagate IronWolf, Toshiba N300). **Không** dùng WD Red không có chữ "Plus" (SMR).
Cân nhắc 8TB: RAID1 chỉ tăng dung lượng sau khi thay cả 2 ổ, nhưng không phải mua lại khi kho ảnh lớn lên.

**3.1 🤖 Kiểm tra trước:**

```bash
sudo /opt/homelab/bin/nas-precheck.sh before
```

Phải ĐẠT: RAID `[UU]`, không đang resync, UPS chạy. Gửi kèm SMART 2 ổ để 👤 chọn **ổ yếu hơn** để thay trước
(nhiều sector reallocated/pending hơn, hoặc nhiều giờ chạy hơn).

⛔ **CỔNG 3 — 👤 thay ổ trên UGOS** (không dùng `mdadm` bằng tay):
Quản lý lưu trữ → chọn ổ cần thay → tháo ổ (hoặc đánh dấu hỏng) → lắp ổ mới cùng khay → chọn **Sửa chữa / Repair** cho pool.

**3.2 🤖 Theo dõi rebuild** (mỗi 1–2 giờ, không can thiệp):

```bash
sudo /opt/homelab/bin/nas-precheck.sh rebuild
```

**3.3 🤖 Kiểm tra sau:**

```bash
sudo /opt/homelab/bin/nas-precheck.sh after
```

👤 Chạy **scrub Btrfs** trong UGOS sau khi rebuild xong và đặt lịch scrub hằng tháng.
👤 Giữ ổ WD Red cũ (nếu SMART còn tốt) làm ổ backup "nguội" — ghi chú ngày tháo.

---

## Giai đoạn 4 — Cutover: chuyển dữ liệu gốc lên NAS

**Vì sao:** NAS có RAID1 (chịu được hỏng 1 ổ), Btrfs (phát hiện dữ liệu hỏng âm thầm, có snapshot) — an toàn hơn hẳn ổ desktop đơn.

**Cách làm:** giữ nguyên đường dẫn `/srv/nas`. Sau cutover nó là mount NFS từ `NAS:/volume1/data/homelab`;
ổ HDD cũ chuyển sang `/mnt/old-hdd` **chỉ đọc**. Không container nào phải sửa đường dẫn.
Thư mục `/srv/nas` gốc trên NVMe bị khoá `chattr +i` → nếu NFS không mount được, **không gì ghi nhầm vào đó**;
Immich sẽ tự từ chối khởi động vì không thấy file `.immich`.

**4.1 🤖 (Chỉ khi GĐ0 phát hiện) Chuyển Postgres của Immich về NVMe** — database **không bao giờ** được nằm trên NFS:

```bash
cd "$IMMICH_COMPOSE_DIR"
sudo /opt/homelab/bin/immich-db-dump.sh              # dump phòng thân
docker compose down
sudo mkdir -p /srv/fast/immich/postgres
sudo rsync -aH --numeric-ids <DB_DATA_LOCATION cũ>/ /srv/fast/immich/postgres/
# sửa .env: DB_DATA_LOCATION=/srv/fast/immich/postgres
docker compose up -d && docker compose logs -f database   # kiểm tra Postgres khởi động sạch
```

Giữ thư mục DB cũ đến khi xong GĐ4. Làm tương tự với file SQLite khác mà chủ nhà quyết định chuyển ở cổng 0.

**4.2 🤖 Preflight và đồng bộ trước** (dịch vụ vẫn chạy, làm vào ngày trước hoặc vài giờ trước):

```bash
sudo /opt/homelab/bin/cutover.sh preflight
sudo /opt/homelab/bin/cutover.sh sync          # lặp lại được; lần sau nhanh hơn
```

👤 Trên UGOS: **tắt ngủ đông ổ / tắt máy theo lịch** của NAS — từ giờ NAS phải chạy 24/7.

⛔ **CỔNG 4 — gửi chủ nhà:** kết quả preflight (tất cả ✅), danh sách container sẽ dừng, thời gian dự kiến.
Chỉ tiếp tục khi chủ nhà trả lời "đồng ý cutover". Nên làm buổi tối, ngoài khung 01:30–05:30.

**4.3 🤖 Cutover:**

```bash
sudo CONFIRM=YES /opt/homelab/bin/cutover.sh switch
# Nếu chủ nhà đã chấp nhận file SQLite ở cổng 0:  sudo CONFIRM=YES ACK_SQLITE=yes /opt/homelab/bin/cutover.sh switch
```

Script tự làm: dừng container → chép lần cuối (`--delete`) → **so checksum toàn bộ** (có thể mất 3–4 giờ với ~1,5TB) →
gỡ HDD → khoá thư mục → sửa `/etc/fstab` (có bản sao) → mount NFS + HDD chỉ đọc → chạy lại container → tắt timer seed.
Bất kỳ bước nào lỗi trước khi đổi mount: dịch vụ chạy lại trên HDD, **không mất gì**. Lỗi ở bước mount: tự quay về bố cục cũ.

**4.4 🤖 Kiểm tra sau cutover:**

```bash
sudo /opt/homelab/bin/cutover.sh status
findmnt /srv/nas                 # phải là nfs từ 192.168.1.123
docker ps                        # mọi container Up, không restart liên tục
docker logs --tail 50 immich_server
```

👤 Kiểm tra thực tế: mở Immich xem album cũ, **tải lên 1 ảnh mới từ điện thoại**, xem Syncthing đồng bộ, mở Calibre/Kobo.

🤖 Cron rsync sang Mac M2 lúc 02:30 **giữ nguyên** (nguồn vẫn là `/srv/nas`, giờ đọc qua NFS) — đây là bản sao thứ 3 trong thời gian chờ GĐ5.

**Đường lui (trong 14 ngày đầu):**

```bash
sudo CONFIRM=YES /opt/homelab/bin/cutover.sh rollback
```

Chép các file mới từ NAS về HDD (không xoá gì), khôi phục fstab, chạy lại dịch vụ trên HDD.

✅ **Xong khi:** chạy ổn định ≥ 14 ngày, không lỗi trong log Immich, Healthchecks xanh.

---

## Giai đoạn 4b — Thumbnail và video encode của Immich về NVMe (khuyến nghị)

**Vì sao:** thumbnail là hàng chục nghìn file nhỏ được đọc liên tục khi cuộn timeline — NVMe nhanh hơn NFS rất nhiều.
Chúng tạo lại được nên không cần nằm trên NAS và không cần backup.

```bash
cd "$IMMICH_COMPOSE_DIR"
docker inspect immich_server -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'   # xác định đường dẫn trong container (/data hay /usr/src/app/upload)
docker compose stop immich-server
sudo mkdir -p /srv/fast/immich
sudo rsync -aH --numeric-ids "$IMMICH_UPLOAD_HOST/thumbs/" /srv/fast/immich/thumbs/
sudo rsync -aH --numeric-ids "$IMMICH_UPLOAD_HOST/encoded-video/" /srv/fast/immich/encoded-video/
cp /path/to/homelab/compose/immich/docker-compose.override.yml.example docker-compose.override.yml   # sửa /data nếu khác; gộp nếu đã có override
docker compose up -d
```

Kiểm tra Immich hiển thị thumbnail bình thường 1 tuần, rồi mới xoá `thumbs/` và `encoded-video/` cũ trên NAS (⛔ hỏi chủ nhà trước khi xoá).
Đặt `BACKUP_EXCLUDE_PATHS="$IMMICH_UPLOAD_HOST/thumbs $IMMICH_UPLOAD_HOST/encoded-video"` trong `homelab.env`.

---

## Giai đoạn 5 — Backup restic, snapshot, giám sát

**Vì sao:** rsync ghi đè → file hỏng/bị mã hoá sẽ đè lên bản tốt. restic giữ nhiều phiên bản (7 ngày, 4 tuần, 12 tháng),
loại bỏ dữ liệu trùng (dedup), và kiểm tra được tính toàn vẹn. Snapshot Btrfs trên NAS cho phép lấy lại file xoá nhầm trong vài giây.

**Thứ tự quan trọng vì Mac chỉ có 1,8TB:** làm kho local trước → xác nhận → mới xoá bản rsync cũ trên Mac để lấy chỗ cho kho restic.

**5.1 👤 Snapshot Btrfs trên UGOS** cho share `data` (nếu UGOS hỗ trợ): hằng giờ giữ 24, hằng ngày giữ 14, hằng tuần giữ 8.
🤖 Sau khi bật: `ls -la /srv/nas /mnt/nas-data` để xem thư mục snapshot có lộ ra qua NFS không và tên gì; nếu tên khác các mẫu
trong `config/restic-excludes.txt` và `config/excludes.txt` thì thêm vào (tránh backup snapshot nhiều lần).

**5.2 👤 Healthchecks.io:** tạo các check và dán URL vào `secrets.env`:

| Check | Biến | Chu kỳ | Ân hạn |
|---|---|---|---|
| homelab-backup-local | `HC_BACKUP_LOCAL` | 1 ngày | 3 giờ |
| homelab-backup-mac | `HC_BACKUP_MAC` | 1 ngày | 3 giờ |
| homelab-maintain | `HC_MAINTAIN` | 7 ngày | 1 ngày |
| homelab-monitor | `HC_MONITOR` | 1 giờ | 30 phút |

**5.3 🤖 Format HDD 3TB thành ổ backup** (sau cutover ≥ 14 ngày):

⛔ **CỔNG 5a — chủ nhà xác nhận:** "đồng ý xoá ổ HDD cũ" + đường dẫn partition đúng như trong `homelab.env`.

```bash
sudo CONFIRM_DEVICE=/dev/disk/by-id/ata-ST3000DM003-...-part1 /opt/homelab/bin/prepare-backup-disk.sh
echo '/dev/disk/by-id/ata-ST3000DM003-...  { spindown_time = 241 }' | sudo tee -a /etc/hdparm.conf   # đĩa, không phải partition
```

Script tự từ chối nếu: sai đường dẫn, không phải ổ ST3000DM003, dữ liệu gốc chưa ở NAS, hoặc cutover chưa đủ 14 ngày.

**5.4 🤖 Kho restic local:**

```bash
sudo /opt/homelab/bin/restic-init.sh local
```

⛔ **CỔNG 5b — 👤 sao lưu mật khẩu restic** vào trình quản lý mật khẩu (`sudo cat /etc/homelab/restic.pass`).
**Mất file này = mất toàn bộ backup.** Hermes không được tự in mật khẩu vào chat/báo cáo — chủ nhà tự chạy lệnh trên.

```bash
sudo systemctl start homelab-backup-local.service      # lần đầu: vài giờ
journalctl -u homelab-backup-local.service --no-pager | tail -30
sudo restic -r /srv/backup/restic --password-file /etc/homelab/restic.pass snapshots
sudo systemctl enable --now homelab-backup-local.timer
```

**5.5 🤖 Chuyển Mac M2 từ rsync sang restic** (sau khi 5.4 đã chạy thành công ≥ 2 đêm):

⛔ **CỔNG 5c — chủ nhà xác nhận** xoá bản rsync cũ trên Mac (đường dẫn cụ thể lấy từ cron cũ ở báo cáo GĐ0).

1. Tắt dòng cron rsync 02:30 cũ (comment lại, ghi chú ngày).
2. Xoá thư mục bản rsync cũ trên Mac theo đúng đường dẫn đã được xác nhận.
3. Khởi tạo và chạy:

```bash
sudo /opt/homelab/bin/restic-init.sh mac
sudo systemctl start homelab-backup-mac.service
sudo systemctl enable --now homelab-backup-mac.timer
```

Trong lúc giữa bước 2 và khi backup Mac đầu tiên xong, vẫn có: NAS (RAID1 + snapshot) + kho restic local.

**5.6 🤖 Bảo trì và giám sát:**

```bash
sudo systemctl enable --now homelab-maintain.timer homelab-monitor-storage.timer homelab-nas-health.timer
sudo /opt/homelab/bin/monitor.sh storage && sudo /opt/homelab/bin/monitor.sh nas-health
```

Cập nhật script "mount guard 15 phút" hiện có: kiểm tra `/srv/nas` là NFS **và** có file `.nas-homelab-sentinel`.
Cảnh báo SMART của ổ 3TB (ID 5/197/198/199) **giữ nguyên** — ổ backup chết mà không ai biết là bẫy phổ biến nhất.
👤 Trong Uptime Kuma (Pi VN): thêm monitor TCP `192.168.1.123:2049` qua Tailscale nếu NAS truy cập được, hoặc dựa vào `HC_MONITOR`.

✅ **Xong khi:** cả 2 kho có snapshot đêm qua, Healthchecks xanh hết, `monitor.sh` không báo lỗi.

---

## Giai đoạn 6 — Thay ổ WD Red thứ hai (2–3 tháng sau GĐ3)

Giống GĐ3, thêm điều kiện: `nas-precheck.sh before` yêu cầu backup local thành công trong 48 giờ (vì NAS giờ giữ dữ liệu gốc).

```bash
sudo /opt/homelab/bin/nas-precheck.sh before
# ⛔ 👤 thay ổ trên UGOS
sudo /opt/homelab/bin/nas-precheck.sh rebuild
sudo /opt/homelab/bin/nas-precheck.sh after
```

Nếu mua ổ lớn hơn: sau khi cả 2 ổ đã thay, 👤 mở rộng pool/volume trong UGOS. Xoá file `/var/lib/homelab/smart-<serial-cũ>-*`.

---

## Giai đoạn 7 — Diễn tập khôi phục (mỗi quý)

**Vì sao:** backup chưa từng thử khôi phục thì không đáng tin.

```bash
sudo systemctl enable --now homelab-restore-drill.timer    # 15/1, 15/4, 15/7, 15/10 lúc 10:00
sudo /opt/homelab/bin/restore-drill.sh local               # chạy thử ngay
```

Lấy ngẫu nhiên 20 file từ snapshot mới nhất so SHA-256 với file đang có, kiểm tra bản dump DB Immich giải nén được. Kết quả gửi Telegram.
👤 Mỗi năm một lần: khôi phục thử một album Immich hoàn chỉnh (ảnh + dump DB) ra máy khác.

---

## 6. Lịch chạy sau khi hoàn tất

| Giờ | Việc | Thay thế |
|---|---|---|
| Hằng giờ | `homelab-monitor-storage` | — |
| 02:30 hằng đêm | `homelab-backup-local` (restic → HDD 3TB) | cron rsync → Mac 02:30 |
| 04:00 hằng đêm | `homelab-backup-mac` (restic → Mac M2) | — |
| 08:10 hằng ngày | `homelab-nas-health` (RAID + SMART NAS) | — |
| CN 06:00 | `homelab-maintain` (prune + check 5%) | — |
| Mỗi quý | `homelab-restore-drill` | — |
| ~~CN 03:00~~ | ~~`homelab-seed`~~ | tự tắt sau cutover |

## 7. Xử lý sự cố nhanh

| Triệu chứng | Kiểm tra | Xử lý |
|---|---|---|
| Immich lỗi, không thấy ảnh | `findmnt /srv/nas` | NAS tắt/mạng rớt → bật NAS, `sudo mount /srv/nas`, `docker restart immich_server` |
| `mount /srv/nas` treo | `ping 192.168.1.123`, `rpcinfo -p 192.168.1.123` | NFS trên UGOS bị tắt/quy tắc IP sai |
| Backup báo "không phải NFS có sentinel" | `ls -la /srv/nas/.nas-homelab-sentinel` | Đúng thiết kế: không backup thư mục rỗng. Sửa mount trước |
| restic báo khoá kho | `restic -r ... list locks` | Chỉ khi chắc không còn restic nào chạy: `restic -r ... unlock` |
| RAID degraded | `nas-precheck.sh rebuild` | Đảm bảo backup local mới → thay ổ theo GĐ6 |
| Mất điện | Telegram ONBATT | Tự động; sau khi có điện: bật NAS trước, rồi server |

## 8. Thứ tự bật lại sau khi tắt toàn bộ

**NAS trước → chờ UGOS lên hẳn (~3 phút) → server.** Nếu server lên trước, `/srv/nas` sẽ chờ tối đa 60 giây rồi bỏ qua;
khi đó chạy `sudo mount /srv/nas && docker restart immich_server` (và các container dùng `/srv/nas`).
