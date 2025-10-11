#!/usr/bin/env bash
# scripts/bootstrap_build.sh
# One-shot setup + build for a Pico project (macOS). Idempotent: skips work if already done.
set -euo pipefail

# ---------- Config (overridable via env/flags) ----------
PICO_SDK_PATH="${PICO_SDK_PATH:-$HOME/pico-sdk}"
PICO_EXTRAS_PATH="${PICO_EXTRAS_PATH:-$HOME/pico-extras}"
PICO_BOARD="${PICO_BOARD:-pico2}"          # RP2350 Pico 2 by default; use 'pico' for RP2040
BUILD_TYPE="${BUILD_TYPE:-Debug}"          # or Release
GENERATOR="${GENERATOR:-}"                 # auto (prefers Ninja)
# Fallback Arm toolchain (adjust version/URL if you like)
ARM_GNU_DIR="${ARM_GNU_DIR:-$HOME/arm-gnu-toolchain}"
ARM_GNU_URL="${ARM_GNU_URL:-https://developer.arm.com/-/media/Files/downloads/gnu/13.2.rel1/binrel/arm-gnu-toolchain-13.2.rel1-darwin-arm64-arm-none-eabi.tar.xz}"

# ---------- Flags ----------
usage() {
  cat <<EOF
Usage: $0 [options]
  -b, --board <pico|pico2|custom>    Set PICO_BOARD (default: ${PICO_BOARD})
  -t, --type <Debug|Release>         Set CMAKE_BUILD_TYPE (default: ${BUILD_TYPE})
  -g, --generator <Ninja|Unix Makefiles>  Force CMake generator (default: auto)
  -c, --clean                         Remove build/ before configuring
  -h, --help                          This help
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

# ---------- Paths ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"

echo "Repo:        $REPO_ROOT"
echo "SDK:         $PICO_SDK_PATH"
echo "Extras:      $PICO_EXTRAS_PATH"
echo "Board:       $PICO_BOARD"
echo "Build type:  $BUILD_TYPE"

# ---------- Helpers ----------
need_cmd() { command -v "$1" >/dev/null 2>&1; }
brew_install_if_missing() {
  local pkg="$1"
  if ! brew list --formula "$pkg" >/dev/null 2>&1; then
    echo "Installing Homebrew package: $pkg"
    brew install "$pkg"
  else
    echo "✔ $pkg already installed"
  fi
}

ensure_nosys_specs() {
  # Returns 0 when nosys.specs is resolvable by the current arm-none-eabi-gcc, else 1
  local spec_path
  spec_path="$(arm-none-eabi-gcc -print-file-name=nosys.specs || true)"
  [[ -f "$spec_path" ]] && { echo "✔ nosys.specs found by toolchain: $spec_path"; return 0; }

  echo "nosys.specs not found via GCC search path; scanning Homebrew install..."
  local gcc_prefix spec_src
  gcc_prefix="$(brew --prefix arm-none-eabi-gcc 2>/dev/null || true)"

  # Look in common keg paths
  spec_src="$(/usr/bin/find "$gcc_prefix" /opt/homebrew/Cellar/arm-none-eabi-gcc -type f -name nosys.specs 2>/dev/null | head -n1 || true)"

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

install_arm_gnu_toolchain() {
  echo "Installing official Arm GNU Toolchain to $ARM_GNU_DIR ..."
  mkdir -p "$ARM_GNU_DIR"
  # Download & extract (xz tarball)
  curl -L "$ARM_GNU_URL" | tar -xJ -C "$ARM_GNU_DIR" --strip-components=1
  export PATH="$ARM_GNU_DIR/bin:$PATH"
  echo "Prepended $ARM_GNU_DIR/bin to PATH"
}

# ---------- Prereqs ----------
if [[ "$OSTYPE" != darwin* ]]; then
  echo "NOTE: This script targets macOS. On Linux: sudo apt install cmake ninja-build gcc-arm-none-eabi"
fi

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
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi
echo "✔ Homebrew present"

brew_install_if_missing cmake
brew_install_if_missing ninja
brew_install_if_missing arm-none-eabi-gcc
brew_install_if_missing git

# Try to make Homebrew toolchain work; if not, fall back to Arm GNU
if ! need_cmd arm-none-eabi-gcc; then
  echo "ERROR: arm-none-eabi-gcc not on PATH after Homebrew install."
  exit 1
fi

if ! ensure_nosys_specs; then
  echo "Could not resolve nosys.specs in Homebrew toolchain."
  echo "Falling back to official Arm GNU Toolchain..."
  install_arm_gnu_toolchain
  # Try once more with Arm GNU toolchain
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
echo "CMake generator: $GENERATOR"

# ---------- .env ----------
ENV_FILE="$REPO_ROOT/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  cat > "$ENV_FILE" <<EOF
# Auto-generated by bootstrap_build.sh
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
elif [[ "$OSTYPE" == "darwin"* ]]; then J=$(sysctl -n hw.ncpu)
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
      break
    fi
  done
else
  echo "Build OK, but no UF2 found (check target name/outputs)."
fi

echo "Done."