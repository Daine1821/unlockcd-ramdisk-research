#!/usr/bin/env python3
"""
Ejecuta boot_order.json del pack UnlockCD tal cual, sin reordenar ni sustituir.

boot_order.json lo genera el propio UnlockCD desde BuildManifest.plist:
  - filename        = nombre real del componente (kernelcache.release.iphone12b, etc)
  - irecv_command   = comando irecovery tras subirlo (firmware/ramdisk/devicetree/
                      rsepfirmware/setpicture/bootx)
  - send_order      = orden de envio
  - wait_disconnect = tras el comando el device se desconecta (kernel/bootx)

iPhone11_26.1 no trae .dmg: RestoreRamDisk/RestoreTrustCache viven en
universal_26.1 (26.1.dmg + 26.1.dmg.trustcache), que es como viene el bundle.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

# 043-53775-129 = build 26.1; el ramdisk/trustcache son el pack universal
UNIVERSAL_RAMDISK_MAP = {
    "043-53775-129.dmg": "26.1.dmg",
    "043-53775-129.dmg.trustcache": "26.1.dmg.trustcache",
}


def load_config() -> dict:
    root = Path(os.environ.get("UCW_ROOT", Path(__file__).resolve().parents[1]))
    fw_dev = Path(
        os.environ.get(
            "FW_DEVICE",
            root.parent / "ramdisks_extracted/iPhone11_26.1/iPhone11_26.1",
        )
    )
    fw_univ = Path(
        os.environ.get(
            "FW_UNIV",
            root.parent / "ramdisks_extracted/universal_26.1/universal_26.1",
        )
    )
    return {
        "fw_dev": fw_dev,
        "fw_univ": fw_univ,
        "tools": Path(os.environ.get("TOOLS", root / "tools")),
        # vacio = usar el setenv boot-args que trae boot_order.json
        "boot_args": os.environ.get("UNLOCKCD_BOOT_ARGS", "").strip(),
    }


def irecovery_exe(tools: Path) -> str:
    exe = tools / "irecovery.exe"
    return str(exe if exe.is_file() else Path("irecovery"))


def irecovery(tools: Path, *args: str) -> int:
    print("[irecovery]", " ".join(args), flush=True)
    return subprocess.run([irecovery_exe(tools), *args]).returncode


def irecovery_mode(tools: Path) -> str:
    r = subprocess.run(
        [irecovery_exe(tools), "-q"], capture_output=True, text=True
    )
    for line in ((r.stdout or "") + (r.stderr or "")).splitlines():
        if line.startswith("MODE:"):
            return line.split(":", 1)[1].strip()
    return ""


def resolve_file(name: str, fw_dev: Path, fw_univ: Path) -> Path:
    mapped = UNIVERSAL_RAMDISK_MAP.get(name)
    if mapped:
        p = fw_univ / mapped
        if not p.is_file():
            raise FileNotFoundError(f"Falta ramdisk universal: {p}")
        print(f"[resolve] {name} -> universal/{mapped}", flush=True)
        return p
    p = fw_dev / name
    if not p.is_file():
        raise FileNotFoundError(f"Falta en el pack: {p}")
    return p


def load_sequence(fw_dev: Path) -> list[dict]:
    data = json.loads((fw_dev / "boot_order.json").read_text(encoding="utf-8"))
    return sorted(data.get("sequence") or [], key=lambda s: s.get("send_order", 0))


def wait_disconnect(tools: Path, seconds: int = 60) -> bool:
    print(f"[wait_disconnect] esperando que salga de Recovery ({seconds}s)...", flush=True)
    for _ in range(seconds):
        if irecovery_mode(tools) != "Recovery":
            print("[wait_disconnect] OK, el device se desconecto (kernel arrancando)", flush=True)
            return True
        time.sleep(1)
    print("[wait_disconnect] SIGUE en Recovery: iBoot no arranco el kernel", flush=True)
    return False


def wait_reconnect(tools: Path, seconds: int = 60) -> bool:
    print(f"[wait_reconnect] esperando reconexion ({seconds}s)...", flush=True)
    for _ in range(seconds):
        if irecovery_mode(tools):
            return True
        time.sleep(1)
    return False


def run_sequence(cfg: dict) -> bool:
    tools, fw_dev, fw_univ = cfg["tools"], cfg["fw_dev"], cfg["fw_univ"]
    booted = True

    for step in load_sequence(fw_dev):
        action = step.get("action")

        if action == "command":
            cmd = step.get("command") or ""
            if cfg["boot_args"] and "boot-args" in cmd:
                cmd = f"setenv boot-args {cfg['boot_args']}"
            irecovery(tools, "-c", cmd)
            continue

        if action != "component":
            continue

        fname = step.get("filename")
        icmd = step.get("irecv_command") or "firmware"
        if not fname:
            continue

        path = resolve_file(fname, fw_dev, fw_univ)
        print(f"[{step.get('name')}] {path.name} -> {icmd}", flush=True)
        if irecovery(tools, "-f", str(path)) != 0:
            print(f"ERROR subiendo {path.name}", file=sys.stderr)
            return False
        irecovery(tools, "-c", icmd)

        if step.get("wait_disconnect"):
            booted = wait_disconnect(tools)
        if step.get("wait_reconnect"):
            wait_reconnect(tools)

    return booted


def main() -> int:
    cfg = load_config()
    fw_dev, fw_univ, tools = cfg["fw_dev"], cfg["fw_univ"], cfg["tools"]

    if not (fw_dev / "boot_order.json").is_file():
        print(f"Falta {fw_dev / 'boot_order.json'}", file=sys.stderr)
        return 1

    mode = irecovery_mode(tools)
    if mode != "Recovery":
        print(f"ERROR: se necesita MODE Recovery, hay '{mode or 'sin device'}'", file=sys.stderr)
        return 1

    print(f"Device pack   : {fw_dev}")
    print(f"Universal pack: {fw_univ}")
    print(f"boot-args     : {cfg['boot_args'] or 'los del boot_order.json'}")

    if not run_sequence(cfg):
        print(
            "\nFALLO: el device sigue en Recovery tras bootx.\n"
            "Diagnostico real (ver el error de iBoot):\n"
            "  irecovery -s      -> consola de iBoot, escribe: bootx\n",
            file=sys.stderr,
        )
        return 2

    print("Boot enviado; el device salio de Recovery.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
