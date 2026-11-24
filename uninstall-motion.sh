#!/bin/zsh
# Removes the snowy-motion helper (shake & tilt). Snowy Motion keeps working without it.
sudo launchctl bootout system/app.snowy.motion 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/app.snowy.motion.plist
sudo rm -rf "/Library/Application Support/SnowyMotion"
sudo rm -f /Library/Logs/snowy-motion.log
print "The snowy-motion helper was removed."
