openmediavault-microvm

Firecracker microVM support for OpenMediaVault. Manage Firecracker VM
definitions, a kernel/rootfs image library, and per-VM lifecycle (start,
stop, restart, autostart) via systemd — independently of the
openmediavault-kvm (libvirt/QEMU) plugin. See the RPC service `MicroVm`
and the systemd template unit `omv-microvm@.service`.

The pinned Firecracker binary version (in `usr/sbin/omv-install-fc`) and the
image catalog's CI source version (in `usr/share/openmediavault-microvm/
image-catalog.json`) are unrelated version axes — a current Firecracker
binary happily boots an older CI test kernel/rootfs, so the catalog just
tracks whichever `firecracker-ci/vX.Y/` folder is newest with real
artifacts (some version folders are pre-created but stay empty until CI
actually populates them).

Since `v1.12`, Firecracker's CI bucket only publishes rootfs images as
read-only `.squashfs` (previously `.ext4`). That's purely a distribution
format — Firecracker's own tooling (`tools/setup-ci-artifacts.sh`) unpacks
it and repacks it as a plain ext4 image before ever booting it, and
`omv-microvm-image-download` does the same (`unsquashfs` + `mkfs.ext4 -d`)
whenever an image's `rootfs_url` ends in `.squashfs`. Everything downstream
(`omv-microvm-run`, the datamodel) only ever sees a single `rootfs.ext4`
file, regardless of which format the source used.

Data disks (Disks tab) are extra block devices attached after the rootfs,
in name order — `/dev/vdb`, `/dev/vdc`, ... Firecracker has no hotplug, so
a new disk shows up the next time the VM starts. An ext4 disk is labelled
with its name; mount it by label so that adding or removing another disk
can't change which device it is, e.g. in the guest's `/etc/fstab`:

    LABEL=data  /data  ext4  defaults,nofail  0  2

A disk image lives in the VM's own directory by default, or under
`microvm-disks/<vm>/` on another shared folder if one is chosen. It is
copied into snapshots and backups as `disk-<name>.img` unless "Include in
snapshots and backups" is turned off.

"Run in jailer" (per VM) starts Firecracker through its `jailer`: chrooted
under `/var/lib/openmediavault-microvm/jail/firecracker/mvm-<hash>/root`,
as a uid/gid of its own (allocated from 1500000000 up, no passwd entry)
and with only that VM's kernel, disks and TAP device available. The files
are bind-mounted into the chroot and chowned to the VM's uid, so on the
shared folder they show up owned by that number; `omv-microvm-stop-cleanup`
unmounts and removes the chroot again. The API socket path in
`/run/openmediavault-microvm/<vm>/` becomes a symlink into the chroot, so
tooling that talks to it works either way. A warm snapshot or backup
records whether it was taken jailed (a `jailed` file next to `vmstate`)
and only restores with the same setting, because its device state holds
the paths Firecracker saw; cold ones restore either way.

Every VM on a private NAT network gets a fixed address, passed to its
kernel via `ip=` so no in-guest DHCP client is needed. With "Run DHCP" on,
`omv-microvm-dhcp@<network>.service` (dnsmasq, bound to the network's
bridge only) also runs on the gateway address. It hands each VM that same
address as a DHCP reservation and answers DNS, and the gateway is passed
as the DNS server in `ip=` too. A VM without a MAC address set gets a fixed
one (`02:fc:…`) derived from its name, so its reservation matches every
boot. The server starts with the first VM on the network.

Stop and Restart shut guests down cleanly. `omv-microvm-shutdown` (the
unit's ExecStop) sends Ctrl+Alt+Del through the Firecracker API. The guest
treats it as a reboot, and Firecracker exits once the guest is down. It
waits up to the VM's shutdown timeout (default 30s, 0 to always stop hard)
and then stops hard. Firecracker only supports this on x86_64, and Force
stop and VM deletion never wait.
