#!/bin/sh
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
#
# Build examples/book end to end and check every edition: the site carries the
# MathML, the EPUB carries it, parses as XML and marks its chapters
# `properties="mathml"`, and the PDF prints the TeX source. A second build at
# another --jobs has to give the same bytes.
#
# Needs a Grimoire with the `mathml` feature (0.5.0 or later), katex, unzip and
# python3; pdftotext, when installed, reads the PDF's text:
#
#   GRIMOIRE="$PWD/../grimoire/bin/grimoire" scripts/check-example.sh
#
# GRIMOIRE is run from a copy of the book in a temp directory, so it has to be
# a command on PATH or an absolute path.

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
GRIMOIRE=${GRIMOIRE:-grimoire}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r "$root/examples/book" "$work/book"
cd "$work/book"
# The launcher by absolute path, since the copy is not beside the repository.
sed -i "s|^command = .*|command = \"$root/bin/grimoire-katex\"|" grimoire.toml

fail() { echo "FAIL: $*" >&2; exit 1; }

"$GRIMOIRE" build --quiet --jobs 1 --out site
"$GRIMOIRE" build --quiet --jobs 4 --out again
diff -r site again >/dev/null || fail "--jobs 1 and --jobs 4 differ"
echo "ok  same bytes at --jobs 1 and 4"

count() { grep -o "$1" "$2" | wc -l; }
[ "$(count '<math xmlns="http://www.w3.org/1998/Math/MathML">' site/index.html)" -eq 4 ] \
    || fail "index.html does not carry its four inline formulas"
[ "$(count 'display="block"' site/index.html)" -eq 1 ] \
    || fail "index.html does not carry its display formula"
[ "$(count '<math ' site/guide/sums.html)" -eq 5 ] || fail "guide/sums.html is missing maths"
if grep -q '&lt;math' site/index.html site/guide/sums.html; then
    fail "MathML was escaped on the site"
fi
grep -q '<code>\$HOME</code>' site/index.html || fail "a code span was typeset"
echo "ok  site"

mkdir epub
(cd epub && unzip -q ../site/maths.epub)
python3 -I - "$PWD/epub" <<'PY' || fail "the EPUB is not valid XML or lost its maths"
import glob, sys, xml.etree.ElementTree as ET
MATHML = "{http://www.w3.org/1998/Math/MathML}math"
root = sys.argv[1]
for f in glob.glob(root + "/**/*", recursive=True):
    if f.endswith((".xhtml", ".opf", ".xml")):
        ET.parse(f)
found = sum(len(ET.parse(f).getroot().findall(".//" + MATHML))
            for f in glob.glob(root + "/OEBPS/*.xhtml"))
sys.exit(0 if found == 10 else 1)
PY
[ "$(count 'properties="mathml"' epub/OEBPS/content.opf)" -eq 2 ] \
    || fail "the package does not mark both chapters properties=\"mathml\""
echo "ok  epub"

if command -v pdftotext >/dev/null 2>&1; then
    pdftotext site/book.pdf book.txt
    grep -q 'e^{i\\pi} + 1 = 0' book.txt || fail "the PDF does not print the TeX source"
    echo "ok  pdf"
else
    test -s site/book.pdf || fail "no PDF"
    echo "ok  pdf (written; install pdftotext to read it)"
fi
