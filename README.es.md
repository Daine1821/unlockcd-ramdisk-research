# UnlockCD Ramdisk — investigación y port Windows

**Español** · [English](README.md)

Espejo comunitario de **artefactos de investigación** extraídos del bundle **UnlockCD Ramdisk V1.0** (Mac): herramientas de descifrado local, flujo de boot, scripts de montaje HFZ en `/mnt2`, y un **kit .bat para Windows**.

---

## Aviso legal (léelo primero)

| | |
|---|---|
| **Finalidad** | **Solo educación e investigación en seguridad.** No es un producto, soporte ni servicio de bypass. |
| **Apple** | **Sin relación, respaldo ni autorización de Apple Inc.** iPhone, iOS y nombres relacionados son marcas de Apple. El firmware en `ramdisks_extracted/` es **material de Apple/terceros**; este repo **no** te otorga licencia para usarlo más allá de lo que permita la ley. |
| **UnlockCD** | **Sin afiliación con UnlockCD** ni sus autores. Si usas la app original, cumple **sus** condiciones. Aquí documentamos lo extraído para estudio; no sustituye ni “crackea” el producto. |
| **Tú** | Eres responsable de leyes locales, propiedad del dispositivo y políticas de plataformas (GitHub incluido). **Usa solo dispositivos tuyos o con permiso explícito.** |

---

## Contenido del repositorio

| Ruta | Descripción |
|------|-------------|
| `decrypt_all_ramdisks.py` | Descifra `*.zip.enc` → `ramdisks_extracted/` |
| `decrypt_all_encrypted.py` | `start.sh`, `give.sh`, `restore.sh`, `mnt2.macho` |
| `scripts_encrypted_extracted/` | Scripts macOS descifrados + `MANIFEST.txt` |
| `mount_mnt2_extracted/` | Helpers mount/backup del `.app` |
| `UnlockCD-Windows/` | Boot → SSH → mount (ver `SETUP_TOOLS.bat`) |
| `ramdisks_extracted/` | IM4P, `boot_order.json`, `.dmg` universal, etc. (**pesado**, Git LFS) |

---

## Requisitos

- Windows 10+, **Python 3.10+**
- iPhone/iPad en **DFU o Recovery**, cable USB
- Herramientas (no todas van en el repo): **`irecovery`**, **`iproxy`**, **OpenSSH** / **`sshpass`** — `UnlockCD-Windows/SETUP_TOOLS.bat`
- Opcional: **Usbliter8Boot** para DFU pwned (ver Agradecimientos)

---

## Descifrado (tu `.app` o los extracts incluidos)

```bat
DESENPAQUETAR_RAMDISKS.bat
DESENCRIPTAR_TODO.bat
```

Las claves están documentadas en los `.py` (HMAC ramdisk vs cadena de protección de scripts).

---

## Flujo Windows (borrador)

1. `UnlockCD-Windows\1_BOOT.bat` — DFU `ibss.raw` → Recovery → `boot_order.json`
2. `2_SSH_PROXY.bat` → `3_SSH_CONECTAR.bat` (`alpine` por defecto)
3. `4_MOUNT.bat` — `remote_mount_dynamic.sh` por SSH (montaje HFZ `/mnt2`)

Detalle en `UnlockCD-Windows/LEEME.txt`.

---

## Ayuda buscada (issues / PRs)

- [ ] Boot estable **Recovery → ramdisk** (kernel / SEP vs `boot_order.json`)
- [ ] Equivalente Windows de **`mnt2.macho`** / menú Mac
- [ ] Documentación completa de **KDF** y `.enc`
- [ ] CI ligero (solo lint; sin firmware en CI)

---

## Archivos grandes y LFS

`ramdisks_extracted/` incluye `.dmg` / `.zip` de cientos de MB. El repo usa **Git LFS** para `*.dmg` y `*.zip`. Clona con [Git LFS](https://git-lfs.com/) instalado.

---

## Licencia

- **Código y documentación original** de este repo (`.py`, `.bat`, `README*`, etc.): **[MIT License](LICENSE)** © Daine1821.
- **Firmware, IM4P, ramdisk, ciphertext UnlockCD y componentes Apple**: **no licenciados por este proyecto**; siguen sujetos a Apple y/o titulares originales.

---

## Agradecimientos

- **[libimobiledevice](https://libimobiledevice.org/)** — ecosistema `irecovery` y restore por USB.
- **[libusbmuxd](https://github.com/libimobiledevice/libusbmuxd)** / **`iproxy`** — túnel SSH por USB.
- **Usbliter8 / herramientas checkm8 USB** — DFU pwned y boot custom junto a `irecovery` (crédito a autores y comunidad **Usbliter8**; no redistribuimos sus binarios por defecto).
- **UnlockCD Ramdisk (macOS)** — estructura del bundle que documentamos (**sin respaldo ni afiliación**).
- Referencias comunitarias (cadenas de boot, ramdisks, montaje) que ayudaron a validar comportamiento — gracias a quien comparte investigación **responsable**.

---

*Si mantienes una herramienta que debamos citar con nombre/URL, abre un issue.*
