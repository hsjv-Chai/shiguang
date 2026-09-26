#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/photoarchive-perl.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
curl -fL https://www.cpan.org/src/5.0/perl-5.40.2.tar.gz -o "$WORK/perl.tar.gz"
printf '%s  %s\n' '10d4647cfbb543a7f9ae3e5f6851ec49305232ea7621aed24c7cfbb0bef4b70d' "$WORK/perl.tar.gz" | shasum -a 256 -c -
tar -xzf "$WORK/perl.tar.gz" -C "$WORK"
cd "$WORK/perl-5.40.2"
MACOSX_DEPLOYMENT_TARGET=14.0 sh Configure -des -Dprefix="$ROOT/Vendor/Perl" -Duserelocatableinc -Dman1dir=none -Dman3dir=none -Dccflags='-mmacosx-version-min=14.0' -Dldflags='-mmacosx-version-min=14.0'
make -j4
make install
cp Artistic Copying "$ROOT/Vendor/Perl/"
"$ROOT/Vendor/Perl/bin/perl" "$ROOT/Vendor/ExifTool/exiftool" -ver
