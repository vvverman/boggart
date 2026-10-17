#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export BOGGART_HARDWARE_TESTING=0
exec ./Scripts/install.sh
