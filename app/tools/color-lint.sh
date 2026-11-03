#!/bin/zsh
# Flags colors written in views instead of taken from the palette (S-031):
# named system colors (.red, .systemOrange, Color.blue), .white, .black,
# .gray, and colors made from numbers (Color(red:), NSColor(hex:), srgbRed).
# Views use .primary, .secondary, .tint, the semantic NSColors (labelColor,
# separatorColor, ...), Palette (accent) and ServicePalette / StatusColors
# (MagnifeKit ColorPalette, contrast-tested).
# Skipped: the palette and token files (UI/Theme.swift, UI/ServicePalette.swift),
# the grid overlay (UI/Grid.swift, debug only), and self-test and snapshot code.
# Silence one line with a reason: // color: ok <why>
# Usage: tools/color-lint.sh [folder]      (default: Sources/Magnife)
set -euo pipefail
dir=${1:-${0:A:h:h}/Sources/Magnife}
find "$dir" -name '*.swift' -not -name 'Theme.swift' -not -name 'ServicePalette.swift' -not -name 'Grid.swift' \
  -not -name 'SelfTest*' -not -name 'Snapshot*' -print0 | xargs -0 perl -ne '
  BEGIN { $count = 0 }
  my $names = "red|orange|yellow|green|blue|purple|pink|teal|indigo|brown|mint|cyan|gray|white|black";
  if (!/color: ok/ && !m{^\s*//}) {
    if (/(?<![\w.])\.(?:$names)\b/ || /\bColor\.(?:$names)\b/ || /\bsystem(?:Red|Orange|Yellow|Green|Blue|Purple|Pink|Teal|Indigo|Brown|Mint|Cyan|Gray)\b/
        || /\b(?:NS)?Color\((?:hex|red|white|srgbRed|calibratedRed|deviceRed|calibratedWhite|deviceWhite)\s*:/) {
      $count++; my $l = $_; $l =~ s/^\s+//; print "$ARGV:$.: fixed color: $l";
    }
  }
  close ARGV if eof;
  END { if ($count) { print "FAIL color-lint: $count lines with a fixed color\n"; exit 1 } print "PASS color-lint\n" }'
