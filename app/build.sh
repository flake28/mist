#!/bin/sh
set -e
cd "$(dirname "$0")"
swiftc -O -swift-version 5 Sources/*.swift -o mist
echo "Built ./mist"
