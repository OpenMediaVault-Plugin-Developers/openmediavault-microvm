# firecracker-guest.sh — shared by the build-*-image scripts: kernel
# download, the guest setup omv-microvm-run relies on, and the ext4 image.
# Sourced, not run.
#
# The kernel is Firecracker's own CI guest kernel, not the distribution's:
# those build virtio/ext4 as modules and need an initrd, which
# omv-microvm-run doesn't pass. The CI kernel has everything built in,
# including the "ip=" autoconfig the plugin uses on NAT networks.

# Newest CI kernel with artifacts in both arches — see the README on the
# catalog's CI version.
FC_CI_VERSION="v1.15"
KERNEL_VERSION="6.1.155"

_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    _log "ERROR: $*" >&2
    exit 1
}

usage() {
    sed -n '/^# Usage:/,/^# Writes/s/^# \{0,1\}//p' "$0"
    exit "${1:-0}"
}

# fetch_kernel <arch> <dest> [<local-vmlinux>]
fetch_kernel() {
    if [ -n "${3:-}" ]; then
        cp "$3" "$2"
        return
    fi
    local url="https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/${FC_CI_VERSION}/${1}/vmlinux-${KERNEL_VERSION}"
    _log "Downloading kernel from ${url} ..."
    wget --quiet --show-progress -O "$2" "$url"
}

# configure_guest <root> <hostname> <root-password> <ssh-key-file> <ssh-unit>
# Empty password: autologin on the console. Empty key file: no SSH setup
# (the distribution script only installs the server when there's a key).
configure_guest() {
    local root="$1" hostname="$2" password="$3" ssh_key="$4" ssh_unit="$5"

    echo "$hostname" > "${root}/etc/hostname"
    printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n::1\t\tlocalhost ip6-localhost ip6-loopback\n' \
        "$hostname" > "${root}/etc/hosts"

    # Firecracker adds "root=/dev/vda" itself.
    echo "/dev/vda / ext4 defaults,errors=remount-ro 0 1" > "${root}/etc/fstab"

    # Every VM boots its own copy of this rootfs, so each must make its own
    # machine id (and SSH host keys, below) on first boot. An empty one
    # also makes it a "first boot" for systemd, whose firstboot wizard
    # would then stop at the console asking for a locale, keymap and
    # timezone — nothing here needs them set.
    : > "${root}/etc/machine-id"
    rm -f "${root}/var/lib/dbus/machine-id"
    systemctl --root="$root" mask systemd-firstboot.service
    [ -e "${root}/etc/locale.conf" ] || echo "LANG=C.UTF-8" > "${root}/etc/locale.conf"

    # On a NAT network omv-microvm-run passes the guest's address as "ip=",
    # which the kernel has already applied by the time userspace starts; on
    # a bridge network there's no "ip=" and the guest must use DHCP. This
    # picks the matching systemd-networkd config at boot, so resolved also
    # learns the DNS server from "ip=" (dns0) when there is one.
    install -D -m 0755 /dev/stdin "${root}/usr/local/sbin/fc-network-config" <<'EOF'
#!/bin/sh
set -eu

NETWORK_FILE=/run/systemd/network/10-eth0.network
mkdir -p "${NETWORK_FILE%/*}"

ip_arg=""
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        ip=*) ip_arg="${arg#ip=}" ;;
    esac
done

# ip=<client>:<server>:<gw>:<netmask>:<host>:<dev>:<autoconf>:<dns0>:<dns1>
case "$ip_arg" in
    *:*)
        IFS=: read -r client _ gw mask _ dev _ dns0 dns1 <<EOT
$ip_arg
EOT
        prefix=0
        IFS=.
        for octet in $mask; do
            while [ "$octet" -gt 0 ]; do
                prefix=$((prefix + (octet & 1)))
                octet=$((octet >> 1))
            done
        done
        unset IFS
        {
            echo "[Match]"
            echo "Name=${dev:-eth0}"
            echo "[Network]"
            echo "Address=${client}/${prefix}"
            [ -z "$gw" ] || echo "Gateway=${gw}"
            [ -z "$dns0" ] || echo "DNS=${dns0}"
            [ -z "$dns1" ] || echo "DNS=${dns1}"
            echo "KeepConfiguration=static"
        } > "$NETWORK_FILE"
        ;;
    *)
        printf '[Match]\nName=eth0\n[Network]\nDHCP=yes\n' > "$NETWORK_FILE"
        ;;
esac
EOF

    cat > "${root}/etc/systemd/system/fc-network-config.service" <<'EOF'
[Unit]
Description=Network configuration from the kernel command line
DefaultDependencies=no
Before=systemd-networkd.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/fc-network-config

[Install]
WantedBy=systemd-networkd.service
EOF

    systemctl --root="$root" enable fc-network-config.service systemd-networkd.service systemd-resolved.service
    ln -sf ../run/systemd/resolve/stub-resolv.conf "${root}/etc/resolv.conf"
    # Only eth0 is ever configured; don't hold up boot waiting for "online".
    systemctl --root="$root" disable systemd-networkd-wait-online.service 2>/dev/null || true

    # Firecracker has no display, only the serial console.
    systemctl --root="$root" mask getty@tty1.service

    if [ -n "$password" ]; then
        echo "root:${password}" | chpasswd -R "$root"
    else
        # The console is only reachable by root on the host
        # (omv-microvm-console), so log straight in.
        mkdir -p "${root}/etc/systemd/system/serial-getty@ttyS0.service.d"
        cat > "${root}/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,57600,38400,9600 - $TERM
EOF
    fi

    if [ -n "$ssh_key" ]; then
        install -d -m 0700 "${root}/root/.ssh"
        install -m 0600 "$ssh_key" "${root}/root/.ssh/authorized_keys"
        rm -f "${root}"/etc/ssh/ssh_host_*
        mkdir -p "${root}/etc/systemd/system/${ssh_unit}.d"
        printf '[Service]\nExecStartPre=/usr/bin/ssh-keygen -A\n' \
            > "${root}/etc/systemd/system/${ssh_unit}.d/hostkeys.conf"
        systemctl --root="$root" enable "$ssh_unit"
    fi
}

# build_ext4 <root> <dest> [<size-mib>]
# Default size: the content plus headroom for the VM to write to; the
# rootfs can be grown later from the VM's settings.
build_ext4() {
    local content_mb image_mb
    content_mb=$(du -sm "$1" | cut -f1)
    image_mb="${3:-$((content_mb + 512))}"
    [ "$image_mb" -gt "$content_mb" ] || die "--size ${image_mb} MiB is smaller than the content (${content_mb} MiB)."

    _log "Building ${image_mb}MiB ext4 image ..."
    truncate -s "${image_mb}M" "$2"
    mkfs.ext4 -q -F -L rootfs -d "$1" "$2"
}
