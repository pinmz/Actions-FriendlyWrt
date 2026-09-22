#!/bin/bash
set -euo pipefail

# OpenAppFilter is a multi-package source tree containing:
#   - luci-app-oaf: LuCI UI
#   - appfilter: userspace service
#   - kmod-oaf: kernel module
# Keep the tag and commit pinned so CI builds are reproducible.
readonly OAF_REPOSITORY="${OAF_REPOSITORY:-https://github.com/destan19/OpenAppFilter.git}"
readonly OAF_TAG="${OAF_TAG:-v7.0.1}"
readonly OAF_COMMIT="${OAF_COMMIT:-b88fcb082597486a816187ec1e02812082161d5e}"
readonly OAF_DIR="friendlywrt/package/OpenAppFilter"
readonly CONFIG_FRAGMENT="99-openappfilter"
FRIENDLYWRT_VERSION="${1:-unknown}"

for required_dir in friendlywrt configs/rockchip configs/rockchip-docker; do
  if [ ! -d "${required_dir}" ]; then
    echo "ERROR: required directory not found: ${required_dir}" >&2
    echo "Run this script from the FriendlyWrt project root after repo sync." >&2
    return 1 2>/dev/null || exit 1
  fi
done

echo "Adding OpenAppFilter ${OAF_TAG} for FriendlyWrt ${FRIENDLYWRT_VERSION}"

if [ -e "${OAF_DIR}" ]; then
  if [ ! -d "${OAF_DIR}/.git" ]; then
    echo "ERROR: ${OAF_DIR} already exists and is not a git checkout." >&2
    return 1 2>/dev/null || exit 1
  fi
else
  git clone --depth 1 --branch "${OAF_TAG}" "${OAF_REPOSITORY}" "${OAF_DIR}"
fi

actual_commit="$(git -C "${OAF_DIR}" rev-parse HEAD)"
if [ "${actual_commit}" != "${OAF_COMMIT}" ]; then
  echo "ERROR: OpenAppFilter ${OAF_TAG} resolved to unexpected commit." >&2
  echo "Expected: ${OAF_COMMIT}" >&2
  echo "Actual:   ${actual_commit}" >&2
  return 1 2>/dev/null || exit 1
fi

cat > "configs/rockchip/${CONFIG_FRAGMENT}" <<'EOF'
# OpenAppFilter v7.0.1
CONFIG_PACKAGE_luci-app-oaf=y
CONFIG_PACKAGE_appfilter=y
CONFIG_PACKAGE_kmod-oaf=y
EOF

# rockchip and rockchip-docker are separate config sets. Keep an explicit
# fragment in both so the package is built into normal and Docker images.
cp "configs/rockchip/${CONFIG_FRAGMENT}" \
   "configs/rockchip-docker/${CONFIG_FRAGMENT}"

echo "OpenAppFilter source and build configuration are ready."