#!/usr/bin/env bash
#
# 小米17 (pudding) 6.12.23-android16-5
# SukiSU 4.3.0 builtin + SUSFS + KPM
#
# 用法（Ubuntu / WSL2）：
#   bash build.sh
#
# 可覆盖：
#   WORK=~/xiaomi17-kbuild TC=~/toolchains JOBS=8 bash build.sh
#
# 产物：
#   $WORK/xiaomi17-sukisu-susfs-kpm.zip
#
# 说明：这是“把 README 里的命令串起来”的参考脚本，不是官方安装器。
# SUSFS patch 若出现 rejects，脚本会停下，需要按 .rej 手动合。

set -euo pipefail

WORK="${WORK:-$HOME/xiaomi17-kbuild}"
TC="${TC:-$HOME/toolchains}"
JOBS="${JOBS:-$(nproc)}"

TREE_REPO="https://github.com/cctv18/android_gki_kernel_common"
TREE_BRANCH="android16-6.12-2025-06"
TREE_COMMIT="9e91eb74a201e8cee839c8db6d642ff9b8408388"

KSU_REPO="https://github.com/SukiSU-Ultra/SukiSU-Ultra"
KSU_BRANCH="builtin"
KSU_COMMIT="b16e899a555e9b96aa1225f049cd7274820ca5b8"
KSU_VERSION="41100"

SUSFS_REPO="https://gitlab.com/simonpunk/susfs4ksu.git"
SUSFS_BRANCH="gki-android16-6.12"
SUSFS_COMMIT="6b60a305d418148bd311f4fc9bddedc82d99e1fc"
SUSFS_PATCH="kernel_patches/50_add_susfs_in_gki-android16-6.12.patch"

KPM_TAG="0.14.0"
KPM_BASE="https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/${KPM_TAG}"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

log "检查基础依赖"
for c in git curl unzip make python3 patch zip; do need "$c"; done
[ -n "${JOBS}" ] || die "JOBS 为空"

mkdir -p "$WORK" "$TC" "$WORK/tools"
cd "$WORK"

# ---------------------------------------------------------------------------
# 1. 工具链
# ---------------------------------------------------------------------------
log "准备工具链（clang r536225 + rust + build-tools）"
if [ ! -x "$TC/clang-r536225/bin/clang" ]; then
  mkdir -p "$TC"
  cd "$TC"
  base="https://github.com/cctv18/oneplus_sm8650_toolchain/releases/download/LLVM-Clang19-r536225"
  for z in clang-r536225.zip rust.zip build-tools.zip; do
    if [ ! -f "$z" ]; then
      curl -L --retry 3 -o "$z" "$base/$z"
    fi
    unzip -q -o "$z"
  done
fi

CLANG_DIR="$TC/clang-r536225"
[ -x "$CLANG_DIR/bin/clang" ] || die "找不到 $CLANG_DIR/bin/clang"

PAHOLE="$(find "$TC/build-tools" -type f -name pahole 2>/dev/null | head -n1 || true)"
[ -n "$PAHOLE" ] || die "找不到 build-tools 里的 pahole"

export PATH="$CLANG_DIR/bin:$TC/rust/bin:$(dirname "$PAHOLE"):$PATH"
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
export LIBCLANG_PATH="$CLANG_DIR/lib"
export PAHOLE
export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export KBUILD_GENDWARFKSYMS_STABLE=1

log "工具链版本"
clang --version | head -n1
"$PAHOLE" --version || true
rustc --version || warn "rustc 不可用，若 CONFIG_RUST=y 会失败"

# ---------------------------------------------------------------------------
# 2. 内核树
# ---------------------------------------------------------------------------
log "取内核树 $TREE_BRANCH"
if [ ! -d "$WORK/src/.git" ]; then
  cd "$WORK"
  git clone --depth=1 -b "$TREE_BRANCH" "$TREE_REPO" src
fi
cd "$WORK/src"

if [ "$(git rev-parse HEAD)" != "$TREE_COMMIT" ]; then
  git fetch --depth=1 origin "$TREE_COMMIT" || true
  git checkout "$TREE_COMMIT" || die "无法 checkout $TREE_COMMIT"
fi

[ "$(awk '/^SUBLEVEL/{print $3}' Makefile)" = "23" ] || die "SUBLEVEL 不是 23"
grep -q '^KMI_GENERATION=5$' build.config.constants || die "KMI_GENERATION 不是 5"
grep -q '^CLANG_VERSION=r536225$' build.config.constants || die "CLANG_VERSION 不是 r536225"
grep -q 'CONFIG_GKI_HACKS_TO_FIX=y' arch/arm64/configs/gki_defconfig || die "缺 GKI_HACKS_TO_FIX"
grep -q 'CONFIG_GCMA=y' arch/arm64/configs/gki_defconfig || die "缺 GCMA"

# ---------------------------------------------------------------------------
# 3. SukiSU builtin
# ---------------------------------------------------------------------------
log "取 SukiSU builtin @ $KSU_COMMIT"
if [ ! -d "$WORK/SukiSU/.git" ]; then
  cd "$WORK"
  git clone --depth=1 -b "$KSU_BRANCH" "$KSU_REPO" SukiSU
fi
cd "$WORK/SukiSU"
if [ "$(git rev-parse HEAD)" != "$KSU_COMMIT" ]; then
  git fetch --depth=1 origin "$KSU_COMMIT" || true
  git checkout "$KSU_COMMIT" || die "无法 checkout SukiSU $KSU_COMMIT"
fi

log "链接 SukiSU 到内核树"
cd "$WORK/src"
rm -rf drivers/kernelsu
ln -sfn "$WORK/SukiSU/kernel" drivers/kernelsu
grep -q 'kernelsu' drivers/Makefile || \
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig || \
  printf '\nsource "drivers/kernelsu/Kconfig"\n' >> drivers/Kconfig
readlink -f drivers/kernelsu | grep -q "$WORK/SukiSU/kernel" || die "drivers/kernelsu 链接不对"

# ---------------------------------------------------------------------------
# 4. SUSFS
# ---------------------------------------------------------------------------
log "取 SUSFS $SUSFS_BRANCH @ $SUSFS_COMMIT"
if [ ! -d "$WORK/susfs/.git" ]; then
  cd "$WORK"
  git clone --depth=1 -b "$SUSFS_BRANCH" "$SUSFS_REPO" susfs
fi
cd "$WORK/susfs"
if [ "$(git rev-parse HEAD)" != "$SUSFS_COMMIT" ]; then
  git fetch --depth=1 origin "$SUSFS_COMMIT" || true
  git checkout "$SUSFS_COMMIT" || die "无法 checkout SUSFS $SUSFS_COMMIT"
fi
[ -f "$SUSFS_PATCH" ] || die "找不到 $SUSFS_PATCH"

log "拷贝 SUSFS 源文件"
cd "$WORK/src"
cp "$WORK/susfs/kernel_patches/fs/susfs.c" fs/
cp "$WORK/susfs/kernel_patches/include/linux/susfs.h" include/linux/
cp "$WORK/susfs/kernel_patches/include/linux/susfs_def.h" include/linux/

log "打 SUSFS VFS 补丁"
if ! patch -p1 --batch --forward --fuzz=3 < "$WORK/susfs/$SUSFS_PATCH"; then
  echo
  echo "SUSFS patch 有 rejects。查看："
  find . -name '*.rej' -print
  echo "按 .rej 手动合完再重新运行脚本。"
  exit 1
fi

grep -q 'susfs.o' fs/Makefile || \
  printf '\nobj-$(CONFIG_KSU_SUSFS) += susfs.o\n' >> fs/Makefile

rm -f android/abi_gki_protected_exports_aarch64 \
      android/abi_gki_protected_exports_x86_64

# ---------------------------------------------------------------------------
# 5. 配置 fragment
# ---------------------------------------------------------------------------
log "写配置 fragment"
cat > arch/arm64/configs/xiaomi17_sukisu.config <<'EOF'
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
EOF

# ---------------------------------------------------------------------------
# 6. 生成配置
# ---------------------------------------------------------------------------
log "生成 .config"
rm -rf out
make O=out ARCH=arm64 LLVM=1 gki_defconfig

cp out/.config out/.config.gki
scripts/kconfig/merge_config.sh -m -O out out/.config.gki \
  arch/arm64/configs/xiaomi17_sukisu.config

make O=out ARCH=arm64 LLVM=1 olddefconfig
make O=out ARCH=arm64 LLVM=1 olddefconfig

log "设置版本串 -android16-5-4k"
./scripts/config --file out/.config --set-str LOCALVERSION "-android16-5-4k"
./scripts/config --file out/.config --disable LOCALVERSION_AUTO
sed -i 's|^[[:space:]]*echo "+"[[:space:]]*$|echo ""|' scripts/setlocalversion
sed -i "s|printf '%s' -dirty|printf '%s' ''|g" scripts/setlocalversion
make O=out ARCH=arm64 LLVM=1 olddefconfig

grep -q '^CONFIG_KSU=y' out/.config || die "CONFIG_KSU 没进 .config"
grep -q '^CONFIG_KSU_SUSFS=y' out/.config || die "CONFIG_KSU_SUSFS 没进 .config"
grep -q '^CONFIG_KPM=y' out/.config || die "CONFIG_KPM 没进 .config"
grep -q '^# CONFIG_STACK_TRACER is not set' out/.config || \
  warn "STACK_TRACER 不是 n，注意 struct module 尺寸"
grep -q '^# CONFIG_FUNCTION_TRACER is not set' out/.config || \
  warn "FUNCTION_TRACER 不是 n，注意 struct module 尺寸"

# ---------------------------------------------------------------------------
# 7. 编译
# ---------------------------------------------------------------------------
log "开始编译（约 30-60 分钟，取决于 CPU）"
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 -j"$JOBS" KSU_VERSION="$KSU_VERSION" \
  2>&1 | tee build.log

grep -q 'KPM is enabled' build.log || die "构建日志没有 KPM is enabled"
grep -q 'SUSFS_VERSION' build.log || die "构建日志没有 SUSFS_VERSION，SUSFS 没集成"
grep -q "SukiSU-Ultra version: $KSU_VERSION" build.log || \
  warn "KSU 版本不是 $KSU_VERSION，检查 build.log"

IMG="$WORK/src/out/arch/arm64/boot/Image"
[ -f "$IMG" ] || die "找不到 $IMG"
log "Image 版本串"
strings "$IMG" | grep -m1 'Linux version' || true

# ---------------------------------------------------------------------------
# 8. KPM 后处理
# ---------------------------------------------------------------------------
log "KPM: patch_linux $KPM_TAG"
cd "$WORK/tools"
for f in patch_linux kptools-linux kpimg; do
  [ -f "$f" ] || curl -L --retry 3 -o "$f" "$KPM_BASE/$f"
done
chmod +x patch_linux kptools-linux

cd "$WORK/src/out/arch/arm64/boot"
cp "$WORK/tools/patch_linux" .
cp "$WORK/tools/kptools-linux" ./kptools
cp "$WORK/tools/kpimg" .
chmod +x patch_linux kptools
./patch_linux || die "patch_linux 执行失败"

if [ ! -f oImage ]; then
  echo "patch_linux 没有生成 oImage，按它自己的 --help/输出处理"
  exit 1
fi
mv -f oImage Image

# ---------------------------------------------------------------------------
# 9. AnyKernel3
# ---------------------------------------------------------------------------
log "打包 AnyKernel3"
cd "$WORK"
if [ ! -d ak3/.git ]; then
  git clone --depth=1 https://github.com/osm0sis/AnyKernel3 ak3
fi
cp "$WORK/src/out/arch/arm64/boot/Image" ak3/Image

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

cd ak3
rm -f "$WORK/xiaomi17-sukisu-susfs-kpm.zip"
zip -r9 "$WORK/xiaomi17-sukisu-susfs-kpm.zip" * -x '.git/*'

log "完成"
ls -lh "$WORK/xiaomi17-sukisu-susfs-kpm.zip"
echo
echo "刷入前：备份 boot/init_boot/vbmeta，确认 BL 已解锁。"
echo "fastboot flash boot Image 或 recovery 刷 AK3 zip，只动 boot。"
