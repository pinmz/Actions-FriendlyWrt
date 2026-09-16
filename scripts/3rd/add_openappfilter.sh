#!/bin/bash
set -euo pipefail

# The FriendlyWrt rootfs is shared by multiple SoCs, while the final image uses
# a separately built FriendlyELEC kernel. Build oaf.ko again against that exact
# kernel so the module ABI matches the final firmware image.
readonly OAF_REPOSITORY="${OAF_REPOSITORY:-https://github.com/destan19/OpenAppFilter.git}"
readonly OAF_TAG="${OAF_TAG:-v7.0.1}"
readonly OAF_COMMIT="${OAF_COMMIT:-b88fcb082597486a816187ec1e02812082161d5e}"
readonly OAF_SOURCE_DIR="openappfilter-kmod"
readonly ARCH="arm64"
readonly CROSS_COMPILE="aarch64-linux-gnu-"
readonly TOOLCHAIN_BIN="/opt/FriendlyARM/toolchain/11.3-aarch64/bin"

if [ ! -d kernel ] || [ ! -d out ]; then
  echo "ERROR: run this script from the FriendlyWrt project root after building the kernel." >&2
  exit 1
fi

export PATH="${TOOLCHAIN_BIN}:${PATH}"

if ! command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
  echo "ERROR: cross compiler not found: ${CROSS_COMPILE}gcc" >&2
  exit 1
fi

if [ -e "${OAF_SOURCE_DIR}" ]; then
  if [ ! -d "${OAF_SOURCE_DIR}/.git" ]; then
    echo "ERROR: ${OAF_SOURCE_DIR} already exists and is not a git checkout." >&2
    exit 1
  fi
else
  git clone --depth 1 --branch "${OAF_TAG}" "${OAF_REPOSITORY}" "${OAF_SOURCE_DIR}"
fi

actual_commit="$(git -C "${OAF_SOURCE_DIR}" rev-parse HEAD)"
if [ "${actual_commit}" != "${OAF_COMMIT}" ]; then
  echo "ERROR: OpenAppFilter ${OAF_TAG} resolved to unexpected commit." >&2
  echo "Expected: ${OAF_COMMIT}" >&2
  echo "Actual:   ${actual_commit}" >&2
  exit 1
fi

kernel_version="$(make -s -C kernel ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" kernelrelease)"

shopt -s nullglob
module_roots=(out/output_*_kmodules)
shopt -u nullglob
if [ "${#module_roots[@]}" -ne 1 ]; then
  echo "ERROR: expected exactly one out/output_*_kmodules directory, found ${#module_roots[@]}." >&2
  printf '  %s\n' "${module_roots[@]:-none}" >&2
  exit 1
fi

module_root="${module_roots[0]}"
module_dir="${module_root}/lib/modules/${kernel_version}"
if [ ! -d "${module_dir}" ]; then
  echo "ERROR: kernel module output directory not found: ${module_dir}" >&2
  exit 1
fi

module_source="$(pwd)/${OAF_SOURCE_DIR}/oaf/src"
KCFLAGS="-Wno-error=missing-prototypes \
-Wno-error=missing-declarations \
-Wno-error=unused-variable \
-Wno-error=declaration-after-statement \
-Wno-error=implicit-fallthrough \
-Wno-error=missing-braces \
-Wno-error=parentheses \
-Wno-error=format \
-Wno-frame-larger-than"

make -C kernel \
  ARCH="${ARCH}" \
  CROSS_COMPILE="${CROSS_COMPILE}" \
  M="${module_source}" \
  KCFLAGS="${KCFLAGS}" \
  modules

"${CROSS_COMPILE}strip" --strip-unneeded "${module_source}/oaf.ko"
install -m 0644 "${module_source}/oaf.ko" "${module_dir}/oaf.ko"

depmod -a -b "${module_root}" "${kernel_version}"

# The platform kernel modules replace the modules from the shared rootfs.
# Add an explicit rootfs overlay entry so oaf.ko is loaded on boot regardless
# of how the OpenWrt kmod package generated its modules.d metadata.
overlay_name="openappfilter-kmod-files"
overlay_modules_dir="${overlay_name}/etc/modules.d"
mkdir -p "${overlay_modules_dir}"
echo "oaf" > "${overlay_modules_dir}/30-oaf"
if ! grep -qF "FRIENDLYWRT_FILES+=(${overlay_name})" .current_config.mk; then
  echo "FRIENDLYWRT_FILES+=(${overlay_name})" >> .current_config.mk
fi

echo "Installed OpenAppFilter kernel module: ${module_dir}/oaf.ko"
