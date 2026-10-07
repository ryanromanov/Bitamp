#!/bin/sh
# Renders the README's screenshots and the repository's social preview into docs/images,
# from the views themselves with a made-up playlist (see Tests/BitampTests/ShowcaseTests.swift).
set -eu
cd "$(dirname "$0")/.."
mkdir -p docs/images
BITAMP_SHOWCASE="$PWD/docs/images" exec scripts/test.sh --filter ShowcaseTests
