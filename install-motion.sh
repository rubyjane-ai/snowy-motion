#!/bin/zsh
# Shake & tilt for Snowy Motion: builds and installs the app, installs the snowy-motion
# helper (runs as root, the only way to read the MacBook's motion sensor) and calibrates it.
# Usage:     zsh install-motion.sh
# Uninstall: zsh uninstall-motion.sh
set -euo pipefail
src="${0:A:h}"
cd "$src"
dir="/Library/Application Support/SnowyMotion"
plist="/Library/LaunchDaemons/app.snowy.motion.plist"

say() { print -P "%F{cyan}==>%f $1"; }
fail() { print -P "%F{red}Error:%f $1" >&2; exit 1; }

[[ "$(uname -m)" == "arm64" ]] || fail "Apple Silicon Mac required."
# No pipeline here: with pipefail, "ioreg | grep -q" can fail even when the sensor exists.
sensor_info="$(ioreg -r -c AppleSPUHIDDevice 2>/dev/null || true)"
[[ "$sensor_info" == *'"PrimaryUsage" = 3'* ]] || fail "no motion sensor (AppleSPUHIDDevice, usage 3) found on this Mac."
xcode-select -p >/dev/null 2>&1 || { xcode-select --install || true; fail "install the Command Line Tools, then run this again."; }

say "Step 1/4. Building and installing Snowy Motion…"
zsh "$src/install.sh"

say "Step 2/4. Building the snowy-motion helper…"
mkdir -p .build/motion
swiftc -O -swift-version 5 motion/snowy-motion.swift -o .build/motion/snowy-motion

say "Step 3/4. Installing the helper. macOS will ask for your administrator password (typing is hidden)."
sudo launchctl bootout system/app.snowy.motion 2>/dev/null || true
sudo mkdir -p "$dir"
sudo cp .build/motion/snowy-motion "$dir/snowy-motion"
sudo chown root:wheel "$dir/snowy-motion"
sudo chmod 755 "$dir/snowy-motion"

say "Step 4/4. Calibration: follow the prompts."
sudo "$dir/snowy-motion" --calibrate || fail "calibration failed. Run this script again."

sudo cp motion/app.snowy.motion.plist "$plist"
sudo chown root:wheel "$plist"
sudo chmod 644 "$plist"
sudo launchctl bootstrap system "$plist"
sleep 2
if sudo launchctl print system/app.snowy.motion 2>/dev/null | grep -q "state = running"; then
  say "Done. Tilt your Mac and the snow slides that way; shake it and snow falls off your windows."
else
  print "The helper did not start. Log: /Library/Logs/snowy-motion.log"
fi
