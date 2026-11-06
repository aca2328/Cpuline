#!/bin/zsh

# Build and run script for Cpuline
# This script:
# 1. Pulls the latest changes from the current branch
# 2. Cleans the build directory completely
# 3. Builds the project in release mode
# 4. Runs the application

set -e

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

echo "🔄 Pulling latest changes..."
git pull origin HEAD

echo "🧹 Cleaning build directory..."
rm -rf .build

echo "🔨 Building in release mode..."
swift build --configuration release

echo "▶️  Running application..."
open "$(swift build --configuration release --show-bin-path)/Cpuline"

echo "✅ Application started. Check your Dock."
