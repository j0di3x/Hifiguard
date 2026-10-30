#!/bin/bash
# Renders the README screenshots into docs/images from the real panel views, with sample devices.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p docs/images
TEST_RUNNER_HIFIGUARD_SCREENSHOT_DIR="$PWD/docs/images" xcodebuild test \
    -scheme Hifiguard \
    -testLanguage en -testRegion US \
    -derivedDataPath "${TMPDIR:-/tmp}/hifiguard-screenshots" \
    -only-testing:HifiguardTests/ScreenshotTests \
    -quiet
