#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"


ROOT="${ROOT:-${SCRIPT_DIR}}"
EXTRACTED_ROOT="${EXTRACTED_ROOT:-${ROOT}/extracted}"
TOOLS_DIR="${TOOLS_DIR:-${ROOT}/tools}"
IM4M="${IM4M:-${TOOLS_DIR}/27.im4m}"
IBOOT_MAPPING="${IBOOT_MAPPING:-${TOOLS_DIR}/iboot_mapping.json}"
IRECOVERY="${IRECOVERY:-${TOOLS_DIR}/irecovery}"
IMG4TOOL="${IMG4TOOL:-${TOOLS_DIR}/img4tool}"
USBLITER8="${USBLITER8:-${TOOLS_DIR}/usbliter8ctl}"
GASTER="${GASTER:-${TOOLS_DIR}/gaster}"
WORK_ROOT="${WORK_ROOT:-${ROOT}/work_full}"
TARGET_IOS_CACHE="${TARGET_IOS_CACHE:-${WORK_ROOT}/target_ios_by_ecid.tsv}"
IMG4_CACHE="${IMG4_CACHE:-${WORK_ROOT}/img4}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-90}"
SLEEP_AFTER_IBSS="${SLEEP_AFTER_IBSS:-8}"
STEP_SLEEP="${STEP_SLEEP:-0.7}"
IRECOVERY_CMD_TIMEOUT="${IRECOVERY_CMD_TIMEOUT:-12}"
DFU_BOOT_TIMEOUT="${DFU_BOOT_TIMEOUT:-45}"
DFU_PWN_TIMEOUT="${DFU_PWN_TIMEOUT:-60}"
SKIP_IBSS="${SKIP_IBSS:-0}"
DRY_RUN="${DRY_RUN:-0}"

APP_IPROXY="${APP_IPROXY:-${TOOLS_DIR}/iproxy.resource}"
FORCE_MODEL=""
FORCE_VERSION=""
FORCE_ECID=""
LIST_ONLY="0"
NO_IMG4="0"
DYNAMIC_SEP="${DYNAMIC_SEP:-1}"
DYNAMIC_SEP_ROOT="${DYNAMIC_SEP_ROOT:-${WORK_ROOT}/dynamic_sep}"
IPSW_URL="${IPSW_URL:-}"
IPSWME_TIMEOUT="${IPSWME_TIMEOUT:-5}"
BOOT_ARGS="${BOOT_ARGS:-rd=md0 -progress}"
FORCE_TARGET_VERSION="${TARGET_VERSION:-}"
FORCE_TARGET_BUILD="${TARGET_BUILD:-}"
TARGET_VERSION_EXPLICIT=0
[ -n "${TARGET_VERSION:-}" ] && TARGET_VERSION_EXPLICIT=1
IMG4_MODE="${IMG4_MODE:-original}"

log(){ printf '\033[1;36m[+]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[-]\033[0m %s\n' "$*" >&2; exit 1; }
need_file(){ [ -f "$1" ] || die "missing file: $1"; }
need_exec(){ [ -x "$1" ] || die "missing executable: $1"; }

usage(){
  cat <<EOF
Usage: $0 [options]
  --model MODEL        ， iPhoneXSMaxGlobal / iPhone11 / iPad9
  --version VERSION    ， 18.3 / 26.1
  -v, --ios-version V   iOS  SEP； build/ SEP， 18.2.1
  --ecid HEX            ECID
  --skip-ibss           DFU ibss.raw， Recovery/iBoot
  --no-img4             IMG4，，
  --no-dynamic-sep      SEP ， SEP
  --target-version V    -v/--ios-version： SEP， 18.7.9
  --target-build B     ： BuildVersion， 22H355； build
  env IPSWME_TIMEOUT=N ipsw.me ， 5； Apple  catalog
  env DFU_BOOT_TIMEOUT=N  ibss.raw ， 45
  env DFU_PWN_TIMEOUT=N   gaster pwn ， 60
  --dry-run            ，
  --list               
  -h, --help           
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --model) [ "$#" -ge 2 ] || die "--model needs value"; FORCE_MODEL="$2"; shift 2;;
    --version) [ "$#" -ge 2 ] || die "--version needs value"; FORCE_VERSION="$2"; shift 2;;
    -v|--ios-version|--target-version) [ "$#" -ge 2 ] || die "$1 needs value"; FORCE_TARGET_VERSION="$2"; TARGET_VERSION_EXPLICIT=1; shift 2;;
    --ecid) [ "$#" -ge 2 ] || die "--ecid needs value"; FORCE_ECID="$2"; shift 2;;
    --skip-ibss) SKIP_IBSS="1"; shift;;
    --no-img4) NO_IMG4="1"; shift;;
    --no-dynamic-sep) DYNAMIC_SEP="0"; shift;;
    --target-build) [ "$#" -ge 2 ] || die "--target-build needs value"; FORCE_TARGET_BUILD="$2"; shift 2;;
    --dry-run) DRY_RUN="1"; shift;;
    --list) LIST_ONLY="1"; shift;;
    -h|--help) usage; exit 0;;
    *) die "unknown option: $1";;
  esac
done

irec(){
  if [ -n "$FORCE_ECID" ]; then
    "$IRECOVERY" -i "$FORCE_ECID" "$@"
  else
    "$IRECOVERY" "$@"
  fi
}

irec_cmd(){
  if [ -n "$FORCE_ECID" ]; then
    run_timeout_capture "$IRECOVERY_CMD_TIMEOUT" "$IRECOVERY" -i "$FORCE_ECID" -c "$1"
  else
    run_timeout_capture "$IRECOVERY_CMD_TIMEOUT" "$IRECOVERY" -c "$1"
  fi
}

list_packages(){
  find "$EXTRACTED_ROOT" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sed 's#^.*/##' | sort
}
available_versions(){
  model_arg="$1"
  list_packages | awk -F_ -v m="$model_arg" '$1==m {print $2}' | sort -V
}
pick_last_version(){
  available_versions "$1" | tail -n 1
}
package_dir(){
  printf '%s/%s_%s\n' "$EXTRACTED_ROOT" "$1" "$2"
}
universal_dir(){
  printf '%s/universal_%s\n' "$EXTRACTED_ROOT" "$1"
}

if [ "$LIST_ONLY" = "1" ]; then
  list_packages
  exit 0
fi

need_file "$IM4M"
need_file "$IBOOT_MAPPING"
need_exec "$IRECOVERY"
need_exec "$IMG4TOOL"
if [ "$SKIP_IBSS" != "1" ]; then
  need_exec "$USBLITER8"
  need_exec "$GASTER"
fi
mkdir -p "$IMG4_CACHE" "$WORK_ROOT" "$DYNAMIC_SEP_ROOT"

query_device(){
  set +e
  out_text="$(irec -q 2>&1)"
  rc_val="$?"
  set -e
  printf '%s\n' "$out_text"
  return "$rc_val"
}

get_field(){
  q_text="$1"
  key_name="$2"
  printf '%s\n' "$q_text" | awk -F'[:=]' -v k="$key_name" 'toupper($1)==toupper(k){sub(/^[ \t]+/,"",$2); sub(/[ \t\r]+$/, "", $2); print $2; exit}'
}

normalize_hex(){
  hex_in="${1:-}"
  hex_in="${hex_in#0x}"
  hex_in="${hex_in#0X}"
  printf '%s' "$hex_in" | tr '[:lower:]' '[:upper:]'
}

cache_target_ios_get(){
  ecid_key="$(normalize_hex "${1:-}")"
  [ -n "$ecid_key" ] || return 1
  [ -f "$TARGET_IOS_CACHE" ] || return 1
  awk -F'\t' -v e="$ecid_key" '$1==e && $2!="" {v=$2; b=$3} END{if(v!=""){if(b!="") print v"\t"b; else print v}}' "$TARGET_IOS_CACHE"
}

cache_target_ios_set(){
  ecid_key="$(normalize_hex "${1:-}")"
  ios_ver="${2:-}"
  ios_build="${3:-}"
  [ -n "$ecid_key" ] && [ -n "$ios_ver" ] || return 0
  mkdir -p "$(dirname "$TARGET_IOS_CACHE")"
  tmp_file="${TARGET_IOS_CACHE}.$$"
  if [ -f "$TARGET_IOS_CACHE" ]; then
    awk -F'\t' -v e="$ecid_key" '$1!=e {print}' "$TARGET_IOS_CACHE" > "$tmp_file"
  else
    : > "$tmp_file"
  fi
  printf '%s\t%s\t%s\n' "$ecid_key" "$ios_ver" "$ios_build" >> "$tmp_file"
  mv "$tmp_file" "$TARGET_IOS_CACHE"
}

map_product_to_model(){
  prod="$1"
  hw_model="$2"
  bdid_val="$3"
  case "$prod" in
    iPhone11,2) printf '%s\n' iPhoneXS; return 0;;
    iPhone11,4) printf '%s\n' iPhoneXSMax; return 0;;
    iPhone11,6) printf '%s\n' iPhoneXSMaxGlobal; return 0;;
    iPhone11,8) printf '%s\n' iPhoneXR; return 0;;
    iPhone12,1) printf '%s\n' iPhone11; return 0;;
    iPhone12,3) printf '%s\n' iPhone11Pro; return 0;;
    iPhone12,5) printf '%s\n' iPhone11ProMax; return 0;;
    iPhone12,8) printf '%s\n' iPhoneSE2; return 0;;
    iPad11,6|iPad11,7) printf '%s\n' iPad8; return 0;;
    iPad12,1|iPad12,2) printf '%s\n' iPad9; return 0;;
    iPad11,3|iPad11,4) printf '%s\n' iPadAir3; return 0;;
    iPad11,1|iPad11,2) printf '%s\n' iPadmini5; return 0;;
    iPad8,*) printf '%s\n' iPad8; return 0;;
  esac

  hw_lc="$(printf '%s' "$hw_model" | tr '[:upper:]' '[:lower:]')"
  case "$hw_lc" in
    d321ap) printf '%s\n' iPhoneXS; return 0;;
    d331ap) printf '%s\n' iPhoneXSMax; return 0;;
    d331pap) printf '%s\n' iPhoneXSMaxGlobal; return 0;;
    n841ap) printf '%s\n' iPhoneXR; return 0;;
    n104ap) printf '%s\n' iPhone11; return 0;;
    d421ap) printf '%s\n' iPhone11Pro; return 0;;
    d431ap) printf '%s\n' iPhone11ProMax; return 0;;
    d79ap) printf '%s\n' iPhoneSE2; return 0;;
    j171aap|j172aap) printf '%s\n' iPad8; return 0;;
    j181ap|j182ap) printf '%s\n' iPad9; return 0;;
    j210ap|j211ap|j217ap|j218ap) printf '%s\n' iPadAir3; return 0;;
  esac

  bdid_norm="$(normalize_hex "$bdid_val")"
  case "$bdid_norm" in
    0E) printf '%s\n' iPhoneXS; return 0;;
    0A) printf '%s\n' iPhoneXSMax; return 0;;
    1A) printf '%s\n' iPhoneXSMaxGlobal; return 0;;
  esac
  return 1
}

detect_iboot_version(){
  q_text="$1"
  printf '%s\n' "$q_text" | grep -Eo 'iBoot-[0-9A-Za-z_.~:-]+' | head -n 1 || true
}

map_iboot_to_ios(){
  iboot_ver="$1"
  [ -n "$iboot_ver" ] || return 1
  /usr/bin/python3 - "$IBOOT_MAPPING" "$iboot_ver" <<'PY'
import json, sys
path = sys.argv[1]
iboot = sys.argv[2]
with open(path, 'r') as f:
    data = json.load(f)
for item in data.get('mappings', []):
    if item.get('iboot_version') == iboot:
        print(item.get('ios_version', ''))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

resolve_version(){
  model_name="$1"
  q_text="$2"
  if [ -n "$FORCE_VERSION" ]; then
    printf '%s\n' "$FORCE_VERSION"
    return 0
  fi

  iboot_ver="$(detect_iboot_version "$q_text")"
  ios_ver="$(map_iboot_to_ios "$iboot_ver" 2>/dev/null || true)"
  if [ -n "$ios_ver" ]; then
    major_ver="$(printf '%s' "$ios_ver" | awk -F. '{print $1}')"

    preferred_ver=""
    case "$major_ver" in
      12|13|14|15|16|17|18) preferred_ver="18.3" ;;
      26) preferred_ver="26.1" ;;
    esac
    if [ -n "$preferred_ver" ] && [ -d "$(package_dir "$model_name" "$preferred_ver")" ]; then
      log "iBoot : ${iboot_ver} -> ${ios_ver};  ${preferred_ver}" >&2
      printf '%s\n' "$preferred_ver"
      return 0
    fi

    candidate_dir="$(package_dir "$model_name" "$ios_ver")"
    if [ -d "$candidate_dir" ]; then
      log "iBoot : ${iboot_ver} -> ${ios_ver}" >&2
      printf '%s\n' "$ios_ver"
      return 0
    fi
  fi

  last_ver="$(pick_last_version "$model_name")"
  if [ -z "$last_ver" ]; then
    return 1
  fi
  if [ -n "$ios_ver" ]; then
    warn " iOS=${ios_ver}, /; fallback  ${last_ver}"
  else
    warn " iBoot ; fallback  ${last_ver};  --version "
  fi
  printf '%s\n' "$last_ver"
}

resolve_component_file(){
  dev_dir_arg="$1"
  uni_dir_arg="$2"
  version_arg="$3"
  name_arg="$4"
  file_arg="$5"
  if [ -f "${dev_dir_arg}/${file_arg}" ]; then
    printf '%s\n' "${dev_dir_arg}/${file_arg}"
    return 0
  fi
  if [ -f "${uni_dir_arg}/${file_arg}" ]; then
    printf '%s\n' "${uni_dir_arg}/${file_arg}"
    return 0
  fi
  if [ "$name_arg" = "RestoreRamDisk" ]; then
    alt_file="${uni_dir_arg}/${version_arg}.dmg"
    if [ -f "$alt_file" ]; then printf '%s\n' "$alt_file"; return 0; fi
  fi
  if [ "$name_arg" = "RestoreTrustCache" ]; then
    alt_file="${uni_dir_arg}/${version_arg}.dmg.trustcache"
    if [ -f "$alt_file" ]; then printf '%s\n' "$alt_file"; return 0; fi
  fi
  return 1
}

img4_payload_name(){
  cmd_arg="$1"
  name_arg="$2"
  case "$cmd_arg" in
    setpicture*) printf '%s\n' rlgo;;
    ramdisk) printf '%s\n' rdsk;;
    devicetree) printf '%s\n' rdtr;;
    rsepfirmware) printf '%s\n' rsep;;
    bootx) printf '%s\n' rkrn;;
    firmware)
      if [ "$name_arg" = "RestoreTrustCache" ]; then printf '%s\n' rtsc; else printf '%s\n' ""; fi;;
    *) printf '%s\n' "";;
  esac
}

cleanup_dynamic_sep_cache(){
  if [ -d "$DYNAMIC_SEP_ROOT" ]; then
    old_dirs="$(find "$DYNAMIC_SEP_ROOT" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort | awk 'BEGIN{n=0}{a[++n]=$0} END{for(i=1;i<=n-8;i++) print a[i]}')"
    if [ -n "$old_dirs" ]; then printf '%s\n' "$old_dirs" | while IFS= read -r d; do rm -rf "$d"; done; fi
    find "$DYNAMIC_SEP_ROOT" -type f \( -name '*.tmp' -o -name '*.partial' \) -delete 2>/dev/null || true
  fi
}

expected_sep_basename(){
  case "${1:-}" in
    iPhone11,2) printf '%s\n' sep-firmware.d321.RELEASE.im4p;;
    iPhone11,4) printf '%s\n' sep-firmware.d331.RELEASE.im4p;;
    iPhone11,6) printf '%s\n' sep-firmware.d331p.RELEASE.im4p;;
    iPhone12,8) printf '%s\n' sep-firmware.d79.RELEASE.im4p;;
    *) return 1;;
  esac
}

find_cached_dynamic_sep(){
  product_arg="${1:-}"
  version_arg="${2:-}"
  build_arg="${3:-}"
  expected="$(expected_sep_basename "$product_arg" 2>/dev/null || true)"
  [ -n "$expected" ] || return 1
  safe_product="$(printf '%s' "$product_arg" | tr ',' '_')"
  if [ -n "$version_arg" ] && [ -n "$build_arg" ]; then
    cand="${DYNAMIC_SEP_ROOT}/${safe_product}_${version_arg}_${build_arg}/${expected}"
    [ -f "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  fi
  if [ -n "$version_arg" ]; then
    find "$DYNAMIC_SEP_ROOT" -maxdepth 2 -type f -path "*/${safe_product}_${version_arg}_*/${expected}" -print 2>/dev/null | sort | tail -n 1
    return 0
  fi
  find "$DYNAMIC_SEP_ROOT" -maxdepth 2 -type f -path "*/${safe_product}_*/${expected}" -print 2>/dev/null | sort | tail -n 1
}

resolve_dynamic_sep(){
  product_arg="$1"
  bundle_major="$2"
  [ "$DYNAMIC_SEP" = "1" ] || return 1
  [ -n "$product_arg" ] || return 1
  command -v /usr/bin/python3 >/dev/null 2>&1 || return 1

  /usr/bin/python3 - "$product_arg" "$bundle_major" "$FORCE_TARGET_VERSION" "$FORCE_TARGET_BUILD" "$DYNAMIC_SEP_ROOT" "$IPSW_URL" "$IPSWME_TIMEOUT" <<'PYSEP'
import sys, os, json, urllib.request, struct, zlib, plistlib, re
product, bundle_major, force_version, force_build, root, override_url, ipswme_timeout_s = sys.argv[1:8]
try:
    ipswme_timeout = max(1, int(float(ipswme_timeout_s)))
except Exception:
    ipswme_timeout = 5
os.makedirs(root, exist_ok=True)
def fail(msg):
    print(msg, file=sys.stderr); raise SystemExit(1)
def select_via_ipswme():
    api = f"https://api.ipsw.me/v4/device/{product}?type=ipsw"
    try:
        with urllib.request.urlopen(urllib.request.Request(api, headers={'User-Agent':'Mozilla/5.0 HFZRamdiskHook/1.0', 'Accept':'application/json', 'Connection':'close'}), timeout=ipswme_timeout) as r:
            info=json.load(r)
    except Exception as e:
        raise RuntimeError(f"ipsw.me query failed/timeout after {ipswme_timeout}s: {e}")
    def ver_key(x):
        ver=str(x.get('version',''))
        nums=[]
        for part in ver.split('.'):
            try: nums.append(int(''.join(ch for ch in part if ch.isdigit()) or 0))
            except Exception: nums.append(0)
        while len(nums)<4: nums.append(0)
        return tuple(nums), str(x.get('releasedate','')), str(x.get('buildid',''))
    firmwares=sorted(info.get('firmwares') or [], key=ver_key, reverse=True)
    chosen=None; mode2='ipsw-me-metadata-latest-signed-same-major'
    for f in firmwares:
        ver=str(f.get('version','')); b=str(f.get('buildid',''))
        if force_version and ver != force_version: continue
        if force_build and b != force_build: continue
        if not force_version and bundle_major and not ver.startswith(str(bundle_major)+'.'): continue
        if not f.get('signed'): continue
        chosen=f; mode2='ipsw-me-metadata-explicit-version' if force_version else 'ipsw-me-metadata-latest-signed-same-major'; break
    if chosen is None and force_version:
        for f in firmwares:
            ver=str(f.get('version','')); b=str(f.get('buildid',''))
            if ver == force_version and (not force_build or b == force_build):
                chosen=f; mode2='ipsw-me-metadata-explicit-version-unsigned-ok'; break
    if chosen is None: raise RuntimeError('no matching IPSW from ipsw.me')
    return str(chosen.get('version')), str(chosen.get('buildid')), chosen.get('url'), mode2

def select_via_apple_catalog():
    catalogs = [
        'https://mesu.apple.com/assets/com_apple_MobileAsset_SoftwareUpdate/com_apple_MobileAsset_SoftwareUpdate.xml',
        'https://mesu.apple.com/assets/com_apple_MobileAsset_SoftwareUpdate/com_apple_MobileAsset_SoftwareUpdate.plist',
    ]
    last = None
    assets = []
    for cat in catalogs:
        try:
            req = urllib.request.Request(cat, headers={'User-Agent':'MobileAsset/1.0', 'Accept':'*/*', 'Connection':'close'})
            with urllib.request.urlopen(req, timeout=12) as r:
                data = r.read()
            obj = plistlib.loads(data)
            assets = obj.get('Assets') or obj.get('assets') or []
            if assets:
                break
        except Exception as e:
            last = e
            continue
    if not assets:
        raise RuntimeError(f'Apple catalog unavailable: {last}')
    cand = []
    for a in assets:
        if not isinstance(a, dict):
            continue
        ver = str(a.get('OSVersion') or a.get('Version') or a.get('ProductVersion') or '')
        build = str(a.get('Build') or a.get('BuildVersion') or a.get('ProductBuildVersion') or '')
        devices = a.get('SupportedDevices') or a.get('SupportedProductTypes') or a.get('Devices') or []
        if isinstance(devices, str):
            devices = [devices]
        urls = []
        for k in ('FirmwareURL', 'FirmwareURLOverride', 'AssetURL', '__BaseURL'):
            u = a.get(k)
            if isinstance(u, str): urls.append(u)
        for aa in a.get('Assets') or []:
            if isinstance(aa, dict):
                for k in ('FirmwareURL', 'FirmwareURLOverride', 'AssetURL'):
                    u = aa.get(k)
                    if isinstance(u, str): urls.append(u)
        urls = [u for u in urls if u.startswith(('https://updates.cdn-apple.com/', 'http://updates.cdn-apple.com/')) and u.endswith('.ipsw')]
        if not urls:
            continue
        if force_version and ver and ver != force_version:
            continue
        if force_build and build and build != force_build:
            continue
        if not force_version and bundle_major and ver and not ver.startswith(str(bundle_major)+'.'):
            continue
        dev_ok = (product in devices) or any(product in u for u in urls)
        if not dev_ok:
            continue
        if (not ver or not build):
            m = re.search(r'_(\d+(?:\.\d+){1,3})_([0-9A-Z]+)_Restore\.ipsw', urls[0])
            if m:
                ver = ver or m.group(1)
                build = build or m.group(2)
        cand.append((ver_tuple(ver), ver, build, urls[0]))
    cand.sort(reverse=True)
    if not cand:
        raise RuntimeError('Apple catalog has no matching IPSW')
    _, ver, build, url = cand[0]
    return ver, build, url, 'apple-official-catalog'

def ver_tuple(ver):
    nums=[]
    for part in str(ver or '').split('.'):
        nums.append(int(''.join(ch for ch in part if ch.isdigit()) or 0))
    while len(nums)<4: nums.append(0)
    return tuple(nums)
def source_json_candidates():
    out=[]
    if not os.path.isdir(root): return out
    for base, dirs, files in os.walk(root):
        if 'source.json' not in files: continue
        sp=os.path.join(base,'source.json')
        try:
            j=json.load(open(sp))
        except Exception:
            continue
        if str(j.get('product','')) != product: continue
        ver=str(j.get('version','')); build=str(j.get('build','')); url=str(j.get('url',''))
        if force_version and ver != force_version: continue
        if force_build and build != force_build: continue
        if not force_version and bundle_major and not ver.startswith(str(bundle_major)+'.'): continue
        if not (url.startswith('https://updates.cdn-apple.com/') or url.startswith('http://updates.cdn-apple.com/')): continue
        out.append((ver_tuple(ver), ver, build, url, sp))
    return sorted(out, reverse=True)
chosen=None
mode=''
known_apple_urls = {
    ('iPhone11,6', '18.7.9', '22H355'): 'https://updates.cdn-apple.com/2026WinterFCS/fullrestores/122-55581/CF2D9050-DB02-4236-8BCA-B6034061E0A5/iPhone11,2,iPhone11,4,iPhone11,6_18.7.9_22H355_Restore.ipsw',
}
def known_apple_candidates():
    out=[]
    for (prod, ver, build), u in known_apple_urls.items():
        if prod != product: continue
        if force_version and ver != force_version: continue
        if force_build and build != force_build: continue
        if not force_version and bundle_major and not ver.startswith(str(bundle_major)+'.'): continue
        out.append((ver_tuple(ver), ver, build, u, 'builtin-apple-url'))
    return sorted(out, reverse=True)
if override_url:
    version=force_version or 'manual'
    build=force_build or 'manual'
    url=override_url
    mode='apple-url-env'
else:
    builtin_cands=known_apple_candidates()
    cands=source_json_candidates()
    if builtin_cands:
        _, version, build, url, sp = builtin_cands[0]
        mode='apple-url-builtin:'+sp
    elif cands:
        _, version, build, url, sp = cands[0]
        mode='apple-url-cache:'+sp
    else:
        try:
            version, build, url, mode = select_via_ipswme()
        except Exception as e:
            print(f"dynamic SEP: ipsw.me unavailable, fallback to Apple official catalog: {e}", file=sys.stderr)
            version, build, url, mode = select_via_apple_catalog()
print(f"dynamic SEP: selected IPSW {product} {version} {build} [{mode}]", file=sys.stderr)
if not url: fail('dynamic SEP: IPSW URL missing')
apple_fast = mode.startswith('apple-url-') and not override_url
safe=f"{product}_{version}_{build}".replace('/','_').replace(',','_')
outdir=os.path.join(root, safe); os.makedirs(outdir, exist_ok=True)
for n in os.listdir(outdir):
    if n.startswith('sep-firmware') and (n.endswith('.im4p') or n.endswith('.tmp') or n.endswith('.partial')):
        try:
            os.unlink(os.path.join(outdir,n))
        except FileNotFoundError:
            pass
def open_retry(req, timeout, label, tries=6):
    if apple_fast:
        timeout=min(timeout, 8)
        tries=min(tries, 2)
    last=None
    for i in range(tries):
        try:
            return urllib.request.urlopen(req, timeout=timeout)
        except Exception as e:
            last=e
            print(f'dynamic SEP: {label} retry {i+1}/{tries}: {e}', file=sys.stderr)
            import time; time.sleep(min(2+i*2, 10))
    raise last

def req_range(start,end):
    headers={
        'Range':f'bytes={start}-{end}',
        'User-Agent':'Mozilla/5.0 HFZRamdiskHook/1.0',
        'Accept':'*/*',
        'Connection':'close',
    }
    req=urllib.request.Request(url, headers=headers)
    with open_retry(req, 180, f'range {start}-{end}') as r:
        return r.read()

def content_len():
    headers={'User-Agent':'Mozilla/5.0 HFZRamdiskHook/1.0', 'Accept':'*/*', 'Connection':'close'}
    try:
        req=urllib.request.Request(url, method='HEAD', headers=headers)
        with open_retry(req, 60, 'HEAD') as r:
            return int(r.headers['Content-Length'])
    except Exception as e:
        print(f'dynamic SEP: HEAD failed, fallback Range 0-0: {e}', file=sys.stderr)
        req=urllib.request.Request(url, headers={**headers, 'Range':'bytes=0-0'})
        with open_retry(req, 60, 'range 0-0') as r:
            cr=r.headers.get('Content-Range','')
            if '/' in cr:
                return int(cr.rsplit('/',1)[1])
            cl=r.headers.get('Content-Length')
            if cl: return int(cl)
            raise RuntimeError('cannot determine IPSW Content-Length')
def fetch_zip_index():
    size=content_len(); tail_size=min(size,1024*1024); tail=req_range(size-tail_size,size-1)
    pos=tail.rfind(b'PK\x05\x06')
    if pos<0: fail('dynamic SEP: EOCD not found')
    sig,disk,cd_disk,disk_entries,total_entries,cd_size,cd_off,comment_len=struct.unpack('<IHHHHIIH',tail[pos:pos+22])
    if cd_off==0xffffffff or cd_size==0xffffffff:
        loc=tail.rfind(b'PK\x06\x07')
        if loc<0: fail('dynamic SEP: ZIP64 locator not found')
        _sig,_disk,z64_off,_disks=struct.unpack('<IIQI',tail[loc:loc+20])
        z64=req_range(z64_off,z64_off+56-1)
        vals=struct.unpack('<IQHHIIQQQQ',z64[:56])
        cd_size=vals[8]; cd_off=vals[9]
    return req_range(cd_off,cd_off+cd_size-1)
try:
    cd=fetch_zip_index()
except SystemExit: raise
except Exception as e:
    if apple_fast:
        print(f'dynamic SEP: Apple URL fast path failed, falling back to ipsw.me metadata: {e}', file=sys.stderr)
        version, build, url, mode = select_via_ipswme()
        if not url: fail('dynamic SEP: IPSW URL missing from ipsw.me')
        apple_fast = False
        safe=f"{product}_{version}_{build}".replace('/','_').replace(',','_')
        outdir=os.path.join(root, safe); os.makedirs(outdir, exist_ok=True)
        print(f"dynamic SEP: selected IPSW {product} {version} {build} [{mode}]", file=sys.stderr)
        try:
            cd=fetch_zip_index()
        except Exception as e2:
            fail(f'dynamic SEP: remote ZIP index failed after Apple+ipsw.me fallback: {e2}')
    else:
        fail(f'dynamic SEP: remote ZIP index failed: {e}')
entries={}; i=0
while i+46 <= len(cd) and cd[i:i+4]==b'PK\x01\x02':
    vals=struct.unpack('<IHHHHHHIIIHHHHHII',cd[i:i+46])
    _,_,_,flag,method,_,_,crc,csize,usize,nlen,xlen,clen,_,_,_,lh_off=vals
    name=cd[i+46:i+46+nlen].decode('utf-8','replace')
    extra=cd[i+46+nlen:i+46+nlen+xlen]
    if csize==0xffffffff or usize==0xffffffff or lh_off==0xffffffff:
        j=0
        while j+4<=len(extra):
            hid,sz=struct.unpack('<HH',extra[j:j+4]); body=extra[j+4:j+4+sz]
            if hid==0x0001:
                k=0
                if usize==0xffffffff and k+8<=len(body): usize=struct.unpack('<Q',body[k:k+8])[0]; k+=8
                if csize==0xffffffff and k+8<=len(body): csize=struct.unpack('<Q',body[k:k+8])[0]; k+=8
                if lh_off==0xffffffff and k+8<=len(body): lh_off=struct.unpack('<Q',body[k:k+8])[0]; k+=8
                break
            j += 4+sz
    entries[name]={'method':method,'csize':csize,'usize':usize,'lh_off':lh_off}
    i += 46+nlen+xlen+clen
def extract(name):
    e=entries[name]; hdr=req_range(e['lh_off'],e['lh_off']+29)
    if hdr[:4]!=b'PK\x03\x04': fail('dynamic SEP: bad local header '+name)
    sig,ver,flag,method,_,_,_,_,_,nlen,xlen=struct.unpack('<IHHHHHIIIHH',hdr)
    start=e['lh_off']+30+nlen+xlen
    comp=req_range(start,start+e['csize']-1)
    if e['method']==0: return comp
    if e['method']==8: return zlib.decompress(comp,-15)
    fail(f'dynamic SEP: unsupported compression {e["method"]} for {name}')
try:
    bm_name='BuildManifest.plist' if 'BuildManifest.plist' in entries else next((n for n in entries if n.endswith('/BuildManifest.plist')),None)
    if not bm_name: fail('dynamic SEP: BuildManifest.plist not found')
    bm_data=extract(bm_name); bm=plistlib.loads(bm_data)
    sep_rel=None
    preferred_sep_base={
        'iPhone11,2':'sep-firmware.d321.RELEASE.im4p',
        'iPhone11,4':'sep-firmware.d331.RELEASE.im4p',
        'iPhone11,6':'sep-firmware.d331p.RELEASE.im4p',
        'iPhone12,8':'sep-firmware.d79.RELEASE.im4p',
    }.get(product)
    fallback_sep=None
    for ident in bm.get('BuildIdentities',[]):
        comp=(ident.get('Manifest',{}) or {}).get('SEP') or (ident.get('Manifest',{}) or {}).get('RestoreSEP')
        p=((comp or {}).get('Info') or {}).get('Path')
        if not p: continue
        base=os.path.basename(p)
        if preferred_sep_base and base.lower()==preferred_sep_base.lower():
            sep_rel=p; break
        if fallback_sep is None:
            fallback_sep=p
    if sep_rel is None:
        sep_rel=fallback_sep
    if not sep_rel: fail('dynamic SEP: SEP path not found in BuildManifest')
    sep_name=sep_rel if sep_rel in entries else next((n for n in entries if n.endswith(sep_rel) or n.endswith('/'+sep_rel) or n.endswith(os.path.basename(sep_rel))),None)
    if not sep_name: fail('dynamic SEP: SEP file not found in IPSW: '+sep_rel)
    sep_data=extract(sep_name)
except SystemExit: raise
except Exception as e: fail(f'dynamic SEP: extraction failed: {e}')
tmp=os.path.join(outdir, os.path.basename(sep_name)+'.tmp')
out=os.path.join(outdir, os.path.basename(sep_name))
open(tmp,'wb').write(sep_data); os.replace(tmp,out)
open(os.path.join(outdir,'BuildManifest.plist'),'wb').write(bm_data)
open(os.path.join(outdir,'source.json'),'w').write(json.dumps({'product':product,'version':version,'build':build,'url':url,'sep_path':sep_name,'output':out,'mode':'online-range-extract-no-cache-reuse'},indent=2))
print(out)
PYSEP
}

is_img4_or_im4p(){
  xxd -p -l 32 "$1" | tr -d '\n' | grep -qiE '494d3450|494d4734'
}
is_img4(){
  xxd -p -l 32 "$1" | tr -d '\n' | grep -qi '494d4734'
}

safe_name(){
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

version_le(){
  /usr/bin/python3 - "$1" "$2" <<'PYVER'
import re, sys

def parts(v):
    nums=[int(x) for x in re.findall(r'\d+', v or '')[:3]]
    while len(nums)<3: nums.append(0)
    return nums[:3]
sys.exit(0 if parts(sys.argv[1]) <= parts(sys.argv[2]) else 1)
PYVER
}

wrap_img4(){
  src_file="$1"
  cmd_arg="$2"
  name_arg="$3"
  order_arg="$4"

  if [ "$NO_IMG4" = "1" ] || [ "$IMG4_MODE" = "none" ]; then
    printf '%s\n' "$src_file"
    return 0
  fi
  if is_img4 "$src_file"; then
    printf '%s\n' "$src_file"
    return 0
  fi
  if ! is_img4_or_im4p "$src_file"; then
    printf '%s\n' "$src_file"
    return 0
  fi

  base_name="$(basename "$src_file")"
  clean_name="$(safe_name "$base_name")"
  ptype="$(img4_payload_name "$cmd_arg" "$name_arg")"
  payload_file="$src_file"

  if [ -n "$ptype" ]; then
    renamed_file="${IMG4_CACHE}/$(printf '%03d_%s.%s.im4p' "$order_arg" "$clean_name" "$ptype")"
    if [ ! -f "$renamed_file" ] || [ "$renamed_file" -ot "$src_file" ]; then
      log "IM4P rename: ${base_name} -> payload=${ptype}" >&2
      if [ "$DRY_RUN" != "1" ]; then
        "$IMG4TOOL" -n "$ptype" -o "$renamed_file" "$src_file" >/dev/null
      fi
    fi
    payload_file="$renamed_file"
  fi

  out_file="${IMG4_CACHE}/$(printf '%03d_%s.img4' "$order_arg" "$clean_name")"
  if [ -f "$out_file" ] && [ "$out_file" -nt "$src_file" ] && [ "$out_file" -nt "$IM4M" ]; then
    printf '%s\n' "$out_file"
    return 0
  fi

  if [ -n "$ptype" ]; then
    log "IMG4 wrap: $(basename "$payload_file") + 27.im4m -> $(basename "$out_file")" >&2
  else
    log "IMG4 wrap: ${base_name} + 27.im4m -> $(basename "$out_file") preserve-payload" >&2
  fi
  if [ "$DRY_RUN" != "1" ]; then
    "$IMG4TOOL" -c "$out_file" -p "$payload_file" -m "$IM4M" >/dev/null
  fi
  printf '%s\n' "$out_file"
}

run_timeout_capture(){
  timeout_s="$1"; shift
  /usr/bin/python3 - "$timeout_s" "$@" <<'PYTIME'
import subprocess, sys
try:
    timeout = float(sys.argv[1])
except Exception:
    timeout = 45.0
cmd = sys.argv[2:]
try:
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        out, _ = p.communicate(timeout=timeout)
        if out:
            print(out, end='')
        raise SystemExit(p.returncode)
    except subprocess.TimeoutExpired:
        p.kill()
        out, _ = p.communicate()
        if out:
            print(out, end='')
        print(f"TIMEOUT after {timeout:g}s: {' '.join(cmd)}")
        raise SystemExit(124)
except FileNotFoundError as e:
    print(str(e))
    raise SystemExit(127)
PYTIME
}


is_pwned_dfu(){
  q_now="$(query_device || true)"
  printf '%s\n' "$q_now" | grep -qi 'PWND:' && return 0
  return 1
}

dfu_pwn_once(){
  log "DFU pwn stage: gaster pwn"
  set +e
  pwn_out="$(run_timeout_capture "$DFU_PWN_TIMEOUT" "$GASTER" pwn 2>&1)"
  pwn_rc="$?"
  set -e
  printf '%s\n' "$pwn_out"
  if [ "$pwn_rc" -ne 0 ]; then
    warn "gaster pwn returned rc=${pwn_rc}; will still try ibss in case device is already pwned"
  fi
  sleep 2
}

send_ibss_like_app(){
  ibss_file="$1"
  need_file "$ibss_file"
  if is_pwned_dfu; then
    log "DFU already appears pwned; skip gaster pwn"
  else
    dfu_pwn_once
  fi
  attempt=1
  while [ "$attempt" -le 2 ]; do
    log "DFU stage: send ibss.raw via usbliter8ctl attempt ${attempt}/2 timeout=${DFU_BOOT_TIMEOUT}s"
    set +e
    dfu_out="$(run_timeout_capture "$DFU_BOOT_TIMEOUT" "$USBLITER8" boot "$ibss_file" 2>&1)"
    dfu_rc="$?"
    set -e
    printf '%s\n' "$dfu_out"
    if [ "$dfu_rc" -eq 0 ]; then
      return 0
    fi
    if printf '%s\n' "$dfu_out" | grep -qiE 'ignored DFU_ABORT error after CUSTOM_BOOT|DFU_ABORT|CUSTOM_BOOT'; then
      warn "usbliter8ctl reported DFU_ABORT after CUSTOM_BOOT; treating as expected DFU disconnect"
      return 0
    fi
    if [ "$attempt" -eq 1 ]; then
      warn "ibss send failed/timeout; retry after pwn check"
      if is_pwned_dfu; then
        log "DFU still appears pwned; retry ibss without gaster"
      else
        dfu_pwn_once
      fi
    fi
    attempt=$((attempt+1))
  done
  die "usbliter8ctl boot failed after retries"
}

wait_recovery(){
  deadline=$((SECONDS + WAIT_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if q_now="$(query_device)"; then
      printf '%s\n' "$q_now" | grep -E 'MODE|CPID|BDID|ECID|PRODUCT|MODEL|SRNM|Serial|iBoot' || true
      return 0
    fi
    sleep 1
  done
  return 1
}

send_cmd(){
  cmd_to_send="$1"
  log "CMD: ${cmd_to_send}"
  if [ "$DRY_RUN" != "1" ]; then
    irec_cmd "$cmd_to_send" || warn "command returned non-zero/timeout: ${cmd_to_send}"
  fi
  sleep "$STEP_SLEEP"
}

send_file_then_cmd(){
  file_to_send="$1"
  cmd_to_send="$2"
  if [ "$DRY_RUN" != "1" ]; then need_file "$file_to_send"; fi
  log "FILE: $(basename "$file_to_send") -> ${cmd_to_send}"
  if [ "$DRY_RUN" != "1" ]; then irec -f "$file_to_send"; fi
  sleep "$STEP_SLEEP"
  if [ "$cmd_to_send" = "bootx" ]; then
    log "CMD(BREQ): ${cmd_to_send}"
  else
    log "CMD: ${cmd_to_send}"
  fi
  if [ "$DRY_RUN" != "1" ]; then
    irec_cmd "$cmd_to_send" || warn "command returned non-zero/timeout: ${cmd_to_send}"
  fi
  sleep "$STEP_SLEEP"
}

log "query device"
Q_TEXT="$(query_device || true)"
if printf '%s\n' "$Q_TEXT" | grep -qi 'Unable to connect to device'; then
  die "cannot query device: irecovery cannot see DFU/Recovery device. Replug USB or put device back into DFU/Pwned DFU, then run this script again with no parameters."
fi
printf '%s\n' "$Q_TEXT" | grep -E 'MODE|CPID|BDID|ECID|PRODUCT|MODEL|SRNM|Serial|iBoot' || true
PRODUCT_VAL="$(get_field "$Q_TEXT" PRODUCT || true)"
if [ -z "$PRODUCT_VAL" ]; then PRODUCT_VAL="$(get_field "$Q_TEXT" ProductType || true)"; fi
HW_VAL="$(get_field "$Q_TEXT" MODEL || true)"
if [ -z "$HW_VAL" ]; then HW_VAL="$(get_field "$Q_TEXT" HardwareModel || true)"; fi
BDID_VAL="$(get_field "$Q_TEXT" BDID || true)"
IBOOT_VER_VAL="$(detect_iboot_version "$Q_TEXT" || true)"
DETECTED_IOS_VAL="$(map_iboot_to_ios "$IBOOT_VER_VAL" 2>/dev/null || true)"
ECID_VAL="$(get_field "$Q_TEXT" ECID || true)"
ECID_VAL="$(normalize_hex "$ECID_VAL")"
if [ -n "$ECID_VAL" ]; then
  { echo "ECID	$ECID_VAL"; echo "PRODUCT	$PRODUCT_VAL"; echo "MODEL	$HW_VAL"; echo "UPDATED	$(date +%Y%m%d_%H%M%S)"; } > "${ROOT}/.last_device.tsv" 2>/dev/null || true
fi

if [ -n "$FORCE_TARGET_VERSION" ] && [ -n "$ECID_VAL" ]; then
  cache_target_ios_set "$ECID_VAL" "$FORCE_TARGET_VERSION" "$FORCE_TARGET_BUILD"
fi

if [ -z "$FORCE_TARGET_VERSION" ] && [ -n "$ECID_VAL" ]; then
  cached_target="$(cache_target_ios_get "$ECID_VAL" || true)"
  if [ -n "$cached_target" ]; then
    FORCE_TARGET_VERSION="$(printf '%s' "$cached_target" | awk -F'\t' '{print $1}')"
    cached_build="$(printf '%s' "$cached_target" | awk -F'\t' '{print $2}')"
    if [ -z "$FORCE_TARGET_BUILD" ] && [ -n "$cached_build" ]; then FORCE_TARGET_BUILD="$cached_build"; fi
    log "target iOS cache : ECID=${ECID_VAL} -> ${FORCE_TARGET_VERSION}${FORCE_TARGET_BUILD:+ (${FORCE_TARGET_BUILD})}"
  fi
fi

MODEL_VAL="$FORCE_MODEL"
if [ -z "$MODEL_VAL" ]; then
  MODEL_VAL="$(map_product_to_model "$PRODUCT_VAL" "$HW_VAL" "$BDID_VAL" || true)"
fi
if [ -z "$MODEL_VAL" ]; then
  die "cannot determine bundle model from device query. Replug USB or return device to DFU/Recovery, then run this script again with no parameters. query was: ${Q_TEXT}"
fi

if [ "$TARGET_VERSION_EXPLICIT" = "1" ] && [ -n "$FORCE_TARGET_VERSION" ] && [ -z "$FORCE_VERSION" ]; then
  if version_le "$FORCE_TARGET_VERSION" "18.7.9"; then
    if [ -d "$(package_dir "$MODEL_VAL" "18.3")" ] && [ -d "$(universal_dir "18.3")" ]; then
      FORCE_VERSION="18.3"
      if [ -z "${UNIVERSAL_VERSION:-}" ]; then UNIVERSAL_VERSION="18.3"; fi
      log "auto boot package: target iOS ${FORCE_TARGET_VERSION} <= 18.7.9; use 18.3 device/universal ramdisk"
    else
      warn "target iOS ${FORCE_TARGET_VERSION} <= 18.7.9 but 18.3 package/universal missing; keep default package selection"
    fi
  fi
fi

VERSION_VAL="$(resolve_version "$MODEL_VAL" "$Q_TEXT" || true)"
if [ -z "$VERSION_VAL" ]; then
  die "cannot determine bundle version for model=${MODEL_VAL} from app/extracted data. Check extracted directory, then run again with no parameters."
fi

DEV_DIR="$(package_dir "$MODEL_VAL" "$VERSION_VAL")"
UNI_VERSION="${UNIVERSAL_VERSION:-$VERSION_VAL}"
UNI_DIR="$(universal_dir "$UNI_VERSION")"
IMG4_CACHE="${WORK_ROOT}/img4/${MODEL_VAL}_${VERSION_VAL}_universal_${UNI_VERSION}"
mkdir -p "$IMG4_CACHE"
[ -d "$DEV_DIR" ] || die "missing device package: ${DEV_DIR}"
if [ ! -d "$UNI_DIR" ]; then warn "missing universal package: ${UNI_DIR}"; fi
need_file "${DEV_DIR}/ibss.raw"
need_file "${DEV_DIR}/boot_order.json"

log "selected model   : ${MODEL_VAL}"
log "selected version : ${VERSION_VAL}"
if [ "$UNI_VERSION" != "$VERSION_VAL" ]; then log "universal version: ${UNI_VERSION} (override)"; fi
log "device package   : ${DEV_DIR}"
log "universal package: ${UNI_DIR}"
log "im4m             : ${IM4M}"
log "img4 cache       : ${IMG4_CACHE}"
log "boot-args        : ${BOOT_ARGS}"
if [ -n "$FORCE_TARGET_VERSION" ]; then
  log "target iOS for SEP: ${FORCE_TARGET_VERSION}${FORCE_TARGET_BUILD:+ (${FORCE_TARGET_BUILD})}"
else
  log "target iOS for SEP: auto (detected/cache; otherwise latest signed same-major IPSW)"
fi

if [ "$SKIP_IBSS" != "1" ]; then
  log "DFU stage: automatic pwn + send ibss.raw"
  if [ "$DRY_RUN" != "1" ]; then
    send_ibss_like_app "${DEV_DIR}/ibss.raw"
  fi
  log "wait ${SLEEP_AFTER_IBSS}s for Recovery/iBoot"
  sleep "$SLEEP_AFTER_IBSS"
else
  warn "SKIP_IBSS=1:  ibss.raw"
fi

log "wait for Recovery/iBoot"
if [ "$DRY_RUN" != "1" ]; then
  wait_recovery || die "irecovery cannot see Recovery/iBoot device"
fi

STEPS_FILE="${WORK_ROOT}/boot_steps_${MODEL_VAL}_${VERSION_VAL}_$$.tsv"
/usr/bin/python3 - "${DEV_DIR}/boot_order.json" > "$STEPS_FILE" <<'PY'
import json, sys
with open(sys.argv[1], 'r') as f:
    data = json.load(f)
for step in sorted(data.get('sequence', []), key=lambda x: int(x.get('send_order', 0))):
    action = step.get('action', '')
    order = str(step.get('send_order', '0'))
    if action == 'command':
        print('\t'.join([order, 'command', step.get('command', '')]))
    elif action == 'component':
        print('\t'.join([order, 'component', step.get('name', ''), step.get('filename', ''), step.get('irecv_command', '')]))
PY

log "send boot_order sequence"
while IFS=$'\t' read -r order_val action_val field_a field_b field_c; do
  if [ -z "${order_val:-}" ]; then continue; fi
  if [ "$action_val" = "command" ]; then
    if printf '%s' "$field_a" | grep -q '^setenv boot-args '; then
      send_cmd "setenv boot-args ${BOOT_ARGS}"
    else
      send_cmd "$field_a"
    fi
    continue
  fi
  name_val="$field_a"
  filename_val="$field_b"
  cmd_val="$field_c"
  src_path="$(resolve_component_file "$DEV_DIR" "$UNI_DIR" "$UNI_VERSION" "$name_val" "$filename_val")" || die "cannot resolve component order=${order_val} name=${name_val} filename=${filename_val}"
  if [ "$name_val" = "RestoreSEP" ] && [ "$DYNAMIC_SEP" = "1" ]; then
    bundle_major="$(printf '%s' "$VERSION_VAL" | awk -F. '{print $1}')"
    old_force_target_version="$FORCE_TARGET_VERSION"
    if [ -z "$FORCE_TARGET_VERSION" ] && [ -n "${DETECTED_IOS_VAL:-}" ]; then
      FORCE_TARGET_VERSION="$DETECTED_IOS_VAL"
    fi
    dyn_sep="$(resolve_dynamic_sep "$PRODUCT_VAL" "$bundle_major" 2>/tmp/ramdisk-hook-dynamic-sep.err || true)"
    FORCE_TARGET_VERSION="$old_force_target_version"
    if [ -n "$dyn_sep" ] && [ -f "$dyn_sep" ]; then
      if [ -s /tmp/ramdisk-hook-dynamic-sep.err ]; then
        while IFS= read -r sep_msg; do [ -n "$sep_msg" ] && log "$sep_msg"; done < /tmp/ramdisk-hook-dynamic-sep.err
      fi
      log "dynamic SEP: $(basename "$dyn_sep") replaces $(basename "$src_path")"
      src_path="$dyn_sep"
      cleanup_dynamic_sep_cache
    else
      sep_err="$(cat /tmp/ramdisk-hook-dynamic-sep.err 2>/dev/null || true)"
      cached_sep="$(find_cached_dynamic_sep "$PRODUCT_VAL" "$FORCE_TARGET_VERSION" "$FORCE_TARGET_BUILD" || true)"
      if [ -n "$cached_sep" ] && [ -f "$cached_sep" ]; then
        warn "dynamic SEP online failed; using last successful cached $(basename "$cached_sep"). ${sep_err}"
        log "dynamic SEP: $(basename "$cached_sep") replaces $(basename "$src_path")"
        src_path="$cached_sep"
      else
        expected_sep="$(expected_sep_basename "$PRODUCT_VAL" 2>/dev/null || true)"
        if [ -n "$expected_sep" ] && [ "$(basename "$src_path")" != "$expected_sep" ]; then
          die "dynamic SEP unavailable and fixed SEP is wrong for ${PRODUCT_VAL}: have $(basename "$src_path"), need ${expected_sep}. ${sep_err}"
        fi
        warn "dynamic SEP unavailable; fallback fixed SEP. ${sep_err}"
      fi
    fi
  fi
  log "[${order_val}] ${name_val}: json=${filename_val} actual=${src_path} command=${cmd_val}"
  send_path="$(wrap_img4 "$src_path" "$cmd_val" "$name_val" "$order_val")"
  send_file_then_cmd "$send_path" "$cmd_val"
  if [ "$cmd_val" = "bootx" ]; then
    log "bootx sent; ramdisk should now boot/re-enumerate. SSH/iproxy intentionally not started."
  fi
done < "$STEPS_FILE"
rm -f "$STEPS_FILE"

log "done: full ramdisk boot sequence sent. Now connect manually after USB re-enumeration."
