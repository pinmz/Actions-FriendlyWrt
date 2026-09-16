# 使用 GitHub Actions 编译 FriendlyWrt
[English](README_en.md)
### 基本信息 
- 用户名：root
- 密码：password
- 后台IP：192.168.2.1
- 固件下载地址： https://github.com/friendlyarm/Actions-FriendlyWrt/releases
- 更多使用说明: https://wiki.friendlyelec.com/wiki/index.php/Template:FriendlyWrt21/zh
### 固件文件说明
- XYZ.img.gz：固件镜像，可写入 SD 卡或 eMMC 启动。
- images-XYZ.tgz：升级包，仅供 "eMMC 刷机助手" 使用，不能直接写入 SD 卡启动。
### 如何刷入 eMMC
- 首次安装：先将 XYZ.img.gz 写入 SD 卡并启动系统，进入 FriendlyWrt 后台 → "系统" → "eMMC 刷机助手"，上传固件直接刷入（无需解压）。完成后弹出 SD 卡，设备会自动重启并从 eMMC 启动。
- 小版本升级（如 25.12.2 → 25.12.3）：在 "eMMC 刷机助手" 中刷入 images-XXYYZZ.tgz，可选择保留数据，但兼容性需自行评估。
- 大版本升级（如 24.10 → 25.12）：建议先[备份配置](https://openwrt.org/docs/guide-user/troubleshooting/backup_restore)，然后使用 XYZ.img.gz 全量安装，以避免兼容性问题。
### 本地主机单目标编译
根目录的 `cc_mybuild.sh` 用于在 x86_64 Linux 主机上编译单一组合，不会展开 GitHub Actions 的完整矩阵。先修改脚本开头的变量：

```bash
VERSION="25.12"
SET="docker"
CPU="rk3328"
JOBS="$(nproc)"
```

准备好与 GitHub Actions 相同的 FriendlyARM/Ubuntu 编译依赖后执行：

```bash
bash cc_mybuild.sh
```

脚本会分别建立 RootFS 和目标平台镜像工作区，编译 OpenAppFilter，并在 `artifact/<版本>-<类型>-<CPU>/` 下生成 `.img.gz` 和 `images-*.tgz`。中断后再次执行会复用 `.local-build/` 中的源码和编译缓存；如需完全重新同步源码，可删除对应组合的工作目录。

### 第三方软件包：OpenAppFilter
当前构建会从以下仓库按固定标签加入 OpenAppFilter：

```text
https://github.com/destan19/OpenAppFilter.git
Tag: v7.0.1
Commit: b88fcb082597486a816187ec1e02812082161d5e
```

该仓库属于多软件包源码集合，整体克隆到 `friendlywrt/package/OpenAppFilter`，包含：

- `luci-app-oaf`：LuCI 管理界面
- `appfilter`：用户空间服务
- `kmod-oaf`：内核模块

普通版和 Docker 版均通过以下配置将其内置到固件：

```text
CONFIG_PACKAGE_luci-app-oaf=y
CONFIG_PACKAGE_appfilter=y
CONFIG_PACKAGE_kmod-oaf=y
```

完整固件编译会自动包含 OpenAppFilter。单独调试软件包时，可在 FriendlyWrt 源码目录执行：

```bash
make tools/install toolchain/install -j$(nproc)
make package/oaf/compile -j$(nproc) V=s
make package/open-app-filter/compile -j$(nproc) V=s
make package/luci-app-oaf/compile -j$(nproc) V=s
```

由于本项目的 FriendlyWrt rootfs 会被多个 SoC 共用，而最终镜像会替换为各平台单独编译的 FriendlyELEC 内核模块，仅在 FriendlyWrt 源码树中编译 `kmod-oaf` 不能保证最终模块 ABI 匹配。工作流会在每个平台内核编译完成后再次运行：

```bash
bash ../scripts/3rd/add_openappfilter.sh
```

该脚本实质上使用以下方式针对最终内核重新编译并安装 `oaf.ko`：

```bash
make -C kernel \
  ARCH=arm64 \
  CROSS_COMPILE=aarch64-linux-gnu- \
  M="$(pwd)/openappfilter-kmod/oaf/src" \
  modules
```

源码与 rootfs 配置集成脚本位于 `scripts/add_packages.sh`；平台内核模块集成脚本位于 `scripts/3rd/add_openappfilter.sh`。GitHub Actions 会校验三个包已启用，并为每个 CPU 平台重新生成匹配内核的 `oaf.ko`。
### 更新说明
* 2026/08/07
    *  增加 NanoPi-R28S 支持
    *  修正 RTL8125 相关问题 [#130](https://github.com/friendlyarm/Actions-FriendlyWrt/issues/130)
* 2026/07/22
    *  更新RTL8125驱动, 提升2.5G网卡性能，降低待机功耗
* 2026/07/08
    *  更新到新版本 openwrt-25.12.5
* 2026/06/25
    *  新增对 NanoPC-T4 和 NanoPi-M4v2 板载 WiFi 的支持
* 2026/06/09
    *  RK33xx内核更新至6.6.134, 优化内核配置，修复重启后 USB 设备偶发无法工作的问题
    *  增加 NanoPi-M6V2 支持
* 2026/06/05
    *  更新到新版本 openwrt-25.12.4
* 2026/04/29
    *  更新到新版本 openwrt-25.12.2
    *  更新了"eMMC 刷机助手"，加强稳定性，支持更多格式
    *  内核启用内置fq_codel队列调度以改善网络延迟
* 2026/03/06
    *  增加 NanoPi-NEO3-Plus 支持
* 2025/12/31
    *  更新到新版本 openwrt-24.10.4
    *  RK35xx内核更新至6.1.141
* 2025/08/04
    *  RK35xx内核更新至6.1.118
* 2025/07/09
    *  增加 NanoPi-R76S 支持
    *  修复 PWM 风扇控制问题 (使用pwm-fan驱动模块)
* 2025/06/30
    *  更新到新版本 openwrt-24.10.2
    *  更新了内核网络部分的配置
* 2025/06/25
    *  增加 NanoPi-R3S-LTS 支持
* 2025/06/06
    *  增加 NanoPi-M5 支持
    *  增加 RTL8851BU 无线网卡的支持
* 2025/03/24
    *  修正opt分区inode过小的问题
    *  从eMMC启动时，为内存超1G设备重新启用eMMC刷机助手
* 2025/02/28
    *  更新到新版本 openwrt-24.10.0
    *  RK33xx内核更新至6.6.78+
    *  调整分区：固定根分区大小，增加独立分区以提升 Docker 存储性能，恢复出厂设置后该分区数据仍会得到保留
* 2025/02/11
    *  RK35xx内核更新至6.1.99
* 2024/12/09
    *  修正luci-app-diskman插件的显示问题 (thanks [helmx](https://github.com/helmx))
* 2024/10/16
    *  更新到新版本 openwrt-23.05.5
    *  增加 NanoPi-Zero2 支持
* 2024/09/14 增加NanoPi-R3S支持
* 2024/08/30
    *  更新到新版本 openwrt-23.05.4
    *  增加 NanoPi-M6 支持
* 2024/07/03
    *  修复因固件丢失而导致的WIFI问题
* 2024/06/06
    *  RK35xx内核更新至6.1.57
* 2024/03/29
    *  更新到新版本 openwrt-23.05.3
* 2024/02/02
    *  为模块rtl8822ce增加无线中继模式的支持,[设置方法](https://wiki.friendlyelec.com/wiki/index.php/NanoPi_R5C/zh#.E6.97.A0.E7.BA.BF.E4.B8.AD.E7.BB.A7.E6.A8.A1.E5.BC.8F)
* 2023/12/22
    *  更新到新版本 openwrt-23.05.2
    *  修正eMMC刷机工具对大容量eMMC的兼容性问题
* 2023/10/31
    *  更新到新版本 openwrt-23.05.0
    *  内核更新至6.1
* 2023/07/04
    *  内核更新至5.10.160 (rk3568/rk3588)
* 2023/06/10
    *  增加 MediaTek MT7921 无线网卡的支持
* 2023/05/31
    *  增加 NanoPC-T6 支持
    *  更新 v22.03 到新版本 openwrt-22.03.5
    *  更新 v21.02 到新版本 openwrt-21.02.7
* 2023/04/26
    *  增加 R5C-2GB 支持
    *  更新 v22.03 到新版本 openwrt-22.03.4
    *  更新 v21.02 到新版本 openwrt-21.02.6
* 2023/03/15
    *  增加R6C支持
    *  更新initramfs,[可禁用OverlayFS或者创建额外的分区](https://wiki.friendlyelec.com/wiki/index.php/How_to_use_overlayfs_on_Linux/zh)
* 2023/03/01
    *  更新到新版本 openwrt-22.03.3
    *  为rk3568/rk3588的5.10内核增加ntfs3驱动
    *  更新内核小版本
    *  更新网卡驱动
* 2022/12/04
    *  增加R5C支持
    *  修正存储空间某些情况下无法扩展的问题
    *  加强eMMC刷机工具的刷机稳定性
* 2022/11/24
    *  修正R6S 1G网口不可用问题  
    *  eMMC刷机工具现可以在eMMC启动时使用  
* 2022/11/01 增加R6S支持
* 2022/10/09 首次发布
### Thanks / 致谢
- [luci-app-diskman](https://github.com/lisaac/luci-app-diskman)
- [luci-theme-argon](https://github.com/jerrykuku/luci-theme-argon)
- [P3TERX](https://github.com/P3TERX/Actions-OpenWrt)
- [NanoPi-R1S-Build-By-Actions](https://github.com/skytotwo/NanoPi-R1S-Build-By-Actions)
- [QiuSimons](https://github.com/QiuSimons/YAOF)
