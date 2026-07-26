# UnlockCD Ramdisk — research / Windows port (community)

Material **extraído y documentado** a partir del bundle **UnlockCD Ramdisk V1.0** (Mac), con foco en:

- Descifrado local de `*.zip.enc` y scripts `*.enc`
- Flujo de boot (`boot_order.json`, `start.sh`)
- Montaje HFZ `/mnt2` (`remote_mount_dynamic.sh`)
- Kit Windows (`UnlockCD-Windows/`)

**No está afiliado a UnlockCD.** Uso bajo tu responsabilidad: revisa leyes, ToS del producto original y políticas de GitHub. Los blobs de firmware/ramdisk pueden estar sujetos a derechos de Apple/terceros.

## Qué hay aquí

| Ruta | Contenido |
|------|-----------|
| `decrypt_all_ramdisks.py` | Ramdisks `*.zip.enc` → `ramdisks_extracted/` |
| `decrypt_all_encrypted.py` | `start.sh`, `give.sh`, `restore.sh`, `mnt2.macho` |
| `scripts_encrypted_extracted/` | Scripts descifrados + `MANIFEST.txt` |
| `mount_mnt2_extracted/` | Mount/backup helpers (sin duplicar todo el `.app`) |
| `UnlockCD-Windows/` | Boot, SSH, mount (configurar `tools/` aparte) |
| `ramdisks_extracted/` | IM4P, `boot_order.json`, `26.1.dmg`, etc. (**muy pesado**) |

## Requisitos

- Windows 10+, Python 3.10+
- iPhone en DFU/Recovery, cable USB
- Herramientas: `irecovery`, `iproxy`, `openssh`/`sshpass` (ver `UnlockCD-Windows/SETUP_TOOLS.bat`)

## Descifrado (local)

```bat
DESENPAQUETAR_RAMDISKS.bat
DESENCRIPTAR_TODO.bat
```

Claves: derivación documentada en los `.py` (ramdisk vs script protection string).

## Flujo Windows (borrador)

1. `UnlockCD-Windows\1_BOOT.bat`
2. `2_SSH_PROXY.bat` → `3_SSH_CONECTAR.bat` (`alpine`)
3. `4_MOUNT.bat` (HFZ mount en dispositivo)

## Ayuda buscada (issues / PRs)

- [ ] Boot Recovery → ramdisk estable (kernel/SEP vs `boot_order.json`)
- [ ] Equivalente Windows de `mnt2.macho` / menú Mac
- [ ] Documentar KDF y formatos `.enc`
- [ ] CI mínimo (lint scripts, sin firmware en CI)

## Firmware en GitHub

Los directorios `ramdisks_extracted/**` suman **cientos de MB**. Opciones:

1. **Git LFS** (cuota limitada en repos gratis)
2. **GitHub Release** con `.zip` aparte
3. **Solo scripts** en el repo + instrucciones “descifra tu `.app` legalmente adquirido”

## Licencia

Sin licencia clara del upstream: tratad el repo como **research artifacts**. Añadid `LICENSE` (p. ej. MIT) solo para **vuestro** código nuevo (`.py`, `.bat`, docs); no implica licencia sobre firmware UnlockCD/Apple.
