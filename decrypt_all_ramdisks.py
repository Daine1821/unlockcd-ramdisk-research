#!/usr/bin/env python3
"""
Decrypt UnlockCD bundled ramdisk *.zip.enc packages (AES-256-CBC + SHA-256 verify).
Derives keys by trying KDF candidates matching derivedRamdiskKeyHexForModel:version:
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

SECRET_HEX = (
    "4e3b401770b929ebc6a1bd327a3c571fe682b8ab258640dd6ddaef178ba248d3"
)

DEFAULT_RAMDISKS_DIR = Path(
    r"E:\OTROS ARCHIVOS IMPORTANTES\ramdisk tool"
    r"\UnlockCD-Ramdisk-V1.0.app\Contents\Resources\ramdisks"
)
DEFAULT_OUT_DIR = Path(
    r"E:\OTROS ARCHIVOS IMPORTANTES\ramdisk tool\ramdisks_extracted"
)

WORKING_KDF_NAME: str | None = "HMAC-SHA256(secret_ascii, model_version)"


def derive_ramdisk_key(model: str, version: str) -> bytes:
    """Key from UnlockCDRamdisk derivedRamdiskKeyHexForModel:version: (reversed)."""
    tag = f"{model}_{version}".encode("utf-8")
    return hmac.new(SECRET_HEX.encode("ascii"), tag, hashlib.sha256).digest()


def sha256_bytes(data: bytes) -> bytes:
    return hashlib.sha256(data).digest()


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_text_hex(path: Path) -> str:
    return path.read_text(encoding="ascii").strip().lower()


def parse_model_version(basename: str) -> tuple[str, str]:
    """iPhone11_26.1 -> (iPhone11, 26.1)"""
    m = re.match(r"^(.+)_(\d+\.\d+)$", basename)
    if not m:
        raise ValueError(f"Cannot parse model/version from basename: {basename}")
    return m.group(1), m.group(2)


def kdf_candidates(model: str, version: str) -> list[tuple[str, bytes]]:
    """Return (name, 32-byte AES key) candidates."""
    secret_raw = bytes.fromhex(SECRET_HEX)
    secret_ascii = SECRET_HEX.encode("ascii")
    model_b = model.encode("utf-8")
    version_b = version.encode("utf-8")
    tag = f"{model}_{version}".encode("utf-8")
    tag_nounderscore = f"{model}{version}".encode("utf-8")

    out: list[tuple[str, bytes]] = []
    seen: set[bytes] = set()

    def add(name: str, material: bytes) -> None:
        key = sha256_bytes(material)
        if key not in seen:
            seen.add(key)
            out.append((name, key))

    parts_variants = [
        ("tag", tag),
        ("tag_no_us", tag_nounderscore),
        ("model_ver", model_b + b"_" + version_b),
        ("modelver", model_b + version_b),
    ]
    secrets = [("raw32", secret_raw), ("ascii64", secret_ascii)]
    for sname, sbytes in secrets:
        for pname, part in parts_variants:
            add(f"SHA256({sname}+{pname})", sbytes + part)
            add(f"SHA256({pname}+{sname})", part + sbytes)
        add(f"SHA256({sname}+model+_+ver)", sbytes + model_b + b"_" + version_b)

    # NSString stringWithFormat:@"%@%@%@" (secret, model, version) — with/without underscore
    for sname, sbytes in secrets:
        add(f"SHA256({sname}+model+version)", sbytes + model_b + version_b)
        add(
            f"SHA256({sname}+model+_+version)",
            sbytes + model_b + b"_" + version_b,
        )

    add("SHA256(secret_raw)", secret_raw)
    add("SHA256(secret_ascii)", secret_ascii)
    add("direct_secret_raw", secret_raw)  # unlikely

    prot = b"protection-key-2026"
    for part in (tag, model_b + b"_" + version_b):
        add("SHA256(protection-key-2026+tag)", prot + part)
        add("SHA256(tag+protection-key-2026)", part + prot)

    # Observed in UnlockCDRamdisk: HMAC-SHA256(secret_ascii, model_version tag)
    for part in (tag, model_b + b"_" + version_b, tag_nounderscore):
        hm = hmac.new(secret_ascii, part, hashlib.sha256).digest()
        if hm not in seen:
            seen.add(hm)
            out.insert(0, (f"HMAC-SHA256(ascii64,{part.decode()})", hm))
        hm2 = hmac.new(secret_raw, part, hashlib.sha256).digest()
        if hm2 not in seen:
            seen.add(hm2)
            out.insert(0, (f"HMAC-SHA256(raw32,{part.decode()})", hm2))

    for mid in (b"_", b"", b"-", b"."):
        add(
            f"SHA256(raw+model+{mid!r}+ver)",
            secret_raw + model_b + mid + version_b,
        )
        add(
            f"SHA256(ascii+model+{mid!r}+ver)",
            secret_ascii + model_b + mid + version_b,
        )

    # Double SHA-256 on primary concatenations
    primary = [
        secret_raw + tag,
        secret_ascii + tag,
        secret_raw + model_b + b"_" + version_b,
        secret_ascii + model_b + b"_" + version_b,
        tag + secret_raw,
        tag + secret_ascii,
    ]
    for idx, material in enumerate(primary):
        d1 = sha256_bytes(material)
        add(f"SHA256(SHA256(primary{idx}))", d1)

    # HMAC-SHA256 variants (fallback ordering)
    for sname, sbytes in secrets:
        for part in (tag, model_b + b"_" + version_b):
            hm = hmac.new(sbytes, part, hashlib.sha256).digest()
            if hm not in seen:
                seen.add(hm)
                out.append((f"HMAC-SHA256({sname},tag)", hm))

    return out


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


def _ps_decrypt_block(key: bytes, iv: bytes, block16: bytes) -> bytes:
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
        raise RuntimeError(proc.stderr.strip() or "AES block decrypt failed")
    return base64.b64decode(proc.stdout.strip())


def aes256_cbc_decrypt_file(key: bytes, iv: bytes, enc_path: Path, out_path: Path) -> None:
    helper = Path(__file__).with_name("_aes_decrypt_file.ps1")
    helper.write_text(_PS_AES, encoding="utf-8")
    k64 = base64.b64encode(key).decode("ascii")
    i64 = base64.b64encode(iv).decode("ascii")
    proc = subprocess.run(
        [
            "powershell",
            "-NoProfile",
            "-NonInteractive",
            "-File",
            str(helper),
            "-KeyB64",
            k64,
            "-IvB64",
            i64,
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
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or "AES file decrypt failed")


def discover_kdf(
    enc_path: Path, iv_hex: str, expected_sha: str, model: str, version: str
) -> tuple[str, bytes] | tuple[None, None]:
    global WORKING_KDF_NAME
    iv = bytes.fromhex(iv_hex)
    block0 = enc_path.read_bytes()[:16]
    candidates = kdf_candidates(model, version)
    tmp_plain = enc_path.with_suffix(".plain.tmp")

    for name, key in candidates:
        try:
            head = _ps_decrypt_block(key, iv, block0)
        except Exception:
            continue
        if not head.startswith(b"PK"):
            continue
        try:
            if tmp_plain.exists():
                tmp_plain.unlink()
            aes256_cbc_decrypt_file(key, iv, enc_path, tmp_plain)
            digest = sha256_hex(tmp_plain.read_bytes())
        except Exception:
            continue
        if digest == expected_sha.lower():
            WORKING_KDF_NAME = name
            return name, key
        if tmp_plain.exists():
            tmp_plain.unlink()
    return None, None


def decrypt_with_key(
    enc_path: Path, iv_hex: str, key: bytes, expected_sha: str
) -> bytes:
    iv = bytes.fromhex(iv_hex)
    tmp_plain = enc_path.with_suffix(".plain.tmp")
    if tmp_plain.exists():
        tmp_plain.unlink()
    aes256_cbc_decrypt_file(key, iv, enc_path, tmp_plain)
    plaintext = tmp_plain.read_bytes()
    tmp_plain.unlink()
    if sha256_hex(plaintext) != expected_sha.lower():
        raise ValueError("SHA-256 mismatch after decrypt")
    if not plaintext.startswith(b"PK"):
        raise ValueError("Plaintext is not a ZIP (missing PK header)")
    return plaintext


def unzip_to( zip_path: Path, dest_dir: Path) -> None:
    if dest_dir.exists():
        shutil.rmtree(dest_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path, "r") as zf:
        zf.extractall(dest_dir)


def main() -> int:
    ramdisks_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_RAMDISKS_DIR
    out_dir = Path(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_OUT_DIR
    out_dir.mkdir(parents=True, exist_ok=True)

    enc_files = sorted(ramdisks_dir.glob("*.zip.enc"))
    if not enc_files:
        print(f"No *.zip.enc files under {ramdisks_dir}", file=sys.stderr)
        return 1

    ok: list[str] = []
    fail: list[str] = []

    for enc_path in enc_files:
        basename = enc_path.name[: -len(".zip.enc")]
        iv_path = enc_path.with_suffix(enc_path.suffix + ".iv")
        sha_path = ramdisks_dir / f"{basename}.sha256"
        if not iv_path.is_file():
            fail.append(f"{basename}: missing IV file")
            continue
        if not sha_path.is_file():
            fail.append(f"{basename}: missing .sha256")
            continue
        try:
            model, version = parse_model_version(basename)
        except ValueError as e:
            fail.append(f"{basename}: {e}")
            continue

        iv_hex = read_text_hex(iv_path)
        expected_sha = read_text_hex(sha_path)
        print(f"Decrypting {basename} ...", flush=True)
        key = derive_ramdisk_key(model, version)
        try:
            plaintext = decrypt_with_key(enc_path, iv_hex, key, expected_sha)
        except Exception as exc:
            # Fallback: brute KDF list (older bundles / future formats)
            found = discover_kdf(enc_path, iv_hex, expected_sha, model, version)
            if found[0] is None:
                fail.append(f"{basename}: decrypt failed ({exc}); no fallback KDF")
                continue
            global WORKING_KDF_NAME
            WORKING_KDF_NAME = found[0]
            plaintext = decrypt_with_key(enc_path, iv_hex, found[1], expected_sha)
        kdf_name = WORKING_KDF_NAME

        zip_out = out_dir / f"{basename}.zip"
        zip_out.write_bytes(plaintext)
        folder_out = out_dir / basename
        unzip_to(zip_out, folder_out)
        ok.append(basename)
        print(f"  OK  KDF={kdf_name}  -> {folder_out}")

    print()
    print("=" * 60)
    if WORKING_KDF_NAME:
        print(f"Working KDF: {WORKING_KDF_NAME}")
    else:
        print("Working KDF: (none succeeded)")
    print(f"Extracted ({len(ok)}): {', '.join(ok) if ok else '(none)'}")
    if fail:
        print(f"Failed ({len(fail)}):")
        for line in fail:
            print(f"  - {line}")

    iphone_dir = out_dir / "iPhone11_26.1"
    if iphone_dir.is_dir():
        print()
        print("iPhone11_26.1 contents:")
        for p in sorted(iphone_dir.rglob("*")):
            rel = p.relative_to(iphone_dir)
            if p.is_dir():
                print(f"  [dir]  {rel}/")
            else:
                print(f"  [file] {rel}  ({p.stat().st_size} bytes)")

    return 0 if ok and not fail else (0 if ok else 1)


if __name__ == "__main__":
    raise SystemExit(main())
