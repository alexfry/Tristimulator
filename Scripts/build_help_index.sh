#!/bin/bash
# Regenerate the Tristimulator Help search indexes with hiutil.
#
# Help Viewer on macOS 10.14 and later reads the Core Spotlight index
# (HPDBookCSIndexPath); older systems read the LSM index (HPDBookIndexPath).
# Run this after editing any page in Help/Tristimulator.help and commit the
# regenerated index files with your change.
set -euo pipefail
cd "$(dirname "$0")/../Help/Tristimulator.help/Contents/Resources/en.lproj"
hiutil -I corespotlight -Caf Tristimulator.cshelpindex -s en -l en -m 3 .
hiutil -I lsm -Caf Tristimulator.helpindex -s en -l en -m 3 .
echo "Indexed: $(hiutil -I corespotlight -Af Tristimulator.cshelpindex | wc -l | tr -d ' ') anchor lines"
