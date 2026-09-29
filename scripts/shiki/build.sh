#!/usr/bin/env bash
# Rebuilds the syntax highlighter the diff window loads into JavaScriptCore.
# Usage: scripts/shiki/build.sh
set -euo pipefail
cd "$(dirname "$0")"
resources=../../Resources

npm ci --silent
npx esbuild entry.mjs --bundle --format=iife --minify --legal-comments=none \
  --outfile="$resources/shiki.js" --log-level=warning
node notices.mjs "$resources/shiki.js" "$resources/ThirdPartyNotices.txt"
node check.mjs "$resources/shiki.js" "$resources/ThirdPartyNotices.txt"
