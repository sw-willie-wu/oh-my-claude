#!/bin/bash
# Test-only loader: source statusline.sh up to function definitions, skipping
# JSON parsing and render. Achieved via OMC_TEST_LIB_ONLY env var that gates
# the render section.
OMC_TEST_LIB_ONLY=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/statusline.sh"
