Param(
  [string]$Board = $env:PICO_BOARD ?? "pico2",
  [string]$BuildType = $env:BUILD_TYPE ?? "Debug"
)

# Prefer official Arm toolchain if present
$ToolPath = "$HOME\arm-gnu-toolchain\bin"
if (Test-Path $ToolPath) { $env:PATH = "$ToolPath;$env:PATH" }

# Require toolchain + SDK
if (-not (Get-Command arm-none-eabi-gcc -ErrorAction SilentlyContinue)) {
  Write-Error "arm-none-eabi-gcc not found. See README to install toolchain."; exit 1
}
if (-not $env:PICO_SDK_PATH) {
  $env:PICO_SDK_PATH = "$HOME\pico-sdk"
}

# nosys.specs must resolve to a real file
$spec = & arm-none-eabi-gcc -print-file-name=nosys.specs
if (-not (Test-Path $spec)) {
  Write-Error "nosys.specs not found by toolchain. Install the official Arm GNU toolchain (see README)."; exit 1
}

# Prefer Ninja if available
$gen = "Ninja"
if (-not (Get-Command ninja -ErrorAction SilentlyContinue)) { $gen = "Unix Makefiles" }

# Clean configure + build
Remove-Item -Recurse -Force build -ErrorAction SilentlyContinue
cmake -S . -B build -G "$gen" -DPICO_BOARD="$Board" -DCMAKE_BUILD_TYPE="$BuildType"
cmake --build build --config $BuildType

# Copy to BOOTSEL if mounted (RPI-RP2 shows as a drive letter)
$uf2 = Get-ChildItem build -Filter *.uf2 | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($uf2) {
  $dest = Get-PSDrive | Where-Object { $_.Root -match "RPI-RP2" } | Select-Object -First 1
  if ($dest) {
    Copy-Item $uf2.FullName "$($dest.Root)"
    Write-Host "Flashed: $($uf2.FullName)"
  } else {
    Write-Host "Built: $($uf2.FullName)  (Put board in BOOTSEL to flash)"
  }
} else {
  Write-Host "Build OK, but no UF2 produced."
}
