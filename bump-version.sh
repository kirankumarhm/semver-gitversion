#!/bin/sh
# Usage: sh bump-version.sh [patch|minor|major]
# Bumps pom.xml version and prints the new version.
set -e

CURRENT=$(mvn help:evaluate -Dexpression=project.version -q -DforceStdout)

MAJOR=$(echo "$CURRENT" | cut -d. -f1)
MINOR=$(echo "$CURRENT" | cut -d. -f2)
PATCH=$(echo "$CURRENT" | cut -d. -f3)

case "$1" in
  major) MAJOR=$((MAJOR+1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR+1)); PATCH=0 ;;
  patch) PATCH=$((PATCH+1)) ;;
  *)
    echo "ERROR: argument must be patch | minor | major (got: '$1')" >&2
    exit 1
    ;;
esac

NEW="$MAJOR.$MINOR.$PATCH"
# generateBackupPoms=true (default) — keeps pom.xml.versionsBackup so
# 'mvn versions:revert' can undo the bump if something goes wrong in CI.
mvn versions:set -DnewVersion="$NEW" -q
echo "$NEW"
