
#!/usr/bin/env bash
# qbuild.sh — Build-only script for Raspberry Pi Pico / Pico 2
# No installs. No updates. No network. No sudo. It only configures & builds
# using whatever is already on disk.

set -euo pipefail
IFS=$' \t\n'

# ---------- Config (overridable via env/flags) ----------
PICO_SDK_PATH="${PICO_SDK_PATH:-$HOME/pico-sdk}"
PICO_EXTRAS_PATH="${PICO_EXTRAS_PATH:-$HOME/pico-extras}"
PICO_BOARD="${PICO_BOARD:-pico2}"          # RP2350 Pico 2 by default; use 'pico' for RP2040
BUILD_TYPE="${BUILD_TYPE:-Debug}"          # or Release
GENERATOR="${GENERATOR:-}"                 # auto (prefers Ninja)
TARGET="${TARGET:-}"                       # optional: a single CMake target to build

# ---------- Flags ----------
usage() {
  cat <<EOF
Usage: $0 [options]
  Build:
    -b, --board <pico|pico2|custom>          Set PICO_BOARD (default: ${PICO_BOARD})
    -t, --type <Debug|Release>               Set CMAKE_BUILD_TYPE (default: ${BUILD_TYPE})
    -g, --generator <Ninja|Unix Makefiles>   Force CMake generator (default: auto)
    -r, --repo <path>                       Force repository root (default: auto-detect)
    -T, --target <name>                      Build only the named CMake target
    -c, --clean                              Remove build/ before configuring
    -h, --help                               This help

Notes:
  • This script NEVER installs packages, downloads toolchains, or updates git repos.
  • It requires arm-none-eabi-gcc and pico-sdk to already exist and be reachable.
  • Auto-detects repo root: current dir if it has CMakeLists.txt, else parent of this script, else git top-level.
EOF
  exit 0
}
CLEAN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--board) PICO_BOARD="$2"; shift 2;;
    -t|--type) BUILD_TYPE="$2"; shift 2;;
    -g|--generator) GENERATOR="$2"; shift 2;;
    -r|--repo) REPO_ROOT="$2"; shift 2;;
    -T|--target) TARGET="$2"; shift 2;;
    -c|--clean) CLEAN=1; shift;;
    -h|--help) usage;;
    *) echo "Unknown option: $1"; usage;;
  esac
done

# ---------- OS/Arch (used only for core detection) ----------
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"   # 'darwin' or 'linux'
IS_MAC=0; [[ "$OS" == darwin* ]] && IS_MAC=1

# ---------- Sudo normalization (Linux) ----------
# If the script is run with sudo, default $HOME becomes /root which breaks defaults like $PICO_SDK_PATH.
# Prefer the invoking user's home for SDK/extras when PICO_* are still at their defaults.
if [[ "${EUID:-$(id -u)}" -eq 0 ]] && [[ -n "${SUDO_USER:-}" ]]; then
  SUDO_HOME="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$SUDO_USER")"
  if [[ "$PICO_SDK_PATH" == "/root/pico-sdk" ]]; then PICO_SDK_PATH="$SUDO_HOME/pico-sdk"; fi
  if [[ "$PICO_EXTRAS_PATH" == "/root/pico-extras" ]]; then PICO_EXTRAS_PATH="$SUDO_HOME/pico-extras"; fi
fi

# ---------- Helpers ----------
need_cmd() { command -v "$1" >/dev/null 2>&1; }

die() { echo "ERROR: $*" >&2; exit 1; }

# Prefer an existing official toolchain if it's already on disk; never download.
maybe_use_existing_toolchain() {
  local candidates=(
    "$HOME/arm-gnu-toolchain/bin"
    "/opt/arm-gnu-toolchain/bin"
    "/usr/local/arm-gnu-toolchain/bin"
  )
  if [[ -d "/Applications/ArmGNUToolchain" ]]; then
    local appbin
    appbin="$(/usr/bin/find /Applications/ArmGNUToolchain -maxdepth 2 -type d -path '*/arm-none-eabi/bin' 2>/dev/null | head -n1 || true)"
    [[ -d "$appbin" ]] && candidates+=("$appbin")
  fi
  for d in "${candidates[@]}"; do
    if [[ -x "$d/arm-none-eabi-gcc" ]]; then
      export PATH="$d:$PATH"
      return 0
    fi
  done
  return 0
}

ensure_nosys_specs() {
  # Return 0 if nosys.specs is resolvable by current arm-none-eabi-gcc, else try to link one locally, else 1
  local spec_path
  spec_path="$(arm-none-eabi-gcc -print-file-name=nosys.specs 2>/dev/null || true)"
  if [[ -f "$spec_path" ]]; then
    echo "✔ nosys.specs found by toolchain: $spec_path"
    return 0
  fi
  echo "nosys.specs not found via GCC search path; scanning local locations..."
  local spec_src=""
  # Homebrew layout (if present locally)
  if need_cmd brew; then
    local gcc_prefix
    gcc_prefix="$(brew --prefix arm-none-eabi-gcc 2>/dev/null || true)"
    [[ -n "$gcc_prefix" ]] && spec_src="$(/usr/bin/find $gcc_prefix /Applications/ArmGNUToolchain -type f -name nosys.specs 2>/dev/null | head -n1 || true)"
  fi
  [[ -z "$spec_src" ]] && spec_src="$(/usr/bin/find /usr /opt "$HOME/arm-gnu-toolchain" -type f -path "*arm-none-eabi*" -name nosys.specs 2>/dev/null | head -n1 || true)"

  if [[ -n "$spec_src" && -f "$spec_src" ]]; then
    local sysroot
    sysroot="$(arm-none-eabi-gcc -print-sysroot)"
    mkdir -p "$sysroot/lib"
    ln -sf "$spec_src" "$sysroot/lib/nosys.specs"
    echo "Linked nosys.specs: $spec_src -> $sysroot/lib/nosys.specs"
    local resolved
    resolved="$(arm-none-eabi-gcc -print-file-name=nosys.specs 2>/dev/null || true)"
    [[ -f "$resolved" ]] && { echo "✔ nosys.specs now resolves at: $resolved"; return 0; }
  fi
  return 1
}


# ---------- Paths ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Allow override via --repo or REPO_ROOT env; otherwise auto-detect the repo root
REPO_ROOT="${REPO_ROOT:-}"
if [[ -z "$REPO_ROOT" ]]; then
  if [[ -f "$PWD/CMakeLists.txt" ]]; then
    # Run from repo root
    REPO_ROOT="$PWD"
  elif [[ -f "$SCRIPT_DIR/../CMakeLists.txt" ]]; then
    # Script in scripts/ (or similar); repo is the parent
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  elif need_cmd git && git -C "$SCRIPT_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
    # Fallback: git top-level
    REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
  else
    # Last resort: parent of script
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  fi
fi

BUILD_DIR="$REPO_ROOT/build"

printf "Repo:        %s\n" "$REPO_ROOT"
printf "SDK:         %s\n" "$PICO_SDK_PATH"
printf "Extras:      %s\n" "$PICO_EXTRAS_PATH"
printf "Board:       %s\n" "$PICO_BOARD"
printf "Build type:  %s\n" "$BUILD_TYPE"

# ---------- Preflight (no installs/updates) ----------
maybe_use_existing_toolchain || true
need_cmd arm-none-eabi-gcc || die "arm-none-eabi-gcc not found on PATH. Install it yourself and re-run."
ensure_nosys_specs || die "nosys.specs is not resolvable by arm-none-eabi-gcc. Place/link an existing nosys.specs into $(arm-none-eabi-gcc -print-sysroot)/lib or adjust your toolchain path."
[[ -d "$PICO_SDK_PATH" ]] || die "PICO_SDK_PATH '$PICO_SDK_PATH' does not exist."
[[ -d "$PICO_EXTRAS_PATH" ]] || echo "Note: PICO_EXTRAS_PATH '$PICO_EXTRAS_PATH' not found; continuing without extras."

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
  die "Could not locate a Pico SDK toolchain file under $PICO_SDK_PATH.\nLooked for: cmake/preload/toolchains/pico_arm_cortex_m33_gcc.cmake, pico_arm_gcc.cmake, pico_arm_clang_arm.cmake, and cmake/pico_toolchain.cmake"
fi

cmake -S "$REPO_ROOT" -B "$BUILD_DIR" -G "$GENERATOR" \
  -DPICO_BOARD="$PICO_BOARD" \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DPICO_SDK_PATH="$PICO_SDK_PATH" \
  -DPICO_EXTRAS_PATH="$PICO_EXTRAS_PATH" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE"

# Parallelism
if command -v nproc >/dev/null 2>&1; then J=$(nproc)
elif (( IS_MAC )); then J=$(sysctl -n hw.ncpu)
else J=4; fi

# Build command
build_cmd=(cmake --build "$BUILD_DIR" -j"$J")
if [[ -n "$TARGET" ]]; then
  build_cmd+=(--target "$TARGET")
fi

echo "Building..."
"${build_cmd[@]}"

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
