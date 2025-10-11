#!/usr/bin/env bash
# setup.sh — One-shot setup + build for a Raspberry Pi Pico/Pico 2 project
# Works on macOS and Ubuntu. Idempotent: skips work if already done.
# It will:
#  - Install required toolchain & build tools (via Homebrew on macOS, apt on Ubuntu)
#  - Ensure nosys.specs is resolvable (or fall back to official Arm GNU Toolchain)
#  - Clone/update pico-sdk and pico-extras if missing
#  - Configure & build your project with CMake (Ninja preferred)
#  - Auto-copy the resulting .uf2 to BOOTSEL volume if mounted

set -euo pipefail

# ---------- Config (overridable via env/flags) ----------
PICO_SDK_PATH="${PICO_SDK_PATH:-$HOME/pico-sdk}"
PICO_EXTRAS_PATH="${PICO_EXTRAS_PATH:-$HOME/pico-extras}"
PICO_BOARD="${PICO_BOARD:-pico2}"          # RP2350 Pico 2 by default; use 'pico' for RP2040
BUILD_TYPE="${BUILD_TYPE:-Debug}"          # or Release
GENERATOR="${GENERATOR:-}"                 # auto (prefers Ninja)
# Where to install the official Arm GNU Toolchain if needed
ARM_GNU_DIR="${ARM_GNU_DIR:-$HOME/arm-gnu-toolchain}"
ARM_GNU_URL="${ARM_GNU_URL:-}"             # if empty, auto-choose per OS/arch
ARM_GNU_VERSION="${ARM_GNU_VERSION:-13.2.rel1}"

# ---------- Flags ----------
usage() {
  cat <<EOF
Usage: $0 [options]
  -b, --board <pico|pico2|custom>        Set PICO_BOARD (default: ${PICO_BOARD})
  -t, --type <Debug|Release>             Set CMAKE_BUILD_TYPE (default: ${BUILD_TYPE})
  -g, --generator <Ninja|Unix Makefiles> Force CMake generator (default: auto)
  -c, --clean                            Remove build/ before configuring
  -h, --help                             This help
EOF
  exit 0
}
CLEAN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--board) PICO_BOARD="$2"; shift 2;;
    -t|--type) BUILD_TYPE="$2"; shift 2;;
    -g|--generator) GENERATOR="$2"; shift 2;;
    -c|--clean) CLEAN=1; shift;;
    -h|--help) usage;;
    *) echo "Unknown option: $1"; usage;;
  esac
done

# ---------- OS/Arch ----------
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"   # 'darwin' or 'linux'
ARCH="$(uname -m)"                               # 'arm64', 'x86_64', 'aarch64', etc.
IS_MAC=0; [[ "$OS" == darwin* ]] && IS_MAC=1
IS_LINUX=0; [[ "$OS" == linux*  ]] && IS_LINUX=1

# ---------- Paths ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"

printf "Repo:        %s\n" "$REPO_ROOT"
printf "SDK:         %s\n" "$PICO_SDK_PATH"
printf "Extras:      %s\n" "$PICO_EXTRAS_PATH"
printf "Board:       %s\n" "$PICO_BOARD"
printf "Build type:  %s\n" "$BUILD_TYPE"

# ---------- Helpers ----------
need_cmd() { command -v "$1" >/dev/null 2>&1; }

sudo_wrap() {
  # Run with sudo if not root
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then sudo "$@"; else "$@"; fi
}

brew_install_if_missing() {
  local pkg="$1"
  if ! brew list --formula "$pkg" >/dev/null 2>&1; then
    echo "Installing Homebrew package: $pkg"
    brew install "$pkg"
  else
    echo "✔ $pkg already installed"
  fi
}

apt_install_if_missing() {
  # Usage: apt_install_if_missing pkg1 [pkg2 ...]
  sudo_wrap apt-get update -y
  local to_install=()
  for pkg in "$@"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      echo "✔ $pkg already installed"
    else
      to_install+=("$pkg")
    fi
  done
  if (( ${#to_install[@]} )); then
    echo "Installing apt packages: ${to_install[*]}"
    sudo_wrap apt-get install -y "${to_install[@]}"
  fi
}

ensure_nosys_specs() {
  # Return 0 if nosys.specs is resolvable by current arm-none-eabi-gcc, else try to link one, else 1
  local spec_path
  spec_path="$(arm-none-eabi-gcc -print-file-name=nosys.specs 2>/dev/null || true)"
  if [[ -f "$spec_path" ]]; then
    echo "✔ nosys.specs found by toolchain: $spec_path"
    return 0
  fi

  echo "nosys.specs not found via GCC search path; scanning common locations..."
  local spec_src=""
  if need_cmd brew; then
    # Homebrew (macOS) search
    local gcc_prefix
    gcc_prefix="$(brew --prefix arm-none-eabi-gcc 2>/dev/null || true)"
    spec_src="$(/usr/bin/find "$gcc_prefix" /opt/homebrew/Cellar/arm-none-eabi-gcc -type f -name nosys.specs 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$spec_src" ]]; then
    # Ubuntu search
    spec_src="$(/usr/bin/find /usr /opt -type f -path "*arm-none-eabi*" -name nosys.specs 2>/dev/null | head -n1 || true)"
  fi

  if [[ -n "$spec_src" && -f "$spec_src" ]]; then
    local sysroot
    sysroot="$(arm-none-eabi-gcc -print-sysroot)"
    mkdir -p "$sysroot/lib"
    ln -sf "$spec_src" "$sysroot/lib/nosys.specs"
    echo "Linked nosys.specs: $spec_src -> $sysroot/lib/nosys.specs"
    return 0
  fi

  return 1
}

choose_arm_gnu_url() {
  # Choose a default tarball URL for the official Arm GNU Toolchain if ARM_GNU_URL is empty
  # Version is ${ARM_GNU_VERSION}. You can override by exporting ARM_GNU_URL yourself.
  local base="https://developer.arm.com/-/media/Files/downloads/gnu/${ARM_GNU_VERSION}/binrel"
  case "${OS}-${ARCH}" in
    darwin-arm64)  echo "${base}/arm-gnu-toolchain-${ARM_GNU_VERSION}-darwin-arm64-arm-none-eabi.tar.xz" ;;
    darwin-x86_64) echo "${base}/arm-gnu-toolchain-${ARM_GNU_VERSION}-darwin-x86_64-arm-none-eabi.tar.xz" ;;
    linux-x86_64)  echo "${base}/arm-gnu-toolchain-${ARM_GNU_VERSION}-x86_64-arm-none-eabi.tar.xz" ;;
    linux-aarch64) echo "${base}/arm-gnu-toolchain-${ARM_GNU_VERSION}-aarch64-arm-none-eabi.tar.xz" ;;
    *)             echo "${base}/arm-gnu-toolchain-${ARM_GNU_VERSION}-x86_64-arm-none-eabi.tar.xz" ;;
  esac
}

install_arm_gnu_toolchain() {
  [[ -n "$ARM_GNU_URL" ]] || ARM_GNU_URL="$(choose_arm_gnu_url)"
  echo "Installing official Arm GNU Toolchain to $ARM_GNU_DIR ..."
  mkdir -p "$ARM_GNU_DIR"
  # Download & extract (xz tarball). If curl is missing, install it.
  if ! need_cmd curl; then
    if (( IS_LINUX )); then apt_install_if_missing curl xz-utils; fi
    if (( IS_MAC )); then brew_install_if_missing curl; fi
  fi
  if ! need_cmd tar; then
    if (( IS_LINUX )); then apt_install_if_missing tar xz-utils; fi
    if (( IS_MAC )); then echo "tar is required"; exit 1; fi
  fi
  curl -L "$ARM_GNU_URL" | tar -xJ -C "$ARM_GNU_DIR" --strip-components=1
  export PATH="$ARM_GNU_DIR/bin:$PATH"
  echo "Prepended $ARM_GNU_DIR/bin to PATH"
}

# ---------- Prereqs ----------
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

  brew_install_if_missing cmake
  brew_install_if_missing ninja
  brew_install_if_missing arm-none-eabi-gcc
  brew_install_if_missing git

elif (( IS_LINUX )); then
  if need_cmd apt-get; then
    echo "✔ Detected Ubuntu/Debian (apt)"
    apt_install_if_missing software-properties-common
    apt_install_if_missing cmake ninja-build git curl xz-utils
    # Try distro toolchain first; libnewlib provides specs on many distros.
    apt_install_if_missing gcc-arm-none-eabi libnewlib-arm-none-eabi || true
  else
    echo "This script currently supports Ubuntu/Debian (apt) and macOS."
    echo "On other distros, install: cmake ninja-build git curl xz, and a working arm-none-eabi toolchain."
  fi
else
  echo "Unsupported OS: $(uname -s). This script supports macOS and Ubuntu/Debian."
  exit 1
fi

# Verify toolchain presence
if ! need_cmd arm-none-eabi-gcc; then
  echo "ERROR: arm-none-eabi-gcc not on PATH after package installation."
  echo "Falling back to official Arm GNU Toolchain..."
  install_arm_gnu_toolchain
fi

# Ensure nosys.specs is available; otherwise fall back to official toolchain
if ! ensure_nosys_specs; then
  echo "Could not resolve nosys.specs in system toolchain."
  echo "Falling back to official Arm GNU Toolchain..."
  install_arm_gnu_toolchain
  if ! ensure_nosys_specs; then
    echo "ERROR: nosys.specs still not found. Try removing and reinstalling your toolchains."
    exit 1
  fi
fi

# ---------- SDKs ----------
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

# ---------- Generator ----------
if [[ -z "${GENERATOR}" ]]; then
  if need_cmd ninja; then GENERATOR="Ninja"; else GENERATOR="Unix Makefiles"; fi
fi
printf "CMake generator: %s\n" "$GENERATOR"

# ---------- .env ----------
ENV_FILE="$REPO_ROOT/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  cat > "$ENV_FILE" <<EOF
# Auto-generated by setup.sh
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

echo "Configuring CMake..."
cmake -S "$REPO_ROOT" -B "$BUILD_DIR" -G "$GENERATOR" \
  -DPICO_BOARD="$PICO_BOARD" \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE"

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
  # Common mount points (macOS & Ubuntu)
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
