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

# FriendlyELEC's final RK3328 platform kernel has CONFIG_SOUND=y and
# CONFIG_SND=y built in, while the FriendlyWrt rootfs package phase uses a
# different kernel ABI.  Do not install the rootfs phase's real
# kmod-sound-core APK: it cannot be loaded by the final platform kernel.
#
# Instead, install a small compatibility package which permanently records the
# kmod-sound-core capability in the firmware APK database.  This survives a
# sysupgrade because it is part of every newly built rootfs, unlike an
# `apk add --virtual` entry created manually on a running device.
readonly SOUND_COMPAT_DIR="friendlywrt/package/friendlywrt-sound-core-compat"
mkdir -p "${SOUND_COMPAT_DIR}/files"

cat > "${SOUND_COMPAT_DIR}/Makefile" <<'EOF'
include $(TOPDIR)/rules.mk

PKG_NAME:=friendlywrt-sound-core-compat
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/friendlywrt-sound-core-compat
  SECTION:=base
  CATEGORY:=Base system
  TITLE:=FriendlyWrt built-in sound-core compatibility provider
  # Keep the provider name unprefixed for both 24.10 (opkg) and 25.12 (apk).
  PROVIDES:=kmod-sound-core
  DEFAULT_VARIANT:=1
endef

define Package/friendlywrt-sound-core-compat/description
 Provides the kmod-sound-core package capability when the ALSA sound core is
 built into the FriendlyELEC platform kernel. This package contains no kernel
 module and must only be used with a platform kernel built with CONFIG_SND=y.
endef

define Build/Compile
endef

define Package/friendlywrt-sound-core-compat/install
	$(INSTALL_DIR) $(1)/usr/share/friendlywrt
	$(INSTALL_DATA) ./files/sound-core-compat \
		$(1)/usr/share/friendlywrt/sound-core-compat
endef

$(eval $(call BuildPackage,friendlywrt-sound-core-compat))
EOF

cat > "${SOUND_COMPAT_DIR}/files/sound-core-compat" <<'EOF'
The FriendlyELEC platform kernel provides ALSA sound core through CONFIG_SND=y.
This package is APK metadata compatibility only and contains no kernel module.
EOF

cat > configs/rockchip/98-sound-core-compat <<'EOF'
# The final FriendlyELEC platform kernel has sound core built in.
CONFIG_PACKAGE_friendlywrt-sound-core-compat=y
EOF
cp configs/rockchip/98-sound-core-compat \
   configs/rockchip-docker/98-sound-core-compat

# Remove the obsolete fragment created by an earlier version of this script.
# Leaving it behind would select the incompatible rootfs-kernel APK again when
# an existing local workspace is reused.
rm -f configs/rockchip/98-sound-core \
      configs/rockchip-docker/98-sound-core

echo "OpenAppFilter and built-in sound-core compatibility configurations are ready."
