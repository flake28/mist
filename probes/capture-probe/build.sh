#!/bin/sh
set -e
cd "$(dirname "$0")"
swiftc -O -swift-version 5 main.swift -o mist-probe
echo "Built ./mist-probe"
