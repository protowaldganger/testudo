#!/bin/zsh
# Builds build/Testudo.app and build/Testudo.dmg. Needs Xcode.
set -euo pipefail
cd "${0:A:h}"
make -j "$(sysctl -n hw.ncpu)"
