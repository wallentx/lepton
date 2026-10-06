#!/bin/bash
set -euo pipefail

apt-get -qq update && apt-get install -y git python3 curl unzip tmux

if [[ -n "${CI_COMMIT_TAG:-}" ]] || [[ "${CI_PIPELINE_SOURCE:-}" == "merge_request_event" ]] || [[ "${CI_COMMIT_BRANCH:-}" == "main" ]]; then
  # Find the previous version tag without needing the first parent object
  if [[ "${CI_PIPELINE_SOURCE:-}" == "merge_request_event" ]] || [[ "${CI_COMMIT_BRANCH:-}" == "main" ]]; then
    PREVIOUS_TAG=$(git tag --list 'v[0-9]*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)
  else
    PREVIOUS_TAG=$(git tag --list 'v[0-9]*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sed -n '/^'"$CI_COMMIT_TAG"'$/{n;p;q}' || true)
  fi

  echo "build-rootfs: CI_COMMIT_TAG=${CI_COMMIT_TAG:-}, CI_COMMIT_SHA=${CI_COMMIT_SHA}, CI_COMMIT_BRANCH=${CI_COMMIT_BRANCH:-}, PREVIOUS_TAG=$PREVIOUS_TAG, initial ${ROOTFS_VERSION_VAR}=${!ROOTFS_VERSION_VAR:-}"

  if [ -z "$PREVIOUS_TAG" ]; then
    echo "build-rootfs: no previous tag found, forcing rebuild"
    printf -v "$ROOTFS_VERSION_VAR" %s ""
  elif ! git diff --quiet "$PREVIOUS_TAG" "${CI_COMMIT_SHA}" -- "$IMAGE_DIR" ".ci_scripts/$BUILD_SCRIPT" ".ci_scripts/$DEPENDENCIES_SCRIPT"; then
    echo "build-rootfs: rootfs changed vs $PREVIOUS_TAG, forcing rebuild"
    printf -v "$ROOTFS_VERSION_VAR" %s ""
  else
    echo "build-rootfs: no rootfs changes vs $PREVIOUS_TAG, keeping ${ROOTFS_VERSION_VAR}=${!ROOTFS_VERSION_VAR}"
  fi
fi

if [[ -z "${!ROOTFS_VERSION_VAR}" ]]; then
  ./.ci_scripts/"$DEPENDENCIES_SCRIPT"
  ./.ci_scripts/"$BUILD_SCRIPT"
else
  ROOTFS_JOB_ID=$(python3 ./.ci_scripts/resolve-rootfs-version.py "$JOB_NAME" "${!ROOTFS_VERSION_VAR}")
  DOWNLOAD_URL="${CI_API_V4_URL}/projects/deckard%2Flepton/jobs/${ROOTFS_JOB_ID}/artifacts"
  echo "Downloading rootfs artifacts from: $DOWNLOAD_URL (${ROOTFS_VERSION_VAR}=${!ROOTFS_VERSION_VAR})"

  curl --fail --location --header "PRIVATE-TOKEN: ${CI_LEPTON_TOKEN}" \
    --output build-rootfs-artifacts.zip \
    "$DOWNLOAD_URL"
  unzip -o build-rootfs-artifacts.zip
  rm build-rootfs-artifacts.zip
fi
test -f "$IMAGE_DIR"/system.img || exit 1
test -f "$IMAGE_DIR"/vendor.img || exit 1
test -f "$IMAGE_DIR"/NOTICE.txt || exit 1
test -f "$IMAGE_DIR"/version.txt || exit 1
test -f "${SYMBOLS}" || exit 1
