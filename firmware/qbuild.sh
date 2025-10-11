

#!/usr/bin/env bash
# qbuild.sh — Setup + (optionally) FAST/OFFLINE build for Raspberry Pi Pico / Pico 2
# Works on macOS and Ubuntu. Idempotent by default. Adds a "fast/offline" mode
# that **never** hits the network, **never** uses sudo, and only builds with
# whatever is already on disk.
#
# Modes
# -----
# Default (no flags):
#   - Behaves like the original script: installs prerequisites if missing,
#     can download the Arm GNU Toolchain, and clones/updates pico-sdk/extras.
# FAST / OFFLINE:
#   - Skip ALL dependency installation and git/network operations.
#   - Do not use sudo (even if available).
#   - Require that arm-none-eabi toolchain and pico-sdk/extras already exist
#     locally and are reachable; otherwise fail fast with guidance.
#
# Examples
#   ./qbuild.sh --fast                         # zero-network, no-sudo, build-only
#   ./qbuild.sh --offline -b pico2 -t Release  # same as --fast, explicitly offline
#   ./qbuild.sh --no-sudo                      # normal mode but never sudo
#
set -euo pipefail
IFS=$' \t\n'

# ---------- Config (overridable via env/flags) ----------
PICO_SDK_PATH="${PICO_SDK_PATH:-$HOME/pico-sdk}"
PICO_EXTRAS_PATH="${PICO_EXTRAS_PATH:-$HOME/pico-extras}"
PICO_BOARD="${PICO_BOARD:-pico2}"          # RP2350 Pico 2 by default; use 'pico' for RP2040
BUILD_TYPE="${BUILD_TYPE:-Debug}"          # or Release
GENERATOR="${GENERATOR:-}"                 # auto (prefers Ninja)

# Where to install the official Arm GNU Toolchain if needed (normal mode only)
ARM_GNU_DIR="${ARM_GNU_DIR:-$HOME/arm-gnu-toolchain}"
ARM_GNU_URL="${ARM_GNU_URL:-}"
ARM_GNU_VERSION="${ARM_GNU_VERSION:-13.2.rel1}"

# Fast/Offline knobs (can also be set via env FAST=1 / OFFLINE=1 / NOSUDO=1)
FAST="${FAST:-0}"        # if 1, skip installs & any network; no sudo
OFFLINE="${OFFLINE:-0}"  # if 1, implies FAST
NOSUDO="${NOSUDO:-0}"    # if 1, never invoke sudo

# ---------- Flags ----------
usage() {
  cat <<EOF
Usage: $0 [options]
  Mode:
    -F, --fast                               Skip installs/updates and build with local deps only
    -O, --offline                            Same as --fast; guarantees no network use
    --no-sudo                                Never use sudo (even in normal mode)

  Build:
    -b, --board <pico|pico2|custom>          Set PICO_BOARD (default: ${PICO_BOARD})
    -t, --type <Debug|Release>               Set CMAKE_BUILD_TYPE (default: ${BUILD_TYPE})
    -g, --generator <Ninja|Unix Makefiles>   Force CMake generator (default: auto)
    -c, --clean                              Remove build/ before configuring
    -h, --help                               This help

Environment overrides:
  FAST=1 OFFLINE=1 NOSUDO=1 PICO_SDK_PATH=... PICO_EXTRAS_PATH=... ARM_GNU_DIR=...
EOF
  exit 0
}
CLEAN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -F|--fast) FAST=1; shift;;
    -O|--offline) OFFLINE=1; FAST=1; shift;;
    --no-sudo) NOSUDO=1; shift;;
    -b|--board) PICO_BOARD="$2"; shift 2;;
    -t|--type) BUILD_TYPE="$2"; shift 2;;
    -g|--generator) GENERATOR="$2"; shift 2;;
    -c|--clean) CLEAN=1; shift;;
    -h|--help) usage;;
    *) echo "Unknown option: $1"; usage;;
  esac
done

# OFFLINE implies FAST
if [[ "$OFFLINE" == "1" ]]; then FAST=1; fi
# FAST implies NOSUDO
if [[ "$FAST" == "1" ]]; then NOSUDO=1; fi

# ---------- OS/Arch ----------
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"   # 'darwin' or 'linux'
ARCH="$(uname -m)"                               # 'arm64', 'x86_64', 'aarch64', etc.
IS_MAC=0; [[ "$OS" == darwin* ]] && IS_MAC=1
IS_LINUX=0; [[ "$OS" == linux*  ]] && IS_LINUX=1

# ---------- Sudo normalization (Linux) ----------
# If the script is run with sudo, default $HOME becomes /root which breaks defaults like $PICO_SDK_PATH.
# Prefer the invoking user's home for SDK/extras when PICO_* are still at their defaults.
if (( IS_LINUX )) && [[ "${EUID:-$(id -u)}" -eq 0 ]] && [[ -n "${SUDO_USER:-}" ]]; then
  SUDO_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6 2>/dev/null || echo "/home/$SUDO_USER")"
  if [[ "$PICO_SDK_PATH" == "/root/pico-sdk" ]]; then PICO_SDK_PATH="$SUDO_HOME/pico-sdk"; fi
  if [[ "$PICO_EXTRAS_PATH" == "/root/pico-extras" ]]; then PICO_EXTRAS_PATH="$SUDO_HOME/pico-extras"; fi
fi

# ---------- Helpers ----------
need_cmd() { command -v "$1" >/dev/null 2>&1; }

die() { echo "ERROR: $*" >&2; exit 1; }

sudo_wrap() {
  if [[ "$NOSUDO" == "1" ]]; then
    # run without sudo; useful in FAST/OFFLINE
    "$@"
  else
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then sudo "$@"; else "$@"; fi
  fi
}

xz_supports_threads() {
  if ! need_cmd xz; then return 1; fi
  xz --help 2>&1 | grep -q "\-T" || return 1
  return 0
}

choose_arm_gnu_url() {
  local base="https://developer.arm.com/-/media/Files/downloads/gnu/${ARM_GNU_VERSION}/binrel"
  case "${OS}-${ARCH}" in
    darwin-arm64)  echo "${base}/arm-gnu-toolchain-${ARM_GNU_VERSION}-darwin-arm64-arm-none-eabi.tar.xz" ;;
    darwin-x86_64) echo "${base}/arm-gnu-toolchain-${ARM_GNU_VERSION}-darwin-x86_64-arm-none-eabi.tar.xz" ;;
    linux-x86_64)  echo "${base}/arm-gnu-toolchain-${ARM_GNU_VERSION}-x86_64-arm-none-eabi.tar.xz" ;;
    linux-aarch64|linux-arm64) echo "${base}/arm-gnu-toolchain-${ARM_GNU_VERSION}-aarch64-arm-none-eabi.tar.xz" ;;
    *)             echo "${base}/arm-gnu-toolchain-${ARM_GNU_VERSION}-x86_64-arm-none-eabi.tar.xz" ;;
  esac
}

# ---------- Default toolchain URL per-OS (only if not provided by env) ----------
if (( IS_MAC )) && [[ -z "$ARM_GNU_URL" ]]; then
  ARM_GNU_URL="https://developer.arm.com/-/media/Files/downloads/gnu/13.2.rel1/binrel/arm-gnu-toolchain-13.2.rel1-darwin-arm64-arm-none-eabi.tar.xz"
fi
if (( IS_LINUX )) && [[ -z "$ARM_GNU_URL" ]]; then
  ARM_GNU_URL="$(choose_arm_gnu_url)"
fi

# ---------- Paths ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"

printf "Repo:        %s\n" "$REPO_ROOT"
printf "SDK:         %s\n" "$PICO_SDK_PATH"
printf "Extras:      %s\n" "$PICO_EXTRAS_PATH"
printf "Board:       %s\n" "$PICO_BOARD"
printf "Build type:  %s\n" "$BUILD_TYPE"
printf "Mode:        %s\n" "$([[ "$FAST" == "1" ]] && echo FAST${OFFLINE:++OFFLINE} || echo 'normal')"
[[ "$NOSUDO" == "1" ]] && echo "Sudo:       disabled" || echo "Sudo:       allowed"

# ---------- Toolchain + SDK checks ----------
maybe_use_existing_toolchain() {
  local candidates=(
    "$ARM_GNU_DIR/bin"
    "$HOME/arm-gnu-toolchain/bin"
    "/opt/arm-gnu-toolchain/bin"
    "/usr/local/arm-gnu-toolchain/bin"
  )
  if [[ -d "/Applications/ArmGNUToolchain" ]]; then
    local appbin
    appbin="$(/usr/bin/find /Applications/ArmGNUToolchain -maxdepth 2 -type d -path '*/arm-none-eabi/bin' 2>/dev/null | head -n1 || true)"
    if [[ -d "$appbin" ]]; then
      candidates+=("$appbin")
    fi
  fi
  for d in "${candidates[@]}"; do
    if [[ -x "$d/arm-none-eabi-gcc" ]]; then
      export PATH="$d:$PATH"
      local nsp
      nsp="$(arm-none-eabi-gcc -print-file-name=nosys.specs 2>/dev/null || true)"
      if [[ -f "$nsp" ]]; then
        echo "Using existing Arm GNU Toolchain at $(dirname "$d")"
        return 0
      fi
    fi
  done
  return 1
}

ensure_nosys_specs() {
  # Return 0 if nosys.specs is resolvable by current arm-none-eabi-gcc, else try to link one, else 1
  local spec_path
  spec_path="$(arm-none-eabi-gcc -print-file-name=nosys.specs 2>/dev/null || true)"
  if [[ -f "$spec_path" ]]; then
    echo "✔ nosys.specs found by toolchain: $spec_path"
    return 0
  fi

  # In FAST/OFFLINE, don't try to fetch anything—only local discovery & link
  echo "nosys.specs not found via GCC search path; scanning local locations..."
  local spec_src=""
  # Homebrew (macOS) search (local only)
  if need_cmd brew; then
    local gcc_prefix
    gcc_prefix="$(brew --prefix arm-none-eabi-gcc 2>/dev/null || true)"
    if [[ -n "$gcc_prefix" ]]; then
      spec_src="$(/usr/bin/find $gcc_prefix /Applications/ArmGNUToolchain -type f -name nosys.specs 2>/dev/null | head -n1 || true)"
    fi
  fi
  if [[ -z "$spec_src" ]]; then
    spec_src="$(/usr/bin/find /usr /opt "$ARM_GNU_DIR" "$HOME/arm-gnu-toolchain" -type f -path "*arm-none-eabi*" -name nosys.specs 2>/dev/null | head -n1 || true)"
  fi

  if [[ -n "$spec_src" && -f "$spec_src" ]]; then
    local sysroot
    sysroot="$(arm-none-eabi-gcc -print-sysroot)"
    mkdir -p "$sysroot/lib"
    ln -sf "$spec_src" "$sysroot/lib/nosys.specs"
    echo "Linked nosys.specs: $spec_src -> $sysroot/lib/nosys.specs"
    local resolved
    resolved="$(arm-none-eabi-gcc -print-file-name=nosys.specs 2>/dev/null || true)"
    if [[ -f "$resolved" ]]; then
      echo "✔ nosys.specs now resolves at: $resolved"
      return 0
    fi
  fi
  return 1
}

install_arm_gnu_toolchain() {
  [[ "$FAST" == "1" ]] && die "install_arm_gnu_toolchain called in FAST/OFFLINE mode"
  [[ -n "$ARM_GNU_URL" ]] || ARM_GNU_URL="$(choose_arm_gnu_url)"
  echo "Toolchain URL: $ARM_GNU_URL"
  if [[ -x "$ARM_GNU_DIR/bin/arm-none-eabi-gcc" ]]; then
    export PATH="$ARM_GNU_DIR/bin:$PATH"
    local nsp
    nsp="$(arm-none-eabi-gcc -print-file-name=nosys.specs 2>/dev/null || true)"
    if [[ -f "$nsp" ]] || [[ -f "$ARM_GNU_DIR/arm-none-eabi/lib/nosys.specs" ]] || [[ -f "$ARM_GNU_DIR/lib/nosys.specs" ]]; then
      echo "Using existing official Arm GNU Toolchain at $ARM_GNU_DIR"
      return 0
    fi
  fi
  echo "Installing official Arm GNU Toolchain to $ARM_GNU_DIR ..."
  mkdir -p "$ARM_GNU_DIR"
  local cache_dir tar_name tar_path
  cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/arm-gnu-toolchain"
  mkdir -p "$cache_dir"
  tar_name="$(basename "$ARM_GNU_URL")"
  [[ -n "$tar_name" ]] || tar_name="arm-gnu-toolchain.tar.xz"
  tar_path="$cache_dir/$tar_name"
  if need_cmd aria2c; then
    echo "Downloading with aria2c (multi-connection) to $tar_path"
    aria2c -x16 -s16 -o "$tar_name" -d "$cache_dir" "$ARM_GNU_URL"
  else
    if ! need_cmd curl; then
      if (( IS_LINUX )); then sudo_wrap apt-get update -y && sudo_wrap apt-get install -y curl xz-utils; fi
      if (( IS_MAC )); then echo "curl is required"; exit 1; fi
    fi
    echo "Downloading with curl (resumable) to $tar_path"
    curl -fL --retry 5 --retry-all-errors -C - -o "$tar_path" "$ARM_GNU_URL"
  fi
  if xz_supports_threads; then
    echo "Extracting with multi-threaded xz..."
    tar -x -C "$ARM_GNU_DIR" --strip-components=1 --use-compress-program="xz -T0" -f "$tar_path"
  else
    echo "Extracting (single-threaded xz)..."
    if ! need_cmd tar; then
      if (( IS_LINUX )); then sudo_wrap apt-get install -y tar xz-utils; fi
      if (( IS_MAC )); then echo "tar is required"; exit 1; fi
    fi
    tar -xJ -C "$ARM_GNU_DIR" --strip-components=1 -f "$tar_path"
  fi
  export PATH="$ARM_GNU_DIR/bin:$PATH"
  echo "Prepended $ARM_GNU_DIR/bin to PATH"
}

# ---------- Prereqs (skipped in FAST/OFFLINE) ----------
if [[ "$FAST" != "1" ]]; then
  if (( IS_MAC )); then
    if ! xcode-select -p >/dev/null 2>&1; then
      echo "Installing Xcode Command Line Tools..."
      xcode-select --install || true
      echo "Finish the CLT installer, then re-run this script."
      exit 1
    fi
    echo "✔ Xcode Command Line Tools present"

    if ! need_cmd brew; then
      echo "Homebrew not found. Installing..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      # shellcheck disable=SC1090
      eval "$(/opt/homebrew/bin/brew shellenv || true)"
    fi
    echo "✔ Homebrew present"
    brew list --formula cmake >/dev/null 2>&1 || brew install cmake
    brew list --formula ninja >/dev/null 2>&1 || brew install ninja
    brew list --formula git >/dev/null 2>&1 || brew install git

  elif (( IS_LINUX )); then
    if need_cmd apt-get; then
      echo "✔ Detected Ubuntu/Debian (apt)"
      sudo_wrap apt-get update -y
      sudo_wrap apt-get install -y software-properties-common cmake ninja-build git curl xz-utils build-essential pkg-config
      sudo_wrap apt-get install -y gcc-arm-none-eabi libnewlib-arm-none-eabi || true
    else
      echo "This script currently supports Ubuntu/Debian (apt) and macOS."
      echo "On other distros, install: cmake ninja-build git curl xz, and a working arm-none-eabi toolchain."
    fi
  else
    echo "Unsupported OS: $(uname -s). This script supports macOS and Ubuntu/Debian."
    exit 1
  fi

  # Verify toolchain presence (prefer existing; else download)
  if ! need_cmd arm-none-eabi-gcc; then
    echo "arm-none-eabi-gcc not on PATH; checking common install locations..."
    if maybe_use_existing_toolchain && need_cmd arm-none-eabi-gcc; then
      echo "✔ Found existing Arm GNU Toolchain"
    else
      echo "Falling back to official Arm GNU Toolchain (direct download)..."
      install_arm_gnu_toolchain
    fi
  fi

  # Ensure nosys.specs is available
  if ! ensure_nosys_specs; then
    echo "Could not resolve nosys.specs; checking existing toolchains..."
    if maybe_use_existing_toolchain && ensure_nosys_specs; then
      echo "✔ nosys.specs found via existing toolchain"
    else
      echo "Falling back to official Arm GNU Toolchain (direct download)..."
      install_arm_gnu_toolchain
      if ! ensure_nosys_specs; then
        die "nosys.specs still not found. Try removing/reinstalling your toolchains."
      fi
    fi
  fi

  # ---------- SDKs (clone/update) ----------
  if [[ ! -d "$PICO_SDK_PATH" ]]; then
    echo "Cloning pico-sdk to $PICO_SDK_PATH ..."
    git clone --recursive https://github.com/raspberrypi/pico-sdk "$PICO_SDK_PATH"
  else
    echo "✔ pico-sdk exists; updating submodules"
    git -C "$PICO_SDK_PATH" submodule update --init --recursive
  fi

  if [[ ! -d "$PICO_EXTRAS_PATH" ]]; then
    echo "Cloning pico-extras to $PICO_EXTRAS_PATH ..."
    git clone --recursive https://github.com/raspberrypi/pico-extras "$PICO_EXTRAS_PATH"
  else
    echo "✔ pico-extras exists; updating submodules"
    git -C "$PICO_EXTRAS_PATH" submodule update --init --recursive
  fi
else
  # ---------- FAST/OFFLINE preflight ----------
  echo "FAST/OFFLINE: Skipping package installs, toolchain downloads, and git operations."
  need_cmd arm-none-eabi-gcc || die "arm-none-eabi-gcc not found on PATH in FAST/OFFLINE mode.
Please install the Arm GNU Toolchain locally and export PATH to include its 'bin'."
  ensure_nosys_specs || die "nosys.specs is not resolvable by arm-none-eabi-gcc in FAST/OFFLINE mode.
Please place/link an existing nosys.specs into $(arm-none-eabi-gcc -print-sysroot)/lib, or adjust your toolchain path."
  [[ -d "$PICO_SDK_PATH" ]] || die "PICO_SDK_PATH '$PICO_SDK_PATH' does not exist in FAST/OFFLINE mode."
  [[ -d "$PICO_EXTRAS_PATH" ]] || echo "Note: PICO_EXTRAS_PATH '$PICO_EXTRAS_PATH' not found; continuing without extras."
fi

# ---------- Generator ----------
if [[ -z "${GENERATOR}" ]]; then
  if need_cmd ninja; then GENERATOR="Ninja"; else GENERATOR="Unix Makefiles"; fi
fi
printf "CMake generator: %s\n" "$GENERATOR"

# ---------- .env ----------
ENV_FILE="$REPO_ROOT/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  cat > "$ENV_FILE" <<EOF
# Auto-generated by qbuild.sh
export PICO_SDK_PATH="$PICO_SDK_PATH"
export PICO_EXTRAS_PATH="$PICO_EXTRAS_PATH"
export PICO_BOARD="$PICO_BOARD"
EOF
  echo "Wrote $ENV_FILE"
else
  echo "✔ $ENV_FILE already exists"
fi

# ---------- Configure & Build ----------
export PICO_SDK_PATH PICO_EXTRAS_PATH PICO_BOARD

if (( CLEAN )); then
  echo "Cleaning $BUILD_DIR ..."
  rm -rf "$BUILD_DIR"
fi

# If a previous cache has a different PICO_SDK_PATH, clear it and the picotool sub-build cache
if [[ -f "$BUILD_DIR/CMakeCache.txt" ]] && ! grep -q "PICO_SDK_PATH:.*$PICO_SDK_PATH" "$BUILD_DIR/CMakeCache.txt"; then
  echo "PICO_SDK_PATH changed; clearing top-level CMake cache"
  rm -f "$BUILD_DIR/CMakeCache.txt"
fi
if [[ -f "$BUILD_DIR/_deps/picotool-build/CMakeCache.txt" ]] && ! grep -q "$PICO_SDK_PATH" "$BUILD_DIR/_deps/picotool-build/CMakeCache.txt"; then
  echo "Stale picotool cache detected; removing _deps/picotool-build to force reconfigure"
  rm -rf "$BUILD_DIR/_deps/picotool-build"
fi

# If previous cache forced host compilers, wipe it so the Pico toolchain can select arm-none-eabi-gcc
if [[ -f "$BUILD_DIR/CMakeCache.txt" ]]; then
  if grep -q '^CMAKE_C_COMPILER:FILEPATH=' "$BUILD_DIR/CMakeCache.txt" || \
     grep -q '^CMAKE_CXX_COMPILER:FILEPATH=' "$BUILD_DIR/CMakeCache.txt"; then
    echo "Removing stale CMAKE_*_COMPILER from cache"
    rm -f "$BUILD_DIR/CMakeCache.txt"
  fi
fi

echo "Configuring CMake..."
find_pico_toolchain_file() {
  local candidates=()
  if [[ "$PICO_BOARD" == pico2* || "$PICO_BOARD" == *rp2350* || "$PICO_BOARD" == *m33* ]]; then
    candidates+=("$PICO_SDK_PATH/cmake/preload/toolchains/pico_arm_cortex_m33_gcc.cmake")
  fi
  candidates+=(
    "$PICO_SDK_PATH/cmake/preload/toolchains/pico_arm_gcc.cmake"
    "$PICO_SDK_PATH/cmake/preload/toolchains/pico_arm_clang_arm.cmake"
    "$PICO_SDK_PATH/cmake/pico_toolchain.cmake"
  )
  local f
  for f in "${candidates[@]}"; do
    if [[ -f "$f" ]]; then
      echo "$f"
      return 0
    fi
  done
  return 1
}
TOOLCHAIN_FILE="$(find_pico_toolchain_file || true)"
if [[ -z "$TOOLCHAIN_FILE" ]]; then
  die "Could not locate a Pico SDK toolchain file under $PICO_SDK_PATH.
Looked for: cmake/preload/toolchains/pico_arm_cortex_m33_gcc.cmake, pico_arm_gcc.cmake, pico_arm_clang_arm.cmake, and cmake/pico_toolchain.cmake"
fi

cmake -S "$REPO_ROOT" -B "$BUILD_DIR" -G "$GENERATOR" \
  -DPICO_BOARD="$PICO_BOARD" \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DPICO_SDK_PATH="$PICO_SDK_PATH" \
  -DPICO_EXTRAS_PATH="$PICO_EXTRAS_PATH" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE"

# Parallelism
if need_cmd nproc; then J=$(nproc)
elif (( IS_MAC )); then J=$(sysctl -n hw.ncpu)
else J=4; fi

echo "Building..."
cmake --build "$BUILD_DIR" -j"$J"

# ---------- Auto-flash if BOOTSEL mounted ----------
UF2="$(ls -t "$BUILD_DIR"/*.uf2 2>/dev/null | head -n 1 || true)"
if [[ -n "$UF2" ]]; then
  echo "UF2 built: $UF2"
  for MOUNT in "/Volumes/RPI-RP2" "/media/$USER/RPI-RP2"; do
    if [[ -d "$MOUNT" ]]; then
      echo "Copying to $MOUNT ..."
      cp "$UF2" "$MOUNT"/
      echo "Flashed to $MOUNT"
      COPIED=1
      break
    fi
  done
  : "${COPIED:=0}"
  if [[ "$COPIED" -eq 0 ]]; then
    echo "Built: $UF2 (put board in BOOTSEL to flash, then copy manually)"
  fi
else
  echo "Build OK, but no UF2 found (check target name/outputs)."
fi

echo "Done."
