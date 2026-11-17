#!/usr/bin/env bash
# Prints the notes of one version from a CHANGELOG file: the lines under its
# `## X.Y.Z — date` heading, up to the next `## ` heading, without the
# heading and without leading/trailing blank lines. Exits 1 when the version
# has no section.
#
#   scripts/changelog_section.sh CHANGELOG.md 1.2.3   (a leading v is accepted)
set -euo pipefail
file=${1:?usage: changelog_section.sh <CHANGELOG.md> <version>}
ver=${2:?usage: changelog_section.sh <CHANGELOG.md> <version>}
ver=${ver#v}

awk -v ver="$ver" '
  /^## / {
    if (inside) exit
    h = $0
    sub(/^## +\[?v?/, "", h)
    split(h, parts, /[^0-9.]/)
    if (parts[1] == ver) { inside = 1; found = 1; next }
  }
  inside {
    if ($0 ~ /^[[:space:]]*$/) { blanks++; next }
    if (printed) for (i = 0; i < blanks; i++) print ""
    blanks = 0
    print
    printed = 1
  }
  END { exit found ? 0 : 1 }
' "$file"
