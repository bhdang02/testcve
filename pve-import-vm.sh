#!/usr/bin/env bash
#
# pve-import-vm.sh — Tạo VM và import file qcow2 vào Proxmox VE
#
# Dùng:
#   ./pve-import-vm.sh                      # chạy full: preflight -> create -> import -> start
#   ./pve-import-vm.sh preflight            # chỉ kiểm tra, không thay đổi gì
#   ./pve-import-vm.sh create               # chỉ tạo VM rỗng
#   ./pve-import-vm.sh import               # chỉ import + gắn disk
#   ./pve-import-vm.sh start                # chỉ khởi động
#   ./pve-import-vm.sh to-virtio            # đổi sata0 -> scsi0 (sau khi đã chạy dracut trong VM)
#   ./pve-import-vm.sh resize-cpu-ram       # nâng cấu hình theo biến PROFILE
#   ./pve-import-vm.sh reclaim-staging      # xóa LV staging không dùng, trả chỗ về thin pool
#   ./pve-import-vm.sh destroy              # xóa VM làm lại từ đầu
#
# Tùy chọn:
#   -y | --yes        không hỏi xác nhận
#   -n | --dry-run    chỉ in lệnh, không thực thi
#   -h | --help       trợ giúp
#
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# CẤU HÌNH — sửa phần này trước khi chạy
# ─────────────────────────────────────────────────────────────
VMID="${VMID:-101}"
VMNAME="${VMNAME:-ai-rocky}"
QCOW2="${QCOW2:-/var/lib/vz/import/AI.qcow2}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"

# PROFILE: light | medium | heavy
PROFILE="${PROFILE:-light}"

# Ghi đè thủ công nếu muốn (để trống = dùng theo PROFILE)
SOCKETS="${SOCKETS:-}"
CORES="${CORES:-}"
MEMORY="${MEMORY:-}"

OSTYPE_="${OSTYPE_:-l26}"
ONBOOT="${ONBOOT:-1}"
STAGING_LV="${STAGING_LV:-pve/staging}"

# ─────────────────────────────────────────────────────────────
# Hạ tầng script
# ─────────────────────────────────────────────────────────────
ASSUME_YES=0
DRY_RUN=0
NBD_DEV=""
GUEST_VG=""

C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'
C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m';    C_OFF=$'\033[0m'

log()   { printf '%s[ %s ]%s %s\n' "$C_BLU" "$(date +%H:%M:%S)" "$C_OFF" "$*"; }
ok()    { printf '%s  OK %s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn()  { printf '%s  !! %s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()   { printf '%s ERR %s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
head_() { printf '\n%s══ %s ══%s\n' "$C_BLD" "$*" "$C_OFF"; }

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s  >> %s %s\n' "$C_YEL" "$C_OFF" "$*"
        return 0
    fi
    "$@"
}

confirm() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    [[ $DRY_RUN   -eq 1 ]] && return 0
    local reply
    read -r -p "$(printf '%s?%s %s [y/N] ' "$C_YEL" "$C_OFF" "$1")" reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

cleanup_nbd() {
    if [[ -n "$GUEST_VG" ]]; then
        vgchange -an "$GUEST_VG" >/dev/null 2>&1 || true
        GUEST_VG=""
    fi
    if [[ -n "$NBD_DEV" ]]; then
        qemu-nbd --disconnect "$NBD_DEV" >/dev/null 2>&1 || true
        NBD_DEV=""
    fi
}
trap cleanup_nbd EXIT INT TERM

apply_profile() {
    case "$PROFILE" in
        light)  : "${SOCKETS:=1}" "${CORES:=4}"  "${MEMORY:=8192}"  ;;
        medium) : "${SOCKETS:=1}" "${CORES:=16}" "${MEMORY:=32768}" ;;
        heavy)  : "${SOCKETS:=2}" "${CORES:=16}" "${MEMORY:=65536}" ;;
        *) die "PROFILE không hợp lệ: $PROFILE (light|medium|heavy)" ;;
    esac
    NUMA=0
    (( MEMORY > 39000 || SOCKETS > 1 )) && NUMA=1
}

# ─────────────────────────────────────────────────────────────
# PREFLIGHT
# ─────────────────────────────────────────────────────────────
BIOS_MODE=""       # seabios | ovmf

detect_bios_mode() {
    log "Phân tích partition table của image..."

    modprobe nbd max_part=8 2>/dev/null || die "Không nạp được module nbd"

    local d
    for d in /dev/nbd{0..15}; do
        if [[ ! -e "${d}p1" ]] && ! qemu-nbd --disconnect "$d" >/dev/null 2>&1; then :; fi
        if [[ "$(cat "/sys/block/$(basename "$d")/size" 2>/dev/null || echo 0)" == "0" ]]; then
            NBD_DEV="$d"; break
        fi
    done
    [[ -n "$NBD_DEV" ]] || die "Không tìm được thiết bị nbd trống"

    qemu-nbd --connect="$NBD_DEV" --read-only "$QCOW2" || die "qemu-nbd không mở được $QCOW2"
    sleep 2
    partprobe "$NBD_DEV" >/dev/null 2>&1 || true

    local ptable
    ptable="$(parted -s "$NBD_DEV" print 2>/dev/null || true)"
    printf '%s\n' "$ptable" | sed 's/^/      /'

    if grep -qiE 'fat(16|32).*(esp|boot)' <<<"$ptable"; then
        BIOS_MODE="ovmf"
        warn "Image dùng UEFI -> sẽ tạo VM với ovmf + efidisk0"
    else
        BIOS_MODE="seabios"
        ok "Image dùng Legacy BIOS -> seabios + machine pc"
    fi

    # Kiểm tra LVM bên trong (nếu có) rồi tắt ngay
    GUEST_VG="$(pvs --noheadings -o vg_name "${NBD_DEV}"p* 2>/dev/null | awk 'NF{print $1; exit}' || true)"
    if [[ -n "$GUEST_VG" && "$GUEST_VG" != "pve" ]]; then
        log "Volume group trong image: $GUEST_VG"
        lvs --noheadings -o vg_name,lv_name,lv_size,lv_attr "$GUEST_VG" 2>/dev/null | sed 's/^/      /' || true
        if lvs --noheadings -o lv_attr "$GUEST_VG" 2>/dev/null | grep -q 'p'; then
            die "Có LV ở trạng thái partial — image thiếu PV, không import được"
        fi
        ok "Các LV lành lặn, không partial"
    else
        GUEST_VG=""
    fi

    cleanup_nbd
    sleep 1
}

preflight() {
    head_ "PREFLIGHT"

    [[ $EUID -eq 0 ]] || die "Phải chạy bằng root"
    command -v qm        >/dev/null || die "Không tìm thấy lệnh qm — đây có phải host Proxmox?"
    command -v qemu-nbd  >/dev/null || die "Thiếu qemu-nbd (gói qemu-utils)"
    ok "Chạy trên host Proxmox: $(pveversion | head -1)"

    [[ -f "$QCOW2" ]] || die "Không thấy file: $QCOW2"
    local vsize dsize
    vsize="$(qemu-img info --output=json "$QCOW2" | grep -o '"virtual-size":[0-9]*' | cut -d: -f2)"
    dsize="$(stat -c %s "$QCOW2")"
    ok "Image: $QCOW2"
    printf '      virtual %s GiB / thực tế %s GiB\n' \
        "$((vsize/1024/1024/1024))" "$((dsize/1024/1024/1024))"

    if qm status "$VMID" >/dev/null 2>&1; then
        die "VMID $VMID đã tồn tại. Chọn VMID khác hoặc chạy: $0 destroy"
    fi
    ok "VMID $VMID còn trống"

    pvesm status | awk -v s="$STORAGE" 'NR>1 && $1==s {found=1} END{exit !found}' \
        || die "Không có storage tên $STORAGE"
    local avail_kib
    avail_kib="$(pvesm status | awk -v s="$STORAGE" '$1==s {print $6}')"
    local need_kib=$((vsize/1024))
    if (( avail_kib < need_kib )); then
        die "Thiếu chỗ trên $STORAGE: cần $((need_kib/1024/1024)) GiB, còn $((avail_kib/1024/1024)) GiB"
    fi
    ok "Storage $STORAGE còn $((avail_kib/1024/1024)) GiB — đủ chỗ"

    ip link show "$BRIDGE" >/dev/null 2>&1 || die "Không có bridge $BRIDGE"
    local ports
    ports="$(ls "/sys/class/net/$BRIDGE/brif" 2>/dev/null | tr '\n' ' ')"
    if [[ -z "${ports// }" ]]; then
        warn "Bridge $BRIDGE không có port vật lý — VM sẽ không ra được mạng ngoài"
    else
        ok "Bridge $BRIDGE (port: ${ports% })"
    fi

    apply_profile
    local mem_total_mb
    mem_total_mb="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
    if (( MEMORY > mem_total_mb - 8192 )); then
        warn "RAM cấp cho VM ($MEMORY MB) quá sát RAM host ($mem_total_mb MB) — nên giảm xuống"
    fi
    ok "Profile $PROFILE: ${SOCKETS} socket × ${CORES} core, ${MEMORY} MB, numa=$NUMA"

    detect_bios_mode

    head_ "TÓM TẮT"
    cat <<EOF
      VMID        : $VMID ($VMNAME)
      Image       : $QCOW2
      Storage     : $STORAGE
      Bridge      : $BRIDGE
      BIOS        : $BIOS_MODE
      CPU/RAM     : ${SOCKETS}×${CORES} core, ${MEMORY} MB (numa=$NUMA)
      Bus ban đầu : sata0  (đổi sang scsi0 sau khi cài driver virtio)
EOF
}

# ─────────────────────────────────────────────────────────────
# CREATE
# ─────────────────────────────────────────────────────────────
create_vm() {
    head_ "TẠO VM $VMID"
    [[ -n "$BIOS_MODE" ]] || { detect_bios_mode; }
    apply_profile

    local -a args=(
        "$VMID"
        --name "$VMNAME"
        --ostype "$OSTYPE_"
        --cpu host
        --sockets "$SOCKETS"
        --cores "$CORES"
        --memory "$MEMORY"
        --balloon 0
        --scsihw virtio-scsi-single
        --net0 "virtio,bridge=$BRIDGE"
        --agent enabled=1
        --onboot "$ONBOOT"
    )
    (( NUMA == 1 )) && args+=(--numa 1)

    if [[ "$BIOS_MODE" == "ovmf" ]]; then
        args+=(--machine q35 --bios ovmf
               --efidisk0 "$STORAGE:1,efitype=4m,pre-enrolled-keys=0")
    else
        args+=(--machine pc --bios seabios)
    fi

    confirm "Tạo VM $VMID với cấu hình trên?" || die "Đã hủy"
    run qm create "${args[@]}"
    ok "Đã tạo VM $VMID"
}

# ─────────────────────────────────────────────────────────────
# IMPORT
# ─────────────────────────────────────────────────────────────
import_disk() {
    head_ "IMPORT DISK"
    qm status "$VMID" >/dev/null 2>&1 || die "VM $VMID chưa tồn tại — chạy '$0 create' trước"

    if qm config "$VMID" | grep -qE '^(sata0|scsi0|virtio0):'; then
        warn "VM $VMID đã có disk gắn sẵn, bỏ qua bước import"
        return 0
    fi

    log "Import (image sparse nên thường nhanh hơn kích thước danh nghĩa)..."
    log "Không Ctrl+C giữa chừng — sẽ để lại LV mồ côi và lock: create"

    if run qm set "$VMID" --sata0 "$STORAGE:0,import-from=$QCOW2,discard=on"; then
        ok "Import + gắn disk xong (một bước)"
    else
        warn "import-from thất bại, chuyển sang cách hai bước"
        run qm disk import "$VMID" "$QCOW2" "$STORAGE"
        local vol
        vol="$(qm config "$VMID" | awk -F': ' '/^unused[0-9]+:/{print $2; exit}')"
        [[ -n "$vol" ]] || die "Không tìm thấy volume vừa import"
        run qm set "$VMID" --sata0 "$vol,discard=on"
        ok "Đã gắn $vol vào sata0"
    fi

    run qm set "$VMID" --boot order=sata0
    [[ $DRY_RUN -eq 0 ]] && qm config "$VMID" | sed 's/^/      /'
}

# ─────────────────────────────────────────────────────────────
# START
# ─────────────────────────────────────────────────────────────
start_vm() {
    head_ "KHỞI ĐỘNG VM $VMID"
    run qm start "$VMID"
    sleep 3
    [[ $DRY_RUN -eq 0 ]] && qm status "$VMID" | sed 's/^/      /'
    cat <<EOF

      Mở console: GUI -> node -> VM $VMID -> Console (noVNC)

      Boot đúng: SeaBIOS -> GRUB -> kernel -> mount root -> login

      Nếu rơi vào dracut emergency shell, xem phần "Xử lý sự cố"
      trong runbook. Nếu boot được, chạy TRONG VM:

        dracut -f --regenerate-all \\
          --add-drivers "virtio_blk virtio_scsi virtio_pci virtio_net"
        poweroff

      rồi trên host chạy:  $0 to-virtio
EOF
}

# ─────────────────────────────────────────────────────────────
# TO-VIRTIO
# ─────────────────────────────────────────────────────────────
to_virtio() {
    head_ "CHUYỂN SANG VIRTIO-SCSI"
    local vol
    vol="$(qm config "$VMID" | awk -F': ' '/^sata0:/{print $2; exit}' | cut -d, -f1)"
    [[ -n "$vol" ]] || die "VM $VMID không có sata0 — có thể đã chuyển rồi"

    cat <<EOF
      Trước khi chạy tiếp, phải chắc chắn ĐÃ chạy trong VM:
        dracut -f --regenerate-all --add-drivers "virtio_blk virtio_scsi virtio_pci virtio_net"
      Nếu chưa, VM sẽ không boot được sau khi đổi bus (gắn lại sata0 là khôi phục).
EOF
    confirm "Đã chạy dracut trong VM và tắt máy?" || die "Đã hủy"

    run qm stop "$VMID" || true
    sleep 2
    run qm set "$VMID" --delete sata0
    run qm set "$VMID" --scsi0 "$vol,discard=on,iothread=1"
    run qm set "$VMID" --boot order=scsi0
    run qm start "$VMID"
    ok "Đã chuyển sang scsi0 ($vol)"
    echo "      Boot xong nhớ chạy trong VM: fstrim -av"
}

# ─────────────────────────────────────────────────────────────
# RESIZE CPU/RAM
# ─────────────────────────────────────────────────────────────
resize_cpu_ram() {
    head_ "NÂNG CẤU HÌNH (profile: $PROFILE)"
    apply_profile
    echo "      -> ${SOCKETS} socket × ${CORES} core, ${MEMORY} MB, numa=$NUMA"
    confirm "VM sẽ bị tắt để áp dụng. Tiếp tục?" || die "Đã hủy"
    run qm stop "$VMID" || true
    sleep 2
    run qm set "$VMID" --sockets "$SOCKETS" --cores "$CORES" --memory "$MEMORY" --numa "$NUMA"
    run qm start "$VMID"
    ok "Đã áp dụng"
}

# ─────────────────────────────────────────────────────────────
# RECLAIM STAGING
# ─────────────────────────────────────────────────────────────
reclaim_staging() {
    head_ "GIẢI PHÓNG LV $STAGING_LV"
    lvs "$STAGING_LV" >/dev/null 2>&1 || { ok "LV $STAGING_LV không tồn tại, bỏ qua"; return 0; }
    lvs -o lv_name,lv_size,data_percent "$STAGING_LV" | sed 's/^/      /'

    if findmnt -S "/dev/$STAGING_LV" >/dev/null 2>&1; then
        warn "LV đang được mount — umount trước khi xóa"
        findmnt -S "/dev/$STAGING_LV" | sed 's/^/      /'
        confirm "Umount rồi xóa?" || die "Đã hủy"
        run umount "/dev/$STAGING_LV"
    fi

    warn "Thao tác này XÓA VĨNH VIỄN dữ liệu trên $STAGING_LV"
    confirm "Xác nhận xóa $STAGING_LV?" || die "Đã hủy"
    run lvremove -y "$STAGING_LV"
    ok "Đã trả chỗ về thin pool"
    [[ $DRY_RUN -eq 0 ]] && pvesm status | sed 's/^/      /'
}

# ─────────────────────────────────────────────────────────────
# DESTROY
# ─────────────────────────────────────────────────────────────
destroy_vm() {
    head_ "XÓA VM $VMID"
    qm status "$VMID" >/dev/null 2>&1 || { ok "VM $VMID không tồn tại"; return 0; }
    qm config "$VMID" | sed 's/^/      /'
    warn "Thao tác này XÓA VĨNH VIỄN VM và toàn bộ disk của nó"
    confirm "Xác nhận xóa VM $VMID?" || die "Đã hủy"

    run qm stop "$VMID" 2>/dev/null || true
    sleep 2
    if ! run qm destroy "$VMID" --purge --destroy-unreferenced-disks 1; then
        warn "Bị từ chối, thử unlock rồi xóa lại"
        run qm unlock "$VMID" || true
        run qm destroy "$VMID" --purge --skiplock
    fi
    ok "Đã xóa VM $VMID"
}

# ─────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────
usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

ACTION="all"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)     ASSUME_YES=1 ;;
        -n|--dry-run) DRY_RUN=1 ;;
        -h|--help)    usage ;;
        preflight|create|import|start|to-virtio|resize-cpu-ram|reclaim-staging|destroy|all)
                      ACTION="$1" ;;
        *) die "Tham số không hiểu: $1 (dùng --help)" ;;
    esac
    shift
done

[[ $DRY_RUN -eq 1 ]] && warn "CHẾ ĐỘ DRY-RUN — không thay đổi gì"

case "$ACTION" in
    preflight)       preflight ;;
    create)          preflight; create_vm ;;
    import)          import_disk ;;
    start)           start_vm ;;
    to-virtio)       to_virtio ;;
    resize-cpu-ram)  resize_cpu_ram ;;
    reclaim-staging) reclaim_staging ;;
    destroy)         destroy_vm ;;
    all)
        preflight
        confirm "Tiến hành tạo VM và import?" || die "Đã hủy"
        create_vm
        import_disk
        start_vm
        ;;
esac

head_ "XONG"
