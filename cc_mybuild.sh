#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# Prerequisite: Ubuntu 22.04 with the FriendlyARM/OpenWrt build dependencies.
# Local build configuration: edit these values, then run: bash cc_mybuild.sh
# Only one VERSION / SET / CPU combination is built per invocation.
# ============================================================================
VERSION="25.12"       # Supported: 25.12, 24.10
SET="docker"          # Supported: docker, non-docker
CPU="rk3328"          # Supported: rk3328, rk3528, rk3399, rk3566,
                       #            rk3568, rk3576, rk3588
JOBS="$(nproc)"        # Parallel jobs for repo sync and compilation
# ============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly WORK_ROOT="${SCRIPT_DIR}/.local-build/${VERSION}-${SET}-${CPU}"
readonly ROOTFS_WORK_DIR="${WORK_ROOT}/rootfs"
readonly IMAGE_WORK_DIR="${WORK_ROOT}/image"
readonly INTERMEDIATE_DIR="${WORK_ROOT}/intermediate"
readonly ARTIFACT_DIR="${SCRIPT_DIR}/artifact/${VERSION}-${SET}-${CPU}"
readonly TOOLS_DIR="${SCRIPT_DIR}/.local-build/tools"
readonly REPO_SOURCE_DIR="${TOOLS_DIR}/friendlyarm-repo"
readonly REPO_BIN="${REPO_SOURCE_DIR}/repo"
readonly MANIFEST_URL="https://github.com/friendlyarm/friendlywrt_manifests"
readonly REPO_URL="https://github.com/friendlyarm/repo"

SUFFIX=""
CONFIG="rockchip"
MODEL=""
DIST_DIR=""
IMG_FILE=""
TGZ_FILE=""
ROOTFS_TAR=""
HOST_PM_TAR=""

log() {
    printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
    printf '\nWARNING: %s\n' "$*" >&2
}

die() {
    printf '\nERROR: %s\n' "$*" >&2
    trap - ERR
    exit 1
}

on_error() {
    local exit_code=$?
    printf '\nERROR: local build failed at line %s (exit code %s).\n' "${BASH_LINENO[0]}" "${exit_code}" >&2
    printf 'Workspace was kept for retry: %s\n' "${WORK_ROOT}" >&2
    exit "${exit_code}"
}
trap on_error ERR

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

safe_remove_under() {
    local parent="$1"
    local target="$2"
    local resolved_parent resolved_target

    resolved_parent="$(realpath -m "${parent}")"
    resolved_target="$(realpath -m "${target}")"

    case "${resolved_target}" in
        "${resolved_parent}"/*)
            rm -rf -- "${resolved_target}"
            ;;
        *)
            die "refusing to remove path outside ${resolved_parent}: ${resolved_target}"
            ;;
    esac
}

validate_selection() {
    [ "$#" -eq 0 ] || die "command-line options are not supported; edit VERSION, SET and CPU at the top of cc_mybuild.sh"

    case "${VERSION}" in
        25.12|24.10) ;;
        *) die "unsupported VERSION=${VERSION}; expected 25.12 or 24.10" ;;
    esac

    case "${SET}" in
        docker)
            SUFFIX="-docker"
            CONFIG="rockchip-docker"
            ;;
        non-docker)
            SUFFIX=""
            CONFIG="rockchip"
            ;;
        *) die "unsupported SET=${SET}; expected docker or non-docker" ;;
    esac

    case "${CPU}" in
        rk3328) MODEL="R2S-R2C-Series" ;;
        rk3528) MODEL="R28S-Zero2-NEO3Plus-Series" ;;
        rk3399) MODEL="R4S-Series" ;;
        rk3566) MODEL="R3S-Series" ;;
        rk3568) MODEL="R5S-R5C-Series" ;;
        rk3576) MODEL="M5-R76S-Series" ;;
        rk3588) MODEL="T6-R6S-R6C-M6-Series" ;;
        *) die "unsupported CPU=${CPU}" ;;
    esac

    [[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer: ${JOBS}"

    DIST_DIR="friendlywrt${VERSION%%.*}${SUFFIX}"
    IMG_FILE="${MODEL}-FriendlyWrt-${VERSION}${SUFFIX}.img"
    TGZ_FILE="images-${MODEL}-FriendlyWrt-${VERSION}${SUFFIX}.tgz"
    ROOTFS_TAR="${INTERMEDIATE_DIR}/rootfs-friendlywrt-${VERSION}${SUFFIX}.tgz"
    HOST_PM_TAR="${INTERMEDIATE_DIR}/host-pm-${VERSION}.tgz"
}

check_host() {
    [ "$(uname -s)" = "Linux" ] || die "local build requires Linux; on Windows use Ubuntu under WSL2/VM or a Linux host"

    # GNU tar configure and other OpenWrt build tools reject a root build.
    # Image creation will request sudo only for the steps that need privileges.
    [ "${EUID}" -ne 0 ] || die "do not run this build as root; use an unprivileged Linux user with sudo access (check with: id -u). If the workspace was created by root, change its ownership before retrying."

    case "$(uname -m)" in
        x86_64|amd64) ;;
        *) die "this local build wrapper currently supports only an x86_64 Linux host; current host is $(uname -m)" ;;
    esac

    local commands=(
        awk bash bzip2 find git grep gzip install ldd make nproc patch python3 realpath
        rsync sed tar time unzip wget xz
    )
    local command_name
    for command_name in "${commands[@]}"; do
        require_command "${command_name}"
    done

    # repo init needs the build user's Git identity in both source workspaces.
    # Check outside this repository so its local Git config cannot mask a
    # missing global/system identity in the newly created repo workspaces.
    if ! (cd / && git var GIT_COMMITTER_IDENT >/dev/null 2>&1); then
        die "Git committer identity is not configured for the current user; run: git config --global user.name 'Your Name' and git config --global user.email 'you@example.com'"
    fi

    local helper_files=(
        "scripts/add_packages.sh"
        "scripts/custome_config.sh"
        "scripts/3rd/add_openappfilter.sh"
    )
    local helper_file
    for helper_file in "${helper_files[@]}"; do
        [ -f "${SCRIPT_DIR}/${helper_file}" ] || \
            die "required project helper not found: ${SCRIPT_DIR}/${helper_file}; update the Actions-FriendlyWrt repository instead of copying only cc_mybuild.sh"
        if LC_ALL=C grep -q $'\r' "${SCRIPT_DIR}/${helper_file}"; then
            die "Windows CRLF line endings found in ${SCRIPT_DIR}/${helper_file}; convert project shell scripts with: sed -i 's/\r$//' cc_mybuild.sh scripts/*.sh scripts/3rd/*.sh scripts/wifi/*.sh"
        fi
    done

    if [ "${EUID}" -ne 0 ]; then
        require_command sudo
        log "Checking sudo access required by loop-device and filesystem image creation"
        sudo -v
    fi

    case "${SCRIPT_DIR}" in
        /mnt/[a-zA-Z]/*)
            warn "the source tree is on a Windows-mounted WSL filesystem (${SCRIPT_DIR}); building under the WSL Linux filesystem is much faster and safer"
            ;;
    esac
}

prepare_directories() {
    mkdir -p "${ROOTFS_WORK_DIR}" "${IMAGE_WORK_DIR}" \
        "${INTERMEDIATE_DIR}" "${ARTIFACT_DIR}" "${TOOLS_DIR}"
}

prepare_repo_tool() {
    if [ ! -x "${REPO_BIN}" ]; then
        log "Downloading FriendlyARM repo launcher"
        safe_remove_under "${TOOLS_DIR}" "${REPO_SOURCE_DIR}"
        git clone --depth=1 "${REPO_URL}" "${REPO_SOURCE_DIR}"
        chmod +x "${REPO_BIN}"
    fi
}

repo_init() {
    local work_dir="$1"
    local manifest="$2"

    (
        cd "${work_dir}"
        "${REPO_BIN}" init \
            --depth=1 \
            -u "${MANIFEST_URL}" \
            -b "master-v${VERSION}" \
            -m "${manifest}" \
            --repo-url="${REPO_URL}" \
            --no-clone-bundle
    )
}

repo_sync_projects() {
    local work_dir="$1"
    shift

    (
        cd "${work_dir}"
        "${REPO_BIN}" sync -c -j"${JOBS}" --no-clone-bundle "$@"
    )
}

prepare_rootfs_sources() {
    if [ -f "${ROOTFS_WORK_DIR}/.sources-ready" ]; then
        log "Reusing existing FriendlyWrt rootfs source: ${ROOTFS_WORK_DIR}"
    else
        log "Initializing FriendlyWrt rootfs source (master-v${VERSION}, rk3399.xml)"
        repo_init "${ROOTFS_WORK_DIR}" "rk3399.xml"
        repo_sync_projects "${ROOTFS_WORK_DIR}" \
            friendlywrt configs device/common device/friendlyelec scripts scripts/sd-fuse toolchain
        touch "${ROOTFS_WORK_DIR}/.sources-ready"
    fi

    log "Applying local package and configuration customizations"
    (
        cd "${ROOTFS_WORK_DIR}"
        source "${SCRIPT_DIR}/scripts/add_packages.sh" "${VERSION}"
        source "${SCRIPT_DIR}/scripts/custome_config.sh"
    )
}

prepare_rootfs_config() {
    log "Preparing FriendlyWrt ${VERSION} ${SET} configuration"
    cat > "${ROOTFS_WORK_DIR}/.current_config.mk" <<EOF
. device/friendlyelec/rk3399/base.mk
TARGET_IMAGE_DIRNAME=${DIST_DIR}
TARGET_FRIENDLYWRT_CONFIG=${CONFIG}
EOF

    (
        cd "${ROOTFS_WORK_DIR}"
        DEBUG_DOT_CONFIG=1 ./build.sh friendlywrt

        local package
        for package in luci-app-oaf appfilter kmod-oaf; do
            grep -q "^CONFIG_PACKAGE_${package}=y$" friendlywrt/.config || \
                die "OpenAppFilter package is not enabled: ${package}"
        done
    )
}

compile_rootfs() {
    log "Downloading FriendlyWrt packages"
    (
        cd "${ROOTFS_WORK_DIR}/friendlywrt"
        make download -j8
        find dl -type f -size -1024c -print
        find dl -type f -size -1024c -delete
    )

    log "Compiling FriendlyWrt rootfs with ${JOBS} jobs"
    (
        cd "${ROOTFS_WORK_DIR}/friendlywrt"
        if ! make -j"${JOBS}"; then
            warn "parallel FriendlyWrt build failed; retrying with one job and verbose output"
            make -j1 V=s
        fi
    )
}

package_rootfs() {
    log "Packaging locally built rootfs and host package manager"
    (
        cd "${ROOTFS_WORK_DIR}"
        set +u
        source .current_config.mk
        set -u

        [ -d "${FRIENDLYWRT_SRC}/${FRIENDLYWRT_ROOTFS}" ] || \
            die "rootfs output not found: ${FRIENDLYWRT_SRC}/${FRIENDLYWRT_ROOTFS}"
        [ -d "${FRIENDLYWRT_SRC}/${FRIENDLYWRT_PACKAGE_DIR}" ] || \
            die "package output not found: ${FRIENDLYWRT_SRC}/${FRIENDLYWRT_PACKAGE_DIR}"

        local pm_bin=""
        [ -f "${FRIENDLYWRT_SRC}/staging_dir/host/bin/apk" ] && \
            pm_bin="${FRIENDLYWRT_SRC}/staging_dir/host/bin/apk"
        [ -f "${FRIENDLYWRT_SRC}/staging_dir/host/bin/opkg" ] && \
            pm_bin="${FRIENDLYWRT_SRC}/staging_dir/host/bin/opkg"
        [ -n "${pm_bin}" ] || die "neither apk nor opkg was found under ${FRIENDLYWRT_SRC}/staging_dir/host/bin"

        local rootfs_items=(
            "${FRIENDLYWRT_SRC}/${FRIENDLYWRT_ROOTFS}"
            "${FRIENDLYWRT_SRC}/${FRIENDLYWRT_PACKAGE_DIR}"
        )

        # OpenWrt 25+ signs the locally generated packages.adb with this build's
        # private key. Keep the matching public key under a unique filename so
        # the final image trusts the local repository without replacing any
        # upstream distribution keys already present in /etc/apk/keys.
        if [ "$(basename "${pm_bin}")" = "apk" ]; then
            local apk_public_key="${FRIENDLYWRT_SRC}/public-key.pem"
            local apk_keys_dir="${FRIENDLYWRT_SRC}/${FRIENDLYWRT_ROOTFS}/etc/apk/keys"

            [ -s "${apk_public_key}" ] || \
                die "APK public key not found or empty: ${apk_public_key}"
            mkdir -p "${apk_keys_dir}"
            install -m 0644 \
                "${apk_public_key}" \
                "${apk_keys_dir}/friendlywrt-local.pem"
            rootfs_items+=("${apk_public_key}")
            log "Installed the local APK repository key into the rootfs"
        fi

        tar czf "${ROOTFS_TAR}" "${rootfs_items[@]}"

        log "Using host package manager: ${pm_bin}"
        tar czf "${HOST_PM_TAR}" "${pm_bin}"
    )
}

prepare_image_sources() {
    if [ -f "${IMAGE_WORK_DIR}/.sources-ready" ]; then
        log "Reusing existing ${CPU} image source: ${IMAGE_WORK_DIR}"
    else
        log "Initializing ${CPU} image source (master-v${VERSION}, ${CPU}.xml)"
        repo_init "${IMAGE_WORK_DIR}" "${CPU}.xml"
        repo_sync_projects "${IMAGE_WORK_DIR}" \
            kernel u-boot rkbin configs device/common device/friendlyelec scripts scripts/sd-fuse toolchain
        touch "${IMAGE_WORK_DIR}/.sources-ready"
    fi

    cat > "${IMAGE_WORK_DIR}/.current_config.mk" <<EOF
. device/friendlyelec/${CPU}/base.mk
TARGET_IMAGE_DIRNAME=${DIST_DIR}
TARGET_FRIENDLYWRT_CONFIG=${CONFIG}
TARGET_SD_RAW_FILENAME=${IMG_FILE}
EOF
}


install_platform_toolchain() {
    local toolchain_dir="/opt/FriendlyARM/toolchain/11.3-aarch64"
    local toolchain_archive="${IMAGE_WORK_DIR}/toolchain/gcc-x64/toolchain-11.3-aarch64.tar.xz"

    if [ -x "${toolchain_dir}/bin/aarch64-linux-gnu-gcc" ]; then
        log "Using installed platform toolchain: ${toolchain_dir}"
        return
    fi

    [ -f "${toolchain_archive}" ] || \
        die "platform toolchain archive not found: ${toolchain_archive}"

    log "Installing FriendlyARM aarch64 GCC 11.3 toolchain under /opt"
    if [ "${EUID}" -eq 0 ]; then
        tar xJf "${toolchain_archive}" -C /
    else
        sudo tar xJf "${toolchain_archive}" -C /
    fi

    [ -x "${toolchain_dir}/bin/aarch64-linux-gnu-gcc" ] || \
        die "platform toolchain installation failed: ${toolchain_dir}"
}

unpack_rootfs_for_image() {
    log "Installing rootfs into the ${CPU} image workspace"
    (
        cd "${IMAGE_WORK_DIR}"
        set +u
        source .current_config.mk
        set -u

        safe_remove_under "${IMAGE_WORK_DIR}" "${IMAGE_WORK_DIR}/${FRIENDLYWRT_SRC}/${FRIENDLYWRT_ROOTFS}"
        safe_remove_under "${IMAGE_WORK_DIR}" "${IMAGE_WORK_DIR}/${FRIENDLYWRT_SRC}/${FRIENDLYWRT_PACKAGE_DIR}"

        tar xzf "${ROOTFS_TAR}"
        tar xzf "${HOST_PM_TAR}"
    )
}

compile_platform() {
    log "Compiling ${CPU} U-Boot and kernel"
    (
        cd "${IMAGE_WORK_DIR}"
        ./build.sh uboot
        ./build.sh kernel

        export PATH="/opt/FriendlyARM/toolchain/11.3-aarch64/bin:${PATH}"
        local kernel_release
        kernel_release="$(make -s -C kernel ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- kernelrelease)"
        log "Final kernel release: ${kernel_release}"

        bash "${SCRIPT_DIR}/scripts/3rd/add_openappfilter.sh"
    )
}

build_image() {
    log "Building final SD/eMMC image"
    (
        cd "${IMAGE_WORK_DIR}"
        ./build.sh sd-img

        [ -f "out/${IMG_FILE}" ] || die "final image not found: ${IMAGE_WORK_DIR}/out/${IMG_FILE}"
        cp -f "out/${IMG_FILE}" "${ARTIFACT_DIR}/${IMG_FILE}"

        [ -d "scripts/sd-fuse/${DIST_DIR}" ] || \
            die "image package directory not found: scripts/sd-fuse/${DIST_DIR}"
        tar czf "${ARTIFACT_DIR}/${TGZ_FILE}" \
            --transform="s|^${DIST_DIR}|${DIST_DIR}-${CPU}|" \
            -C scripts/sd-fuse "${DIST_DIR}"
    )

    gzip -f "${ARTIFACT_DIR}/${IMG_FILE}"
}

print_summary() {
    log "Build completed"
    printf 'Selection : VERSION=%s SET=%s CPU=%s\n' "${VERSION}" "${SET}" "${CPU}"
    printf 'Workspace : %s\n' "${WORK_ROOT}"
    printf 'Artifacts :\n'
    printf '  %s\n' "${ARTIFACT_DIR}/${IMG_FILE}.gz"
    printf '  %s\n' "${ARTIFACT_DIR}/${TGZ_FILE}"
}

main() {
    validate_selection "$@"
    check_host
    prepare_directories
    prepare_repo_tool

    log "Starting local single-target build: VERSION=${VERSION}, SET=${SET}, CPU=${CPU}, JOBS=${JOBS}"
    prepare_rootfs_sources
    prepare_rootfs_config
    compile_rootfs
    package_rootfs
    prepare_image_sources
    install_platform_toolchain
    unpack_rootfs_for_image
    compile_platform
    build_image
    print_summary
}

main "$@"
