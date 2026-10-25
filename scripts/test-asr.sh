#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
fixture_dir="$(mktemp -d "$PWD/build/asr-test.XXXXXX")"
say -v Thomas -o "$fixture_dir/sample.aiff" 'Bonjour Antoine. La réunion commence à neuf heures. Nous devons préparer le prototype pour vendredi.'
afconvert -f caff -d LEF32@16000 -c 1 "$fixture_dir/sample.aiff" "$fixture_dir/sample.caf"
"build/How Was Your Day.app/Contents/MacOS/HWYD" --asr-test "$fixture_dir"
