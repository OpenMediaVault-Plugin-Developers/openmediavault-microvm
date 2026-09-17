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
