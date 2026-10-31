# 小米17 6.12.23 + SukiSU 4.3.0 + SUSFS + KPM 构建清单

> 目标设备：Xiaomi 17 `pudding`，HyperOS 3.0.x，内核 `6.12.23-android16-5-g316453da9a9e-abogki441133159-4k`
>
> 目标管理器：SukiSU Ultra `v4.3.0 (41100)`
>
> 目标内核：SukiSU 4.3.0 builtin + SUSFS + KPM，`boot` 分区，`init_boot` 保持原厂
>
> 构建机：x86_64 Linux / WSL2，建议 16 GB 内存、20 GB 磁盘

**这不是“下载一个包刷进去”的教程。** 你是在编一个带 root、SUSFS、KPM 的厂商适配 GKI 内核；第一次刷有变砖风险，先备份、先确认 BL 已解锁。

## 最快路径

不想手敲几十条命令，用这两个之一：

- **云端（推荐，不需要本地 Linux）**：把 `build.sh` 和 `.github/workflows/build.yml` 放进一个 GitHub 仓库，Actions 里手动运行 `build-xiaomi17-sukisu`，等 40–90 分钟，下载 artifact `xiaomi17-sukisu-susfs-kpm.zip`。
- **本地 Ubuntu / WSL2**：装好依赖后执行 `bash build.sh`，产物在 `~/xiaomi17-kbuild/xiaomi17-sukisu-susfs-kpm.zip`。

脚本仍会在 SUSFS patch 出现 rejects 时停下；那不是脚本能替你决定的，需要按 `.rej` 手动合。

---

## 0. 为什么是这套组合

| 组件 | 作用 | 为什么不能用现成的 |
|---|---|---|
| `cctv18/android_gki_kernel_common` 2025-06 | 带小米/高通适配层的 6.12.23 GKI 树 | AOSP 上游树在这台机器上卡第一屏 |
| SukiSU `builtin` | 内置 root，带 SUSFS/KPM 选项 | LKM 只加载 `kernelsu.ko`，改不了内核 |
| SUSFS `gki-android16-6.12` | VFS 层隐藏 | 必须打内核补丁 |
| KPM | SukiSU 的内核模块加载 | 必须 `CONFIG_KPM=y` + KernelPatch |

版本必须全部对齐到 **6.12.23 / KMI generation 5**。6.12.69 / `android16-6` 的内核不能刷到你这台机器上。

---

## 1. 版本锁定表

| 项 | 值 |
|---|---|
| 内核树 | `cctv18/android_gki_kernel_common` |
| 分支 | `android16-6.12-2025-06` |
| 树 HEAD | `9e91eb74a201e8cee839c8db6d642ff9b8408388` |
| SUBLEVEL | `23` |
| `KMI_GENERATION` | `5` |
| `CLANG_VERSION` | `r536225` |
| SukiSU | `builtin` @ `b16e899a555e9b96aa1225f049cd7274820ca5b8` |
| SUSFS | `gki-android16-6.12` @ `6b60a305d418148bd311f4fc9bddedc82d99e1fc` |
| KPM patch tool | `SukiSU_KernelPatch_patch` `0.14.0` |

SukiSU 的 builtin 提交 `b16e899a` 是 v4.3.0 发布后修复 clang GKI 构建的提交；不要用更早的 `0b666cad`，它在 clang GKI 上编不过。

---

## 2. 目录与工具链

```bash
export WORK="$HOME/xiaomi17-kbuild"
export TC="$HOME/toolchains"
mkdir -p "$WORK" "$TC"
```

工具链从 cctv18 的 release 取（clang 19 / r536225）：

```bash
cd "$TC"
base="https://github.com/cctv18/oneplus_sm8650_toolchain/releases/download/LLVM-Clang19-r536225"
curl -LO "$base/clang-r536225.zip"
curl -LO "$base/rust.zip"
curl -LO "$base/build-tools.zip"
unzip -q clang-r536225.zip
unzip -q rust.zip
unzip -q build-tools.zip
```

目录约定：

```text
$TC/clang-r536225/bin
$TC/rust/bin
$TC/build-tools/build-tools/bin     # pahole 在这里
```

环境变量：

```bash
export PATH="$TC/clang-r536225/bin:$TC/rust/bin:$TC/build-tools/build-tools/bin:$PATH"
export CC=clang
export LD=ld.lld
export AR=llvm-ar
export NM=llvm-nm
export OBJCOPY=llvm-objcopy
export OBJDUMP=llvm-objdump
export READELF=llvm-readelf
export STRIP=llvm-strip
export HOSTCC=clang
export HOSTCXX=clang++
export RUSTC=rustc
export BINDGEN=bindgen
export LIBCLANG_PATH="$TC/clang-r536225/lib"
export PAHOLE="$TC/build-tools/build-tools/bin/pahole"
export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export KBUILD_GENDWARFKSYMS_STABLE=1
```

自检：

```bash
clang --version | head -1          # 19.0.1 左右
pahole --version                    # 必须是 build-tools 里的
rustc --version                     # 1.82.0 左右
```

> `pahole` 不要用 Ubuntu 24.04 自带的 1.25，会在 `LD vmlinux` 后报 `FAILED: load BTF from vmlinux: Invalid argument`。

---

## 3. 取内核树

```bash
cd "$WORK"
git clone --depth=1 -b android16-6.12-2025-06 \
  https://github.com/cctv18/android_gki_kernel_common src
cd src
```

断言，任何一项不符就停：

```bash
test "$(git rev-parse HEAD)" = "9e91eb74a201e8cee839c8db6d642ff9b8408388"
awk '/^SUBLEVEL/{print $3}' Makefile                 # 23
grep -E '^KMI_GENERATION=5$' build.config.constants
grep -E '^CLANG_VERSION=r536225$' build.config.constants
grep -q 'CONFIG_GKI_HACKS_TO_FIX=y' arch/arm64/configs/gki_defconfig
grep -q 'CONFIG_GCMA=y' arch/arm64/configs/gki_defconfig
grep -q 'CONFIG_GKI_TASK_STRUCT_VENDOR_SIZE_MAX=1024' arch/arm64/configs/gki_defconfig
```

如果分支已经移动，`git checkout 9e91eb74...` 后再继续；不要用“最新的 2025-06”代替 pin。

---

## 4. 集成 SukiSU 4.3.0 builtin

```bash
cd "$WORK"
git clone https://github.com/SukiSU-Ultra/SukiSU-Ultra SukiSU
cd SukiSU
git checkout builtin
git checkout b16e899a555e9b96aa1225f049cd7274820ca5b8
git fetch origin main:main      # Makefile 用 main 的提交数算 KSU_VERSION
```

链接进内核：

```bash
cd "$WORK/src"
rm -rf drivers/kernelsu
ln -sfn "$WORK/SukiSU/kernel" drivers/kernelsu
grep -q 'kernelsu' drivers/Makefile || \
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig || \
  printf '\nsource "drivers/kernelsu/Kconfig"\n' >> drivers/Kconfig
```

检查：

```bash
readlink -f drivers/kernelsu        # 应该指向 $WORK/SukiSU/kernel
grep kernelsu drivers/Makefile
tail -5 drivers/Kconfig
```

> SukiSU 的 `setup.sh` 也能做这件事，但它会 checkout 分支最新提交；这里手动 pin 是为了版本可复现。

---

## 5. 集成 SUSFS

```bash
cd "$WORK"
git clone -b gki-android16-6.12 \
  https://gitlab.com/simonpunk/susfs4ksu.git susfs
cd susfs
git checkout 6b60a305d418148bd311f4fc9bddedc82d99e1fc
```

拷贝 SUSFS 源文件和头文件：

```bash
cd "$WORK/src"
cp "$WORK/susfs/kernel_patches/fs/susfs.c" fs/
cp "$WORK/susfs/kernel_patches/include/linux/susfs.h" include/linux/
cp "$WORK/susfs/kernel_patches/include/linux/susfs_def.h" include/linux/
```

打 VFS 补丁：

```bash
cd "$WORK/src"
patch -p1 --batch --forward --fuzz=3 \
  < "$WORK/susfs/kernel_patches/50_add_susfs_in_gki-android16-6.12.patch"
```

**不要**再打 `kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch`：SukiSU builtin 已经内置了 KSU 侧的 SUSFS 开关，重复打会冲突。

检查 `fs/Makefile` 是否有 `susfs.o`：

```bash
grep -q 'susfs.o' fs/Makefile || \
  printf '\nobj-$(CONFIG_KSU_SUSFS) += susfs.o\n' >> fs/Makefile
```

删除 protected exports（GKI 6.12 的 WiFi 等模块需要）：

```bash
rm -f android/abi_gki_protected_exports_aarch64 \
      android/abi_gki_protected_exports_x86_64
```

如果 `patch` 有 rejects：先看 `.rej` 是哪个文件，通常是 `fs/exec.c`、`fs/open.c`、`fs/stat.c`、`fs/namespace.c` 的上下文差异。**不要**带着 `.rej` 继续编；SUSFS 少了 hook 会“看起来编过了，但隐藏不生效”。

---

## 6. 配置 fragment

写入 `arch/arm64/configs/xiaomi17_sukisu.config`：

```text
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KPM=y
```

说明：

- `CONFIG_KSU_SUSFS_*` 全部是 builtin 的 Kconfig 选项；
- `CONFIG_KPM=y` 会 `select KALLSYMS` / `KALLSYMS_ALL`；
- 不要在这里加 `CONFIG_LOCALVERSION`，下一步单独处理。

---

## 7. 配置与版本串

```bash
cd "$WORK/src"
rm -rf out

make O=out ARCH=arm64 LLVM=1 gki_defconfig

# merge_config.sh 的输出就是 out/.config，先备份一份 base，避免读写同一个文件
cp out/.config out/.config.gki
scripts/kconfig/merge_config.sh -m -O out out/.config.gki \
  arch/arm64/configs/xiaomi17_sukisu.config

make O=out ARCH=arm64 LLVM=1 olddefconfig
make O=out ARCH=arm64 LLVM=1 olddefconfig
```

设置版本串，必须对齐原厂模块的 vermagic（`6.12.23-android16-5-4k`）：

```bash
./scripts/config --file out/.config --set-str LOCALVERSION "-android16-5-4k"
./scripts/config --file out/.config --disable LOCALVERSION_AUTO
```

压掉 `setlocalversion` 追加的 `+` / `-dirty`：

```bash
sed -i 's|^[[:space:]]*echo "+"[[:space:]]*$|echo ""|' scripts/setlocalversion
sed -i "s|printf '%s' -dirty|printf '%s' ''|g" scripts/setlocalversion
```

再跑一轮：

```bash
make O=out ARCH=arm64 LLVM=1 olddefconfig
grep '^CONFIG_LOCALVERSION' out/.config
# CONFIG_LOCALVERSION="-android16-5-4k"
```

配置自检：

```bash
for k in KSU KSU_SUSFS KPM GENDWARFKSYMS MODVERSIONS CFI_CLANG DEBUG_INFO_BTF; do
  grep -E "^(CONFIG_${k}=|# CONFIG_${k} is not set)" out/.config || echo "$k = <absent>"
done
grep -E '^# CONFIG_(FUNCTION_TRACER|STACK_TRACER) is not set' out/.config
```

`FUNCTION_TRACER` / `STACK_TRACER` 必须是 `n`；如果被 `select` 拉起来，先关 `STACK_TRACER`，再跑两轮 `olddefconfig`。这两个开了会让 `struct module` 尺寸变化，`msm_drm.ko` 拒载。

---

## 8. 编译

```bash
cd "$WORK/src"
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 -j"$(nproc)" KSU_VERSION=41100 \
  2>&1 | tee build.log
```

`KSU_VERSION=41100` 是为了和你的管理器 `v4.3.0 (41100)` 对齐。如果不想强制，去掉它，编完看日志里的 `-- SukiSU-Ultra version:`，再装同版本管理器。

日志里必须出现：

```text
-- SukiSU-Ultra version: 41100
-- KERNEL_VERSION: 6.12
-- KERNEL_TYPE: GKI 2.0
-- SukiSU-Ultra: using SUSFS_INLINE_HOOK
-- KPM is enabled
-- SUSFS_VERSION: v2.x
```

`SUSFS_VERSION` 没有打印，说明 `fs/susfs.c` 没进树或补丁没打对。

产物：

```text
out/arch/arm64/boot/Image
```

版本检查：

```bash
strings out/arch/arm64/boot/Image | grep -m1 'Linux version'
# 目标：6.12.23-android16-5-4k ...
```

---

## 9. KPM 后处理

只开 `CONFIG_KPM=y` 还不够，KPM 需要 KernelPatch 对 `Image` 做一次处理。

下载 `0.14.0` 的 `patch_linux`（以及同目录的 `kptools-linux`、`kpimg`）：

```bash
cd "$WORK"
mkdir -p tools
base="https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.14.0"
curl -LO "$base/patch_linux"
curl -LO "$base/kptools-linux"
curl -LO "$base/kpimg"
chmod +x patch_linux kptools-linux
```

在 `Image` 目录执行：

```bash
cd "$WORK/src/out/arch/arm64/boot"
cp "$WORK/tools/patch_linux" .
cp "$WORK/tools/kptools-linux" ./kptools
cp "$WORK/tools/kpimg" .
chmod +x patch_linux kptools
./patch_linux
```

按 0.14.0 的实际输出，通常会生成 `oImage`：

```bash
ls -l Image oImage 2>/dev/null
[ -f oImage ] && mv -f oImage Image
```

> 不同 KernelPatch 版本的命令可能略有差异；以 `./patch_linux --help` 和 release 说明为准。处理完再打包，顺序不能反。

---

## 10. 打包 AnyKernel3

```bash
cd "$WORK"
git clone --depth=1 https://github.com/osm0sis/AnyKernel3 ak3
cp src/out/arch/arm64/boot/Image ak3/Image
```

写 `ak3/anykernel.sh`：

```bash
cat > ak3/anykernel.sh <<'EOF'
kernel.string=SukiSU 4.3.0 + SUSFS + KPM (6.12.23-android16-5)
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1

device.name1=pudding
device.name2=canoe
device.name3=
device.name4=
device.name5=

supported.versions=
supported.patchlevels=

block=/dev/block/bootdevice/by-name/boot;
is_slot_device=1;
ramdisk=false;
EOF
```

说明：

- `device.name1=pudding`，`canoe` 是平台代号，留着兼容；
- `ramdisk=false`：小米17 的 `boot` 没有 ramdisk，ramdisk 在 `init_boot`；
- 只打包 `Image`，不要打包 `Image.gz`，除非你确认 AK3 走 gz 分支。

打包：

```bash
cd ak3
zip -r9 "$WORK/xiaomi17-sukisu-susfs-kpm.zip" * -x '.git/*'
```

---

## 11. 刷入

前提：BL 已解锁，已备份原厂 `boot.img` / `init_boot.img` / `vbmeta.img`。

```bash
adb reboot bootloader
fastboot getvar current-slot
```

当前槽是 `a`：

```bash
fastboot flash boot boot_a
fastboot reboot
```

当前槽是 `b`：

```bash
fastboot flash boot boot_b
fastboot reboot
```

也可以先解包 AK3 zip，取出里面的 `Image` 再：

```bash
fastboot flash boot Image
```

**不要** `fastboot flash boot xxx.zip`：fastboot 会把 zip 当成镜像写进去，直接坏分区。AK3 zip 留给 recovery / 内核管理器刷。

---

## 12. 刷后验证

```bash
adb shell getprop ro.product.device          # pudding
adb shell su -c 'cat /proc/version'          # 6.12.23-android16-5-4k ...
adb shell su -c id                           # uid=0(root)
```

管理器里检查：

- 内核版本显示 `6.12.23-android16-5-4k`；
- KSU 版本 `41100`；
- SUSFS 开关可见；
- KPM 页面可见。

SUSFS 工具：

```bash
adb shell su -c 'ksu_susfs --help'
```

没有 `ksu_susfs` 就安装 susfs4ksu 的用户态模块，或把编译出的 `ksu_susfs` 推到 `/data/adb/ksu/bin/`。

---

## 13. 失败处理

**SUSFS patch 失败**

看 `.rej`，通常是 6.12.23 与 2026-03 的上下文差异。先 `--fuzz=3`，还失败就按 `.rej` 手动合；不要跳过。

**编译报 `netlink_kernel_cfg` / `security_add_hooks`**

说明 SukiSU 代码不是最新 builtin。确认在 `b16e899a` 或更新；这是 6.12 API 变更，老提交编不过。

**编译报 BTF `Invalid argument`**

`pahole` 不对。用 `$TC/build-tools/build-tools/bin/pahole`，`export PAHOLE=...`，不要关 `CONFIG_DEBUG_INFO_BTF`。

**卡第一屏 / 循环重启**

先刷回原厂 `boot`：

```bash
fastboot flash boot stock_boot.img
```

`init_boot` 没动过就不用管；如果动过，也刷回原厂。

**管理器提示内核版本高于管理器**

你编出的 KSU 版本不是 41100。用 `KSU_VERSION=41100` 重编，或换同版本管理器。

**刷完没有 root**

检查 `CONFIG_KSU=y`、`drivers/kernelsu` 链接、`drivers/Makefile`、`drivers/Kconfig`；再看 `build.log` 里 `SukiSU-Ultra version` 是否打印。

---

## 14. 救砖底线

- 保留完整线刷包 / EDL；
- 保留原厂 `boot.img`、`init_boot.img`、`vbmeta.img`；
- 第一次刷之前确认 ARB（`fastboot getvar anti`）；
- 不要顺手 `fastboot --disable-verity --disable-verification flash vbmeta`，除非你确认是 AVB 校验导致的问题。

---

## 15. 参考

- 内核树：<https://github.com/cctv18/android_gki_kernel_common/tree/android16-6.12-2025-06>
- SukiSU 集成文档：<https://sukisu.org/zh/guide/how-to-integrate>
- SukiSU 4.3.0：<https://github.com/SukiSU-Ultra/SukiSU-Ultra/releases/tag/v4.3.0>
- SUSFS：<https://gitlab.com/simonpunk/susfs4ksu/-/tree/gki-android16-6.12>
- KPM patch：<https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/tag/0.14.0>
- 6.12.69 实机验证记录（构建方法可复用，版本号不可照抄）：<https://github.com/Ma6302/xiaomi17-kernel-skills>
