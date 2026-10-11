#!/usr/bin/env bash
# Formats every Swift file with the rules in .swift-format.
set -euo pipefail
cd "$(dirname "$0")/.."
swift format format -i -r Sources Tests
