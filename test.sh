#!/bin/bash
# Checks Galley's link handling on the PDFs in test-pdf/ without opening the app.
# Usage: ./test.sh            write reports to test-pdf/reports/ and compare with test-pdf/expected/
#        ./test.sh --accept   take the current reports as the expected results
set -euo pipefail
cd "$(dirname "$0")"

if [[ "${1:-}" == "--accept" ]]; then
  mkdir -p test-pdf/expected
  cp test-pdf/reports/*.txt test-pdf/expected/
  echo "OK: Current reports saved as expected results."
  exit 0
fi

echo "-> Compiling the link report..."
mkdir -p build
xcrun swiftc -O -parse-as-library -swift-version 5 \
  -target "$(uname -m)-apple-macos14.0" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-name LinkReport \
  Sources/DestinationFixer.swift Sources/ReferenceDetector.swift Sources/OutlineDetector.swift Tests/LinkReport.swift \
  -o build/linkreport

echo "-> Reading the test PDFs..."
rm -rf test-pdf/reports
build/linkreport test-pdf/reports test-pdf/*.pdf

changed=0
for report in test-pdf/reports/*.txt; do
  name="$(basename "${report}")"
  expected="test-pdf/expected/${name}"
  if [[ ! -f "${expected}" ]]; then
    echo "   new:       ${name}"
  elif ! diff -q "${expected}" "${report}" >/dev/null; then
    echo "   changed:   ${name} ($(diff "${expected}" "${report}" | grep -c '^[<>]') lines)"
    changed=$((changed + 1))
  else
    echo "   unchanged: ${name}"
  fi
done
echo "OK: Reports in test-pdf/reports/ (${changed} changed)."
