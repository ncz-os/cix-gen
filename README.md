# ⚠️ This is a mirror — the canonical repo lives on GitLab

### 👉 https://gitlab.com/ncz-os/cix-gen

**Source, releases, issues, merge requests, and CI all live on GitLab.** This GitHub copy is a read-only mirror and may lag. Please file issues and get releases there.

---

> # 📍 Moved to GitLab
> **The canonical, authoritative home of this project is GitLab — always:**
> ## 👉 https://gitlab.com/ncz-os/cix-gen
>
> This GitHub repository is a **frozen, read-only mirror**. All development, issues, and releases happen on GitLab. Please open issues and merge requests there. The full history of this stub is preserved on GitLab.

---

# cixmini-gen

Reproducible nclawzero-distro image builder for the **Minisforum MS-R1**
(Cix Sky1 / CP8180 SoC). Produces a Debian-bookworm-arm64-based image
with our `linux-cix-msr1` kernel, Cix's closed-source userspace .debs,
GNOME desktop, and the nclawzero agent stack (zeroclaw, openclaw, hermes,
claude-code).

## Quick start

```bash
sudo ./cixmini-gen.sh \
    --target /dev/nvme0n1 \
    --debs-dir ./assets/cix-debs \
    --kernel-image ./assets/kernel/Image-cixmini.bin \
    --kernel-modules ./assets/kernel/modules-cixmini.tgz
```

## Inputs

| Path | Source | Notes |
|---|---|---|
| `assets/cix-debs/` | `dpkg-repack` of stock Cix Debian | 35+ proprietary `.deb` files |
| `assets/kernel/Image-cixmini.bin` | Yocto build of `meta-cix` `linux-cix-msr1` recipe | aarch64 kernel binary |
| `assets/kernel/modules-cixmini.tgz` | Yocto build (same) | tarball of `/lib/modules/<KVER>/` |
| `assets/agent-stack/` | `meta-cix/recipes-nclawzero/agent-stack/files/` | systemd quadlet definitions |

## Stages

1. **Stage 0 — Partition.** Wipe target, GPT, 1 GiB ESP + rest ext4.
2. **Stage 1 — Debootstrap.** Debian Bookworm arm64 base.
3. **Stage 2 — Bind mounts.** /dev /proc /sys /run + resolv.conf.
4. **Stage 3 — System config.** apt sources, locale, hostname.
5. **Stage 4 — GNOME desktop.** gnome-core + gdm3 + chromium + apps.
6. **Stage 5 — Cix proprietary userspace.** dpkg -i of all `cix-*.deb`s.
7. **Stage 6 — Our kernel.** linux-cix-msr1 6.6.10 + modules.
8. **Stage 7 — Bootloader.** systemd-boot + UEFI entry.
9. **Stage 8 — Agents.** podman + 3 quadlet units + claude-code via npm.
10. **Stage 9 — User.** ncz operator with NOPASSWD sudo.
11. **Stage 10 — Branding.** /etc/os-release, motd.
12. **Stage 11 — Cleanup.** apt clean, sync, unmount.

## Status

**v0** — single-script form. Reproducible, idempotent (re-run = wipe + rebuild).
A pi-gen-style staged builder is the planned v1 evolution.