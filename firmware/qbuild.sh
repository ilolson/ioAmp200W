#!/usr/bin/env bash

set -e

# Cross‑platform detection
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
IS_LINUX=0; [[ "$OS" == linux*  ]] && IS_LINUX=1
IS_MAC=0;   [[ "$OS" == darwin* ]] && IS_MAC=1

# Helper: locate the best Pico SDK toolchain file
find_pico_toolchain_file() {
  local candidates=()
  # Prefer Cortex‑M33 GCC toolchain for Pico 2 / RP2350
  if [[ "${PICO_BOARD:-pico2}" == pico2* || "${PICO_BOARD:-pico2}" == *rp2350* || "${PICO_BOARD:-pico2}" == *m33* ]]; then
    candidates+=("$PICO_SDK_PATH/cmake/preload/toolchains/pico_arm_cortex_m33_gcc.cmake")
  fi
  candidates+=(
    "$PICO_SDK_PATH/cmake/preload/toolchains/pico_arm_gcc.cmake"
    "$PICO_SDK_PATH/cmake/preload/toolchains/pico_arm_clang_arm.cmake"
    "$PICO_SDK_PATH/cmake/pico_toolchain.cmake"
  )
  local f
  for f in "${candidates[@]}"; do
    if [ -f "$f" ]; then
      echo "$f"
      return 0
    fi
  done
  return 1
}

# Prefer the official Arm GNU toolchain if you installed it here:
if [ -d "$HOME/arm-gnu-toolchain/bin" ]; then
  export PATH="$HOME/arm-gnu-toolchain/bin:$PATH"
fi

# Require toolchain + SDK
command -v arm-none-eabi-gcc >/dev/null || { echo "arm-none-eabi-gcc not found. See README to install toolchain."; exit 1; }
export PICO_SDK_PATH="${PICO_SDK_PATH:-$HOME/pico-sdk}"
export PICO_EXTRAS_PATH="${PICO_EXTRAS_PATH:-$HOME/pico-extras}"

# Quick sanity: nosys.specs should resolve to a real path
NSP="$(arm-none-eabi-gcc -print-file-name=nosys.specs)"
[ -f "$NSP" ] || { echo "nosys.specs not found by toolchain. Install the official Arm GNU toolchain (see README)."; exit 1; }

# Choose a generator
GEN="Unix Makefiles"; command -v ninja >/dev/null && GEN="Ninja"

# Persist FetchContent downloads to avoid re-fetching (e.g., picotool) between runs
export FETCHCONTENT_BASE_DIR="${FETCHCONTENT_BASE_DIR:-$HOME/.cache/cmake-fetch}"
mkdir -p "$FETCHCONTENT_BASE_DIR"

# Configure (keep build/ so deps are not re‑fetched); use persistent FetchContent cache + toolchain
TC="$(find_pico_toolchain_file || true)"
FC_FLAGS="-DFETCHCONTENT_BASE_DIR=\"$FETCHCONTENT_BASE_DIR\""
# If deps already exist in cache or _deps/, build fully disconnected for speed
if ls -d "$FETCHCONTENT_BASE_DIR"/picotool* >/dev/null 2>&1 || [ -d "build/_deps/picotool-src" ]; then
  FC_FLAGS="$FC_FLAGS -DFETCHCONTENT_FULLY_DISCONNECTED=ON -DFETCHCONTENT_UPDATES_DISCONNECTED=ON"
fi
CMAKE_ARGS=(
  -S . -B build -G "$GEN"
  -DPICO_BOARD="${PICO_BOARD:-pico2}"
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE:-Debug}"
  -DPICO_SDK_PATH="$PICO_SDK_PATH"
  -DPICO_EXTRAS_PATH="$PICO_EXTRAS_PATH"
)
if [ -n "$TC" ]; then
  CMAKE_ARGS+=( -DCMAKE_TOOLCHAIN_FILE="$TC" )
fi
# shellcheck disable=SC2086
cmake "${CMAKE_ARGS[@]}" $FC_FLAGS

# Build with all cores
J=4
if command -v nproc >/dev/null; then J=$(nproc); elif command -v sysctl >/dev/null; then J=$(sysctl -n hw.ncpu); fi
cmake --build build -j"$J"

# Auto-copy to BOOTSEL volume (if mounted)
UF2=$(ls -t build/*.uf2 2>/dev/null | head -n 1 || true)
if [ -n "$UF2" ]; then
  if   [ -d "/Volumes/RPI-RP2" ];             then cp "$UF2" /Volumes/RPI-RP2/ && echo "Flashed: $UF2"
  elif [ -d "/media/$USER/RPI-RP2" ];         then cp "$UF2" "/media/$USER/RPI-RP2/" && echo "Flashed: $UF2"
  elif [ -d "/run/media/$USER/RPI-RP2" ];     then cp "$UF2" "/run/media/$USER/RPI-RP2/" && echo "Flashed: $UF2"
  else echo "Built: $UF2 (put board in BOOTSEL to flash)"; fi
else
  echo "Build OK, but no UF2 was produced (check target name/outputs)."
fi
