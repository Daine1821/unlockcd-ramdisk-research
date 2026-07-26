# Universal ramdisk pack — iOS 26.1

Shared **restore ramdisk** used with device-specific packs (e.g. `iPhone11_26.1/`). Merge this `boot_order.json` with the device order when booting via `irecovery`.

| File | Role |
|------|------|
| `universal_26.1/26.1.dmg` | Universal restore ramdisk (IM4P `rdsk`) — **~315 MB, Git LFS** |
| `universal_26.1/26.1.dmg.trustcache` | Trust cache for ramdisk |
| `universal_26.1/boot_order.json` | trustcache → ramdisk (send_order 0–1) |

**Clone with LFS** (required for real `.dmg`):

```bash
git lfs install
git clone https://github.com/Daine1821/unlockcd-ramdisk-research.git
cd unlockcd-ramdisk-research
git lfs pull
```

On GitHub’s web UI, `.dmg` may show as a tiny pointer file until downloaded with LFS.

Parent folder may also contain `universal_26.1.zip` (same payload, LFS).
