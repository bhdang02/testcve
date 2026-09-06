# Quy trình tạo VM và import `AI.qcow2` — host `pve` (192.168.1.80)

Runbook viết theo đúng hiện trạng hệ thống của bạn tại thời điểm báo cáo. Mọi lệnh chạy bằng `root` trên host PVE.

---

## Hiện trạng hệ thống

| Hạng mục | Giá trị thực tế | Ý nghĩa |
|---|---|---|
| Proxmox | 9.2.2, kernel 7.0.2-6-pve | Có `qm disk import` và `import-from` — nhanh hơn `importdisk` cũ |
| CPU | 2 × Xeon E5-2696 v4, 22 core/socket, 88 threads | Broadwell, hỗ trợ `x86-64-v3` → `--cpu host` chạy được Rocky 9 |
| NUMA | 2 node | VM lớn cần `--numa 1` |
| RAM | 78 GiB tổng, 75 GiB trống | **Trần thực tế cho VM là ~64 GiB**, không phải 768 GB như kế hoạch ban đầu |
| Thin pool | `pve/data` 3.49 TiB, dùng 4.76% | Thừa chỗ cho image 120 GiB |
| Root fs | `pve-root` 94 GB, dùng 18% | Đủ chỗ, không còn tình trạng đầy như trước |
| Mạng | `vmbr0` 192.168.1.80/24, gw .1, DNS 8.8.8.8, ping ra ngoài OK | Dùng `vmbr0` cho VM. `vmbr1` không có port vật lý |
| VM hiện có | **Không có VM nào** | VMID 100 và 101 đều trống, làm lại từ đầu |
| File nguồn | `/mnt/staging/AI.qcow2` — 120 GiB virtual, **2.86 GiB thực** | Image rất sparse, import sẽ nhanh hơn nhiều lần dự đoán cũ |

### Ba điểm cần biết trước khi bắt đầu

**1. `/mnt/staging` không được mount.** `df` cho thấy đường dẫn này trỏ về `pve-root`, tức LV `pve/staging` (300 GB) đang nằm không và file qcow2 thực ra nằm trên root filesystem. LV này vẫn chiếm ~150 GB trong thin pool mà không dùng vào việc gì.

**2. Image sparse.** File chỉ 2.86 GiB dữ liệu thật trên 120 GiB dung lượng danh nghĩa. `qemu-img` bỏ qua vùng zero nên thời gian import ngắn hơn nhiều so với ước tính trước đây.

**3. Đặc điểm image (đã xác minh bằng `qemu-nbd`).**

| Hạng mục | Giá trị | Ảnh hưởng |
|---|---|---|
| Partition table | GPT + `bios_grub`, **không có ESP** | → `--bios seabios`, `--machine pc` |
| Layout | p1 `bios_grub` 1MB · p2 `/boot` xfs 2.1GB · p3 LVM 127GB | Trọn vẹn trong 1 PV |
| VG `rl` | root 100.12g, home 10.00g, swap 7.88g, PFree 0 | Rocky Linux, VG đã dùng hết PV |
| Driver | Initramfs thiếu `virtio_scsi` | → gắn `sata0` trước, đổi `scsi0` sau |

---

## Giai đoạn 0 — Dọn dẹp trước khi làm

### 0.1 Giải phóng LV staging (khuyến nghị)

LV này không được mount nhưng vẫn giữ chỗ trong pool. Chuyển file qcow2 ra ngoài rồi xóa:

```bash
mkdir -p /var/lib/vz/import
mv /mnt/staging/AI.qcow2 /var/lib/vz/import/
lvremove pve/staging
rmdir /mnt/staging
lvs pve                     # xác nhận staging đã biến mất
```

Đặt file vào `/var/lib/vz/import` có lợi thêm: storage `local` của bạn đã bật content type `import`, nên file sẽ hiện trong GUI ở mục **local → Import**, dùng được cả bằng wizard nếu muốn.

Nếu muốn giữ LV staging thì phải mount đúng cách:

```bash
mount /dev/pve/staging /mnt/staging
```

### 0.2 Xác nhận không còn VM cũ

```bash
qm list
ls -l /etc/pve/qemu-server/
lvs pve | grep vm-
```

Cả ba phải trống. Nếu còn LV `vm-1xx-disk-x` mồ côi thì xóa:

```bash
lvremove pve/vm-101-disk-0
```

---

## Giai đoạn 1 — Chọn cấu hình VM

Host có 88 threads và 78 GiB RAM. Ba mức gợi ý:

| Mức | sockets/cores | memory | Dùng khi |
|---|---|---|---|
| Nhẹ — test boot trước | 1 / 4 | 8192 | Chỉ để xác nhận image boot được |
| Vừa | 1 / 16 | 32768 | Workload thông thường |
| Nặng | 2 / 16 (32 vCPU) | 65536 + `--numa 1` | Workload AI/inference dùng nhiều RAM |

Hai lưu ý về host này:

- **Đừng cấp quá 64 GiB.** Host chỉ có 78 GiB, cần chừa cho PVE và ZFS/page cache.
- **Vượt 39 GiB RAM là VM trải qua 2 NUMA node.** Khi đó bắt buộc `--numa 1` và nên đặt `--sockets 2`, nếu không hiệu năng memory access sẽ giảm rõ rệt trên Xeon E5 v4.

Cách an toàn: tạo mức nhẹ để xác nhận image boot được trước, chỉnh lên sau bằng `qm set` (không cần import lại).

---

## Giai đoạn 2 — Tạo VM rỗng

```bash
qm create 101 \
  --name ai-rocky \
  --ostype l26 \
  --machine pc \
  --bios seabios \
  --cpu host \
  --sockets 1 \
  --cores 4 \
  --memory 8192 \
  --balloon 0 \
  --scsihw virtio-scsi-single \
  --net0 virtio,bridge=vmbr0 \
  --agent enabled=1 \
  --onboot 1
```

| Tham số | Lý do với hệ thống này |
|---|---|
| `--bios seabios` + `--machine pc` | Image có `bios_grub`, không có ESP. Bật `ovmf` sẽ không boot |
| `--cpu host` | Rocky 9 cần `x86-64-v2`; `kvm64` mặc định gây kernel panic. E5-2696 v4 đáp ứng thoải mái |
| `--balloon 0` | Tắt ballooning — workload AI không nên để RAM bị thu hồi động |
| `--net0 ... bridge=vmbr0` | `vmbr0` là bridge duy nhất có port vật lý (`nic0`) |
| `--scsihw virtio-scsi-single` | Chuẩn bị cho bước chuyển sang `scsi0` + `iothread` |
| `--onboot 1` | Tự khởi động cùng host |

Nếu chọn mức nặng, thêm:

```bash
qm set 101 --sockets 2 --cores 16 --memory 65536 --numa 1
```

---

## Giai đoạn 3 — Import và gắn disk (một bước)

PVE 9 cho phép import và attach cùng lúc. Gắn thẳng vào **SATA** vì image thiếu driver virtio:

```bash
qm set 101 --sata0 local-lvm:0,import-from=/var/lib/vz/import/AI.qcow2,discard=on
```

Cú pháp `local-lvm:0` nghĩa là để Proxmox tự quyết dung lượng theo image nguồn.

Chạy trong `tmux` nếu SSH không ổn định:

```bash
tmux new -s import
# Ctrl+b rồi d để detach, tmux attach -t import để quay lại
```

### Cách hai — hai bước rời (nếu `import-from` báo lỗi)

```bash
qm disk import 101 /var/lib/vz/import/AI.qcow2 local-lvm
qm config 101 | grep unused
qm set 101 --sata0 local-lvm:vm-101-disk-0,discard=on
```

### Theo dõi

```bash
iostat -x 2
watch -n2 "grep -E 'Dirty|Writeback' /proc/meminfo"
```

Vì image chỉ có 2.86 GiB dữ liệu thật, quá trình này thường chỉ vài phút. Log vẫn đếm tới `120.0 GiB (100.00%)` vì đó là virtual size, không phải lượng dữ liệu thực ghi xuống.

**Sau khi log hiện 100% vẫn chưa xong** — còn flush cache và ghi metadata LVM. Dấu hiệu bình thường: `Dirty` ≈ 0, `Writeback` giảm dần. Đợi prompt trả về, đừng `Ctrl+C` (đó chính là nguyên nhân VM 100 bị treo `lock: create` lần trước).

### Kiểm tra sau import

```bash
qm config 101
lvs pve | grep vm-101
```

Cần thấy `sata0: local-lvm:vm-101-disk-0,discard=on,size=120G`.

---

## Giai đoạn 4 — Cấu hình boot và khởi động

```bash
qm set 101 --boot order=sata0
qm start 101
qm status 101
```

Xem console: GUI → node `pve` → VM 101 → **Console** (noVNC).

Trình tự boot đúng: SeaBIOS → GRUB → kernel → mount `/dev/mapper/rl-root` → màn hình login.

---

## Giai đoạn 5 — Cấu hình mạng trong VM

Dải mạng host là `192.168.1.0/24`, gateway `192.168.1.1`. Đặt IP tĩnh cho VM (ví dụ `.81`):

```bash
nmcli con mod "$(nmcli -g NAME con show --active | head -1)" \
  ipv4.method manual \
  ipv4.addresses 192.168.1.81/24 \
  ipv4.gateway 192.168.1.1 \
  ipv4.dns "8.8.8.8 8.8.4.4"
nmcli con up "$(nmcli -g NAME con show --active | head -1)"
ping -c2 1.1.1.1
```

Interface trong VM sẽ tên `ens18` hoặc `eth0` — kiểm tra bằng `ip -br a`. Card cũ có thể mang tên khác do MAC thay đổi; nếu không có connection active nào, tạo mới:

```bash
nmcli con add type ethernet ifname ens18 con-name ens18 \
  ip4 192.168.1.81/24 gw4 192.168.1.1
nmcli con mod ens18 ipv4.dns "8.8.8.8 8.8.4.4"
nmcli con up ens18
```

Cài guest agent để Proxmox đọc được IP và shutdown mềm:

```bash
dnf install -y qemu-guest-agent
systemctl enable --now qemu-guest-agent
```

---

## Giai đoạn 6 — Chuyển sang virtio

SATA chậm hơn virtio-scsi đáng kể. Sau khi VM chạy ổn, thêm driver rồi đổi bus.

**Trong VM:**

```bash
dracut -f --regenerate-all --add-drivers "virtio_blk virtio_scsi virtio_pci virtio_net"
lsinitrd /boot/initramfs-$(uname -r).img | grep virtio_scsi    # phải có kết quả
poweroff
```

**Trên host:**

```bash
qm set 101 --delete sata0
qm config 101 | grep unused
qm set 101 --scsi0 local-lvm:vm-101-disk-0,discard=on,iothread=1
qm set 101 --boot order=scsi0
qm start 101
```

`--delete` chỉ tháo disk thành `unused`, không xóa dữ liệu. Boot fail thì gắn lại `sata0` là quay về trạng thái chạy được.

**Sau khi boot bằng virtio, chạy fstrim để trả chỗ trống về thin pool:**

```bash
fstrim -av                 # trong VM
lvs pve | grep vm-101      # trên host, xem Data% giảm
```

Bước này quan trọng với image sparse như của bạn: đĩa 120 GiB nhưng dữ liệu thật chỉ vài GB, `discard=on` cộng `fstrim` giúp pool chỉ giữ phần thực dùng.

---

## Giai đoạn 7 — Xử lý sự cố

### Rơi vào dracut emergency, `/dev/mapper/rl-root does not exist`

Đã loại trừ khả năng thiếu PV (image đã xác minh lành lặn). Nếu xảy ra kể cả với SATA, sửa initramfs offline từ host:

```bash
qm stop 101
kpartx -av /dev/pve/vm-101-disk-0
vgchange -ay rl
mkdir -p /mnt/vm101
mount /dev/rl/root /mnt/vm101
lsblk                                      # tìm partition /boot, dạng loop0p2
mount /dev/mapper/loop0p2 /mnt/vm101/boot
for d in dev proc sys run; do mount --bind /$d /mnt/vm101/$d; done

chroot /mnt/vm101 dracut -f --regenerate-all \
  --add-drivers "virtio_blk virtio_scsi virtio_pci virtio_net ahci"
```

Tháo ngược đúng thứ tự:

```bash
for d in run sys proc dev; do umount /mnt/vm101/$d; done
umount /mnt/vm101/boot /mnt/vm101
vgchange -an rl
kpartx -d /dev/pve/vm-101-disk-0
```

> **Cảnh báo duplicate VG.** File qcow2 và LV đã import chứa cùng VG `rl` với cùng UUID. Không bao giờ mở đồng thời cả hai (`qemu-nbd` + `kpartx`) — LVM sẽ báo duplicate PV và có thể thao tác nhầm thiết bị. Luôn `vgchange -an rl` trước khi tháo.

### Kernel panic / `unsupported CPU`

```bash
qm set 101 --cpu host
```

### `VM is locked (create)`

```bash
ps aux | egrep 'importdisk|qemu-img|lvcreate' | grep -v grep    # đảm bảo không còn tiến trình
qm unlock 101
```

Vẫn treo:

```bash
sed -i '/^lock:/d' /etc/pve/qemu-server/101.conf
rm -f /var/lock/qemu-server/lock-101.conf
```

### VM không ra được mạng

```bash
qm config 101 | grep net0                  # trên host: phải là bridge=vmbr0
ip -br a                                   # trong VM
ip r                                       # phải có default via 192.168.1.1
```

Gắn nhầm `vmbr1` là mất mạng, vì bridge đó không có port vật lý.

### Mở rộng dung lượng (VG đang PFree 0)

Đúng thứ tự này, sai là không nhận chỗ trống:

```bash
# Trên host
qm resize 101 scsi0 +50G

# Trong VM
growpart /dev/sda 3
pvresize /dev/sda3
lvextend -l +100%FREE /dev/rl/root
xfs_growfs /
```

Kiểm tra filesystem trước: `xfs_growfs` cho XFS, `resize2fs` cho ext4.

---

## Giai đoạn 8 — Dọn dẹp

Sau khi VM chạy ổn định vài ngày:

```bash
rm -f /var/lib/vz/import/AI.qcow2
lvs pve
pvesm status
qm list
```

---

## Rollback — xóa VM làm lại

```bash
qm stop 101
qm destroy 101 --purge --destroy-unreferenced-disks 1
```

Bị từ chối vì lock:

```bash
qm destroy 101 --purge --skiplock
```

Phương án cuối:

```bash
rm -f /etc/pve/qemu-server/101.conf
lvs pve
lvremove pve/vm-101-disk-0
```

---

## Bảng lệnh nhanh

```bash
# 0. Dọn LV staging, chuyển file vào thư mục import
mv /mnt/staging/AI.qcow2 /var/lib/vz/import/
lvremove pve/staging

# 1. Tạo VM
qm create 101 --name ai-rocky --ostype l26 --machine pc --bios seabios \
  --cpu host --sockets 1 --cores 4 --memory 8192 --balloon 0 \
  --scsihw virtio-scsi-single --net0 virtio,bridge=vmbr0 \
  --agent enabled=1 --onboot 1

# 2. Import + gắn SATA một bước
qm set 101 --sata0 local-lvm:0,import-from=/var/lib/vz/import/AI.qcow2,discard=on
qm set 101 --boot order=sata0

# 3. Chạy
qm start 101 && qm status 101

# 4. Trong VM: thêm driver rồi tắt máy
#    dracut -f --regenerate-all --add-drivers "virtio_blk virtio_scsi virtio_pci virtio_net"

# 5. Đổi sang virtio
qm set 101 --delete sata0
qm set 101 --scsi0 local-lvm:vm-101-disk-0,discard=on,iothread=1
qm set 101 --boot order=scsi0
qm start 101

# 6. Trong VM: trả chỗ trống về pool
#    fstrim -av
```

---

## Phụ lục A — Nâng cấu hình sau khi VM đã chạy

Không cần import lại, chỉ cần tắt máy và chỉnh:

```bash
qm stop 101
qm set 101 --sockets 2 --cores 16 --memory 65536 --numa 1
qm start 101
```

Kiểm tra bên trong VM:

```bash
lscpu | egrep 'CPU\(s\)|NUMA'
free -h
```

## Phụ lục B — Nếu sau này gặp image UEFI

Image hiện tại **không** thuộc trường hợp này. Dấu hiệu nhận biết: `parted` cho thấy partition `fat32` mang flag `esp`.

```bash
qm create 102 --name vm-uefi --ostype l26 --machine q35 --bios ovmf \
  --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0 \
  --cpu host --sockets 1 --cores 4 --memory 8192 \
  --scsihw virtio-scsi-single --net0 virtio,bridge=vmbr0
```

`pre-enrolled-keys=0` tắt Secure Boot enrollment, tránh OVMF chặn kernel không có signature. Vào EFI Shell thì gõ `exit` → **Boot Maintenance Manager** → **Boot From File** → chọn `EFI/<distro>/grubx64.efi`, rồi ghi lại boot entry bằng `efibootmgr`.

## Phụ lục C — Kiểm tra nhanh image lạ trước khi import

```bash
modprobe nbd max_part=8
qemu-nbd --connect=/dev/nbd0 --read-only /đường/dẫn/file.qcow2
parted /dev/nbd0 print          # BIOS hay UEFI?
pvs /dev/nbd0p3                 # có LVM không?
lvs -o vg_name,lv_name,lv_size,lv_attr

# Ngắt ngay sau khi xem
vgchange -an <tên_vg>
qemu-nbd --disconnect /dev/nbd0
vgscan                          # phải chỉ còn VG "pve"
```

Cách đọc: có `bios_grub` và không có `esp` → Legacy BIOS. `lv_attr` ký tự thứ 5 là `a` và không có `p` → LV lành lặn, không partial.
