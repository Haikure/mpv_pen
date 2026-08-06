#!/bin/bash

set -oset -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd $SCRIPT_DIR
ln -sr ./mpv /userdisk/VideoPlayer
