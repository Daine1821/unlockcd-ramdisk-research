#!/usr/bin/env python3
"""
Decrypt UnlockCD Resources encrypted blobs:
  - ramdisks/*.zip.enc  (existing KDF)
  - *.sh.enc, mnt2.enc  (script KDF via derivedScriptKeyHexForScriptNamed:)

Output: scripts_encrypted_extracted/ + ramdisks_extracted/ (optional)
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

# Reuse ramdisk constants from sibling script
SECRET_HEX = (
    "4e3b401770b929ebc6a1bd327a3c571fe682b8ab258640dd6ddaef178ba248d3"
)
SCRIPT_PROTECTION = "UnlockCD-Ramdisk-v1-script-protection-key-2026"

DEFAULT_RESOURCES = Path(
    r"E:\OTROS ARCHIVOS IMPORTANTES\ramdisk tool"
    r"\UnlockCD-Ramdisk-V1.0.app\Contents\Resources"
)
DEFAULT_SCRIPTS_OUT = Path(
    r"E:\OTROS ARCHIVOS IMPORTANTES\ramdisk tool\scripts_encrypted_extracted"
)
DEFAULT_RAMDISKS_OUT = Path(
    r"E:\OTROS ARCHIVOS IMPORTANTES\ramdisk tool\ramdisks_extracted"
)

_PS_AES = r"""
param(
  [Parameter(Mandatory=$true)][string]$KeyB64,
  [Parameter(Mandatory=$true)][string]$IvB64,
  [Parameter(Mandatory=$true)][string]$InPath,
  [Parameter(Mandatory=$true)][string]$OutPath
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$key = [Convert]::FromBase64String($KeyB64)
$iv = [Convert]::FromBase64String($IvB64)
$aes = [System.Security.Cryptography.Aes]::Create()
$aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
$aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
$aes.Key = $key
$aes.IV = $iv
$dec = $aes.CreateDecryptor()
$inStream = [System.IO.File]::OpenRead($InPath)
$outStream = [System.IO.File]::Create($OutPath)
$crypto = New-Object System.Security.Cryptography.CryptoStream($inStream, $dec, [System.Security.Cryptography.CryptoStreamMode]::Read)
$buf = New-Object byte[] 1048576
while (($n = $crypto.Read($buf, 0, $buf.Length)) -gt 0) { [void]$outStream.Write($buf, 0, $n) }
$crypto.Dispose(); $inStream.Dispose(); $outStream.Dispose()
"""


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_iv_hex(path: Path) -> bytes:
    return bytes.fromhex(path.read_text(encoding="ascii").strip().lower())


def aes256_cbc_decrypt_file(key: bytes, iv: bytes, enc_path: Path, out_path: Path) -> None:
    helper = Path(__file__).with_name("_aes_decrypt_file.ps1")
    helper.write_text(_PS_AES, encoding="utf-8")
    proc = subprocess.run(
        [
            "powershell",
            "-NoProfile",
            "-NonInteractive",
            "-File",
            str(helper),
            "-KeyB64",
            base64.b64encode(key).decode("ascii"),
            "-IvB64",
            base64.b64encode(iv).decode("ascii"),
            "-InPath",
            str(enc_path),
            "-OutPath",
            str(out_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or "AES decrypt failed")


def _ps_decrypt_block(key: bytes, iv: bytes, block16: bytes) -> bytes | None:
    k64 = base64.b64encode(key).decode("ascii")
    i64 = base64.b64encode(iv).decode("ascii")
    c64 = base64.b64encode(block16).decode("ascii")
    ps = (
        "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.Security; "
        f"$k=[Convert]::FromBase64String('{k64}'); $v=[Convert]::FromBase64String('{i64}'); "
        f"$c=[Convert]::FromBase64String('{c64}'); "
        "$a=[System.Security.Cryptography.Aes]::Create(); "
        "$a.Mode=[System.Security.Cryptography.CipherMode]::CBC; "
        "$a.Padding=[System.Security.Cryptography.PaddingMode]::None; "
        "$a.Key=$k; $a.IV=$v; $d=$a.CreateDecryptor(); "
        "[Convert]::ToBase64String($d.TransformFinalBlock($c,0,$c.Length))"
    )
    proc = subprocess.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command", ps],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        return None
    return base64.b64decode(proc.stdout.strip())


def normalize_key(key: bytes) -> bytes:
    if len(key) == 32:
        return key
    if len(key) == 16:
        return key + key
    raise ValueError(f"bad key length {len(key)}")


def script_name_for_enc(enc_path: Path) -> str:
    name = enc_path.name
    if name == "mnt2.enc":
        return "mnt2.sh"
    if name.endswith(".sh.enc"):
        return name[: -len(".enc")]  # start.sh
    stem = enc_path.stem
    if stem.endswith(".enc"):
        stem = stem[:-4]
    return stem if stem.endswith(".sh") else f"{stem}.sh"


def logical_script_names(enc_path: Path) -> list[str]:
    """Names passed to derivedScriptKeyHexForScriptNamed: (filename variants)."""
    primary = script_name_for_enc(enc_path)
    names = [primary]
    if enc_path.name == "mnt2.enc":
        names = ["mnt2", "mnt2.sh", "mnt2.enc", primary]
    out: list[str] = []
    for n in names:
        out.extend(script_name_variants(n))
    return list(dict.fromkeys(out))


def script_name_variants(logical: str) -> list[str]:
    base = logical.replace(".sh", "")
    return list(
        dict.fromkeys(
            [
                logical,
                base,
                f"{base}.sh",
                logical.replace(".sh", ".enc"),
                base + ".enc",
            ]
        )
    )


def script_kdf_candidates(script_logical: str) -> list[tuple[str, bytes]]:
    secret_raw = bytes.fromhex(SECRET_HEX)
    secret_ascii = SECRET_HEX.encode("ascii")
    prot_b = SCRIPT_PROTECTION.encode("utf-8")

    secrets: list[tuple[str, bytes]] = [
        ("script_prot", prot_b),
        ("secret_ascii", secret_ascii),
        ("secret_raw", secret_raw),
        ("sha256_script_prot", hashlib.sha256(prot_b).digest()),
        ("sha256_secret_ascii", hashlib.sha256(secret_ascii).digest()),
        ("sha256_secret_raw", hashlib.sha256(secret_raw).digest()),
    ]

    out: list[tuple[str, bytes]] = []
    seen: set[bytes] = set()

    def add(label: str, key: bytes) -> None:
        try:
            k = normalize_key(key)
        except ValueError:
            return
        if k in seen:
            return
        seen.add(k)
        out.append((label, k))

    for tag in script_name_variants(script_logical):
        tag_b = tag.encode("utf-8")
        for sname, sbytes in secrets:
            add(f"HMAC-SHA256({sname},{tag})", hmac.new(sbytes, tag_b, hashlib.sha256).digest())
            add(f"HMAC-SHA256({sname},utf16,{tag})", hmac.new(sbytes, tag.encode("utf-16le"), hashlib.sha256).digest())
            add(f"SHA256({sname}+{tag})", hashlib.sha256(sbytes + tag_b).digest())
            add(f"SHA256({tag}+{sname})", hashlib.sha256(tag_b + sbytes).digest())
            add(f"SHA256({sname}+:{tag})", hashlib.sha256(sbytes + b":" + tag_b).digest())

        # NSString format guesses: protection + script
        for mid in (b"", b":", b"/", b"_"):
            add(
                f"SHA256(prot+mid+{tag})",
                hashlib.sha256(prot_b + mid + tag_b).digest(),
            )

    # Same secret as ramdisks but script tag
    for tag in script_name_variants(script_logical):
        add(
            f"ramdisk-style HMAC ascii {tag}",
            hmac.new(secret_ascii, tag.encode("utf-8"), hashlib.sha256).digest(),
        )

    return out


def plaintext_score(data: bytes) -> int:
    if not data:
        return -999
    score = 0
    head = data[:512].lstrip(b"\xef\xbb\xbf")
    if head.startswith(b"\xca\xfe\xba\xbe") or head.startswith(b"\xce\xfa\xed\xfe"):
        score += 120  # Mach-O fat / thin
    if head.startswith(b"#!/"):
        score += 100
    if head.startswith(b"set -e") or head.startswith(b"set -eu"):
        score += 60
    if b"bash" in head[:120] or b"/bin/sh" in head[:120]:
        score += 40
    if head.startswith(b"PK"):
        score += 80
    printable = sum(32 <= b < 127 or b in (9, 10, 13) for b in head[:256])
    score += printable // 2
    if printable < min(len(head[:256]), 256) * 0.45 and score < 80:
        score -= 50
    return score


def fast_script_keys_for_tag(tag: str) -> list[tuple[str, bytes]]:
    prot_b = SCRIPT_PROTECTION.encode("utf-8")
    return [(f"HMAC-SHA256(script_prot,{tag})", hmac.new(prot_b, tag.encode(), hashlib.sha256).digest())]


def discover_script_key(enc_path: Path, iv: bytes) -> tuple[str, bytes] | None:
    block0 = enc_path.read_bytes()[:16]
    best: tuple[int, str, bytes] | None = None
    seen_keys: set[bytes] = set()

    def consider(kname: str, key: bytes, head: bytes | None) -> None:
        nonlocal best
        if key in seen_keys:
            return
        seen_keys.add(key)
        if head is None:
            head = _ps_decrypt_block(key, iv, block0)
        if not head:
            return
        sc = plaintext_score(head)
        if sc < 25:
            return
        if best is None or sc > best[0]:
            best = (sc, kname, key)

    # Fast path (matches UnlockCD derivedScriptKeyHexForScriptNamed:)
    for logical in logical_script_names(enc_path):
        for kname, key in fast_script_keys_for_tag(logical):
            consider(kname, key, None)

    if best is not None:
        return best[1], best[2]

    for logical in logical_script_names(enc_path):
        for kname, key in script_kdf_candidates(logical):
            if key in seen_keys:
                continue
            consider(kname, key, None)
    if best is None:
        return None
    return best[1], best[2]


def decrypt_script_blob(
    enc_path: Path, iv_path: Path, out_path: Path
) -> tuple[str, bytes]:
    iv = read_iv_hex(iv_path)
    logical = script_name_for_enc(enc_path)
    found = discover_script_key(enc_path, iv)
    if found is None:
        raise RuntimeError(
            f"no KDF matched for {enc_path.name} (tried {logical_script_names(enc_path)})"
        )
    kname, key = found
    tmp = out_path.with_suffix(out_path.suffix + ".tmp")
    if tmp.exists():
        tmp.unlink()
    aes256_cbc_decrypt_file(key, iv, enc_path, tmp)
    plain = tmp.read_bytes()
    tmp.unlink()
    if plaintext_score(plain) < 20:
        raise RuntimeError(f"decrypted {enc_path.name} but plaintext looks invalid")
    out_path.write_bytes(plain)
    return kname, key


def collect_encrypted_scripts(resources: Path) -> list[Path]:
    out: list[Path] = []
    for p in sorted(resources.iterdir()):
        if not p.is_file():
            continue
        if p.name.endswith(".zip.enc"):
            continue
        if p.name.endswith(".enc") and not p.name.endswith(".enc.iv"):
            out.append(p)
    return out


def output_name_for_enc(enc_path: Path, plain: bytes) -> str:
    if enc_path.name == "mnt2.enc":
        if plain.startswith(b"\xca\xfe\xba\xbe") or plain.startswith(b"\xce\xfa\xed\xfe"):
            return "mnt2.macho"
        return "mnt2.sh"
    logical = script_name_for_enc(enc_path)
    return logical if logical.endswith(".sh") else enc_path.name.replace(".enc", "")


def decrypt_ramdisks(resources: Path, out_dir: Path) -> tuple[list[str], list[str]]:
    """Import logic from decrypt_all_ramdisks if present."""
    ramdisks_dir = resources / "ramdisks"
    if not ramdisks_dir.is_dir():
        return [], ["ramdisks/ missing"]
    try:
        import importlib.util

        spec = importlib.util.spec_from_file_location(
            "decrypt_ram", Path(__file__).with_name("decrypt_all_ramdisks.py")
        )
        if spec is None or spec.loader is None:
            raise ImportError("no spec")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    except Exception as exc:
        return [], [f"ramdisk module: {exc}"]

    ok: list[str] = []
    fail: list[str] = []
    out_dir.mkdir(parents=True, exist_ok=True)
    for enc_path in sorted(ramdisks_dir.glob("*.zip.enc")):
        basename = enc_path.name[: -len(".zip.enc")]
        iv_path = enc_path.with_suffix(enc_path.suffix + ".iv")
        sha_path = ramdisks_dir / f"{basename}.sha256"
        if not iv_path.is_file() or not sha_path.is_file():
            fail.append(f"{basename}: missing iv/sha256")
            continue
        try:
            model, version = mod.parse_model_version(basename)
            iv_hex = mod.read_text_hex(iv_path)
            expected_sha = mod.read_text_hex(sha_path)
            key = mod.derive_ramdisk_key(model, version)
            plain = mod.decrypt_with_key(enc_path, iv_hex, key, expected_sha)
        except Exception as exc:
            found = mod.discover_kdf(
                enc_path,
                mod.read_text_hex(iv_path),
                mod.read_text_hex(sha_path),
                *mod.parse_model_version(basename),
            )
            if found[0] is None:
                fail.append(f"{basename}: {exc}")
                continue
            plain = mod.decrypt_with_key(
                enc_path,
                mod.read_text_hex(iv_path),
                found[1],
                mod.read_text_hex(sha_path),
            )
        zip_out = out_dir / f"{basename}.zip"
        zip_out.write_bytes(plain)
        folder_out = out_dir / basename
        if folder_out.exists():
            shutil.rmtree(folder_out)
        folder_out.mkdir(parents=True)
        with zipfile.ZipFile(zip_out, "r") as zf:
            zf.extractall(folder_out)
        ok.append(basename)
    return ok, fail


def main() -> int:
    resources = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_RESOURCES
    scripts_out = Path(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_SCRIPTS_OUT
    do_ramdisks = "--ramdisks" in sys.argv or "-r" in sys.argv
    ramdisks_out = DEFAULT_RAMDISKS_OUT

    if not resources.is_dir():
        print(f"Missing {resources}", file=sys.stderr)
        return 1

    scripts_out.mkdir(parents=True, exist_ok=True)
    enc_sources = scripts_out / "encrypted_sources"
    enc_sources.mkdir(parents=True, exist_ok=True)

    manifest_lines = [
        "UnlockCD encrypted assets — decrypted output",
        f"Source: {resources}",
        "",
    ]

    script_ok: list[str] = []
    script_fail: list[str] = []

    for enc_path in collect_encrypted_scripts(resources):
        iv_path = resources / f"{enc_path.name}.iv"
        if not iv_path.is_file():
            script_fail.append(f"{enc_path.name}: missing {iv_path.name}")
            continue
        tmp_out = scripts_out / "_decrypt.tmp"
        print(f"Decrypting {enc_path.name} ...", flush=True)
        try:
            kname, _key = decrypt_script_blob(enc_path, iv_path, tmp_out)
            plain = tmp_out.read_bytes()
            out_name = output_name_for_enc(enc_path, plain)
            out_path = scripts_out / out_name
            if out_path.exists():
                out_path.unlink()
            tmp_out.replace(out_path)
            script_ok.append(enc_path.name)
            manifest_lines.append(f"OK  {enc_path.name} -> {out_name}  KDF={kname}")
            shutil.copy2(enc_path, enc_sources / enc_path.name)
            shutil.copy2(iv_path, enc_sources / iv_path.name)
        except Exception as exc:
            tmp_out.unlink(missing_ok=True)
            script_fail.append(f"{enc_path.name}: {exc}")
            manifest_lines.append(f"FAIL {enc_path.name}: {exc}")

    if do_ramdisks:
        print("Decrypting ramdisks/*.zip.enc ...", flush=True)
        rok, rfail = decrypt_ramdisks(resources, ramdisks_out)
        manifest_lines.extend(["", "Ramdisks:"])
        for b in rok:
            manifest_lines.append(f"OK  {b}.zip.enc")
        for line in rfail:
            manifest_lines.append(f"FAIL {line}")

    manifest_lines.extend(
        [
            "",
            f"Scripts OK ({len(script_ok)}): {', '.join(script_ok) or '(none)'}",
            f"Scripts FAIL ({len(script_fail)}):",
        ]
    )
    manifest_lines.extend(f"  - {x}" for x in script_fail)
    manifest_lines.extend(
        [
            "",
            "Script KDF (expected): derivedScriptKeyHexForScriptNamed:",
            f"  protection string: {SCRIPT_PROTECTION}",
            "  AES-256-CBC, IV from *.enc.iv, PKCS7 padding",
        ]
    )

    (scripts_out / "MANIFEST.txt").write_text("\n".join(manifest_lines) + "\n", encoding="utf-8")
    print()
    print("\n".join(manifest_lines))
    return 0 if script_ok and not script_fail else (0 if script_ok else 1)


if __name__ == "__main__":
    raise SystemExit(main())
