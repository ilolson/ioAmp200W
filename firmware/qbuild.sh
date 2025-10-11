#!/usr/bin/env bash
set -e

# Prefer the official Arm GNU toolchain if you installed it here:
if [ -d "$HOME/arm-gnu-toolchain/bin" ]; then
  export PATH="$HOME/arm-gnu-toolchain/bin:$PATH"
fi

# Require toolchain + SDK
command -v arm-none-eabi-gcc >/dev/null || { echo "arm-none-eabi-gcc not found. See README to install toolchain."; exit 1; }
export PICO_SDK_PATH="${PICO_SDK_PATH:-$HOME/pico-sdk}"

# Quick sanity: nosys.specs should resolve to a real path
NSP="$(arm-none-eabi-gcc -print-file-name=nosys.specs)"
[ -f "$NSP" ] || { echo "nosys.specs not found by toolchain. Install the official Arm GNU toolchain (see README)."; exit 1; }

# Choose a generator
GEN="Unix Makefiles"; command -v ninja >/dev/null && GEN="Ninja"

# Persist FetchContent downloads to avoid re-fetching (e.g., picotool) between runs
export FETCHCONTENT_BASE_DIR="${FETCHCONTENT_BASE_DIR:-$HOME/.cache/cmake-fetch}"
mkdir -p "$FETCHCONTENT_BASE_DIR"

# Configure (keep build/ so dependencies are not re-fetched); pass persistent FetchContent cache
cmake -S . -B build -G "$GEN" -DPICO_BOARD="${PICO_BOARD:-pico2}" -DCMAKE_BUILD_TYPE="${BUILD_TYPE:-Debug}" -DFETCHCONTENT_BASE_DIR="$FETCHCONTENT_BASE_DIR"

# Build with all cores
J=4
if command -v nproc >/dev/null; then J=$(nproc); elif command -v sysctl >/dev/null; then J=$(sysctl -n hw.ncpu); fi
cmake --build build -j"$J"

# Auto-copy to BOOTSEL volume (if mounted)
UF2=$(ls -t build/*.uf2 2>/dev/null | head -n 1 || true)
if [ -n "$UF2" ]; then
  if   [ -d "/Volumes/RPI-RP2" ];         then cp "$UF2" /Volumes/RPI-RP2/ && echo "Flashed: $UF2"
  elif [ -d "/media/$USER/RPI-RP2" ];     then cp "$UF2" "/media/$USER/RPI-RP2/" && echo "Flashed: $UF2"
  else echo "Built: $UF2 (put board in BOOTSEL to flash)"; fi
else
  echo "Build OK, but no UF2 was produced (check target name/outputs)."
fi
