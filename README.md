# UnlockCD Ramdisk — research & Windows port

**English** · [Español](README.es.md)

Community mirror of **research artifacts** derived from the **UnlockCD Ramdisk V1.0** (macOS) bundle: local decrypt tooling, boot flow notes, HFZ-style `/mnt2` mount scripts, and a **Windows batch kit**.

---

## Disclaimer (read first)

| | |
|---|---|
| **Purpose** | **Education and security research only.** Not a product, not support, not a bypass service. |
| **Apple** | **Not affiliated with, endorsed by, or authorized by Apple Inc.** Apple, iPhone, iOS, and related names are trademarks of Apple Inc. Firmware and restore components in `ramdisks_extracted/` are **Apple/third-party material**; this repo does **not** grant you any license to use them beyond what law permits. |
| **UnlockCD** | **Not affiliated with UnlockCD** or its authors. If you use the original app, you must comply with **their** terms. This repo documents what we extracted for study; it is not a replacement or crack. |
| **You** | You are responsible for compliance with local laws, device ownership, and platform policies (including GitHub). **Use only on devices you own or have explicit permission to test.** |

---

## What is in this repo

| Path | Description |
|------|-------------|
| `decrypt_all_ramdisks.py` | Decrypt `*.zip.enc` → `ramdisks_extracted/` |
| `decrypt_all_encrypted.py` | Decrypt `start.sh`, `give.sh`, `restore.sh`, `mnt2.macho` |
| `scripts_encrypted_extracted/` | Decrypted macOS-side scripts + `MANIFEST.txt` |
| `mount_mnt2_extracted/` | Mount/backup shell helpers from the `.app` |
| `UnlockCD-Windows/` | Windows boot → SSH → mount workflow (see `SETUP_TOOLS.bat`) |
| `ramdisks_extracted/` | IM4P, `boot_order.json`, universal `.dmg`, etc. (**large**, Git LFS) |

---

## Requirements

- Windows 10+, **Python 3.10+**
- iPhone/iPad in **DFU or Recovery**, USB cable
- Tools (not all redistributed here): **`irecovery`**, **`iproxy`**, **OpenSSH** / **`sshpass`** — see `UnlockCD-Windows/SETUP_TOOLS.bat`
- Optional: **Usbliter8Boot** for pwned DFU (see Acknowledgments)

---

## Decrypt (bring your own `.app` or use included extracts)

```bat
DESENPAQUETAR_RAMDISKS.bat
DESENCRIPTAR_TODO.bat
```

Key derivation is documented in the Python sources (ramdisk HMAC vs script protection string).

---

## Windows workflow (draft)

1. `UnlockCD-Windows\1_BOOT.bat` — DFU `ibss.raw` → Recovery → `boot_order.json`
2. `2_SSH_PROXY.bat` → `3_SSH_CONECTAR.bat` (default `alpine`)
3. `4_MOUNT.bat` — pipes `remote_mount_dynamic.sh` over SSH (HFZ-style `/mnt2`)

See `UnlockCD-Windows/LEEME.txt` for details.

---

## Help wanted (issues / PRs)

- [ ] Stable **Recovery → ramdisk** boot (kernel / SEP vs `boot_order.json`)
- [ ] Windows equivalent of **`mnt2.macho`** / Mac menu flow
- [ ] Full **KDF** docs for all `.enc` layouts
- [ ] Light CI (lint scripts only; no firmware in CI)

---

## Large files & LFS

`ramdisks_extracted/` includes multi‑hundred‑MB `.dmg` / `.zip` assets. This repo uses **Git LFS** for `*.dmg` and `*.zip`. Clone with [Git LFS](https://git-lfs.com/) installed.

---

## License

- **This repository’s original code and docs** (`.py`, `.bat`, `README*`, etc.): **[MIT License](LICENSE)** © Daine1821.
- **Firmware blobs, IM4P, ramdisk images, UnlockCD ciphertext, and Apple components**: **not licensed by this project**; remain subject to Apple and/or original rights holders. Do not assume redistribution is permitted outside research context.

---

## Acknowledgments

- **[libimobiledevice](https://libimobiledevice.org/)** ecosystem — `irecovery`, USB restore workflow ideas.
- **[libusbmuxd](https://github.com/libimobiledevice/libusbmuxd)** / **`iproxy`** — SSH over USB tunneling.
- **Usbliter8 / checkm8 USB boot tooling** — pwned DFU and custom boot paths used alongside `irecovery` (credit to the **Usbliter8** authors and community; we do not ship their binaries in this repo by default).
- **UnlockCD Ramdisk (macOS)** — source bundle structure we studied (**no endorsement, no affiliation**).
- Community references (boot chains, ramdisk packs, mount notes) that helped validate behavior — thank you to everyone sharing **responsible** research.

---

*If you maintain a tool we should credit by name/URL, open an issue and we will add it.*
