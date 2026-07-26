# Universal ramdisk pack — iOS 18.3

Shared **restore ramdisk** for 18.3 device packs. Merge this `boot_order.json` with the device-specific order when booting.

| File | Role |
|------|------|
| `universal_18.3/18.3.dmg` | Universal restore ramdisk — **Git LFS** |
| `universal_18.3/18.3.dmg.trustcache` | Trust cache |
| `universal_18.3/boot_order.json` | trustcache → ramdisk |

**Clone with LFS:**

```bash
git lfs install
git clone https://github.com/Daine1821/unlockcd-ramdisk-research.git
cd unlockcd-ramdisk-research
git lfs pull
```

See also: [universal_26.1/README.md](../universal_26.1/README.md)
