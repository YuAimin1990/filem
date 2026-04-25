#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "" > running/logs/error.log
echo "" > running/logs/access.log

bash "$SCRIPT_DIR/stop.sh"
bash "$SCRIPT_DIR/start.sh"

