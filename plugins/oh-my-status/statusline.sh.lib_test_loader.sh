#!/bin/bash
# Test-only loader: source statusline.sh up to function definitions, skipping
# JSON parsing and render. Achieved via OMC_TEST_LIB_ONLY env var that gates
# the render section.
OMC_TEST_LIB_ONLY=1
case ${BASH_SOURCE[0]} in */*|*\\*) SCRIPT_DIR=${BASH_SOURCE[0]%[/\\]*} ;; *) SCRIPT_DIR=. ;; esac
. "$SCRIPT_DIR/statusline.sh"
