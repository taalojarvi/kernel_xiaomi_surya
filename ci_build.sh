#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Automation script for Building Kernels on Github Actions

# Download latest Neutron clang from their repos.
mkdir -p Neutron/
curl -s https://api.github.com/repos/Neutron-Toolchains/clang-build-catalogue/releases/latest \
| grep "browser_download_url.*tar.zst" \
| cut -d : -f 2,3 \
| tr -d \" \
| wget --output-document=Neutron.tar.zst -qi -

tar -xf Neutron.tar.zst -C Neutron/ || exit 1

# Clone dependant repositories
# git clone --depth 1 -b gcc-master https://github.com/mvaisakh/gcc-arm64.git gcc-arm64
# git clone --depth 1 -b gcc-master https://github.com/mvaisakh/gcc-arm.git gcc-arm
git clone --depth 1 -b surya https://github.com/sunscape-stuff/AnyKernel3 || exit 1

# Workaround for safe.directory permission fix
git config --global safe.directory "$GITHUB_WORKSPACE"
git config --global safe.directory /github/workspace
git config --global --add safe.directory /__w/kernel_xiaomi_surya/kernel_xiaomi_surya

# Export Environment Variables.
export DATE=$(date +"%d-%m-%Y-%I-%M")
export PATH="$(pwd)/Neutron/bin:$PATH"
# export PATH="$TC_DIR/bin:$HOME/gcc-arm/bin${PATH}"
export CLANG_TRIPLE=aarch64-linux-gnu-
export ARCH=arm64
# export CROSS_COMPILE=$(pwd)/gcc-arm64/bin/aarch64-elf-
# export CROSS_COMPILE_ARM32=$(pwd)/gcc-arm/bin/arm-eabi-
export CROSS_COMPILE=aarch64-linux-gnu-
# export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
# export CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
export LD_LIBRARY_PATH=$TC_DIR/lib
export KBUILD_BUILD_USER="David112x"
export KBUILD_BUILD_HOST="github.com"
export USE_HOST_LEX=yes
export KERNEL_IMG=out/arch/arm64/boot/Image
export KERNEL_DTBO=out/arch/arm64/boot/dtbo.img
export KERNEL_DTB=out/arch/arm64/boot/dts/qcom/sdmmagpie.dtb
export DEFCONFIG=surya_defconfig
export ANYKERNEL_DIR=$(pwd)/AnyKernel3/
export BUILD_ID=$((GITHUB_RUN_NUMBER + 199))
export PATH="/usr/lib/ccache:/usr/local/opt/ccache/libexec:$PATH"
export SYSMEM="$(($(vmstat -s | grep -i 'total memory' | sed 's/ *//' | sed 's/total//g;s/memory//g;s/K//g;s/  / /g') / 1000))"
export GITBRNCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$(cat /sys/devices/system/cpu/smt/active)" = "1" ]; then
		export THREADS=$(($(nproc --all) * 2))
	else
		export THREADS=$(nproc --all)
	fi

# Telegram API Stuff
BUILD_START=$(date +"%s")
KBUILD_COMPILER_STRING=$("$TC_DIR"/bin/clang --version | head -n 1 | perl -pe 's/\(http.*?\)//gs' | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')
BOT_MSG_URL="https://api.telegram.org/bot$token/sendMessage"
BOT_BUILD_URL="https://api.telegram.org/bot$token/sendDocument"
CHATID=-1002079649530
COMMIT_HEAD=$(git log --oneline -1)
TERM=xterm

tg_post_msg() {
	curl -s -X POST "$BOT_MSG_URL" -d chat_id="$CHATID" \
	-d "disable_web_page_preview=true" \
	-d "parse_mode=html" \
	-d text="$1"

}

tg_post_build() {
	#Post MD5Checksum alongwith for easeness
	MD5CHECK=$(md5sum "$1" | cut -d' ' -f1)

	#Show the Checksum alongwith caption
	curl --progress-bar -F document=@"$1" "$BOT_BUILD_URL" \
	-F chat_id="$CHATID"  \
	-F "disable_web_page_preview=true" \
	-F "parse_mode=Markdown" \
	-F caption="$2 | *MD5 Checksum : *\`$MD5CHECK\`"
}

if [[ "$GITHUB_ACTIONS" =~ true ]]; then
 	echo -e "GitHub Actions runner detected. Switching to Full LTO"
  	sed -i 's/CONFIG_THINLTO=y/# CONFIG_THINLTO is not set/' arch/arm64/configs/surya_defconfig
else
  	echo -e "Skipping patch: $patch_file"
 fi

# Make defconfig
# make $DEFCONFIG LD=aarch64-elf-ld.lld O=out/
make $DEFCONFIG -j$THREADS CC=clang LD=ld.lld AS=llvm-as AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip O=out

# Make Kernel
echo The system has $SYSMEM MB of total memory.
echo Using $THREADS jobs for this build...
echo Building branch: $GITBRNCH
tg_post_msg "<b>Build Started on Github Actions</b>%0A<b>Branch: </b><code>$GITBRNCH</code>%0A<b>Build ID: </b><code>"$BUILD_ID"</code>%0A<b>Date : </b><code>$(TZ=Etc/UTC date)</code>%0A<b>Top Commit : </b><code>$COMMIT_HEAD</code>%0A"
# make -j$THREADS LD=ld.lld O=out/
make -j$THREADS CC='ccache clang -Qunused-arguments -fcolor-diagnostics' LLVM=1 LD=ld.lld LLVM_IAS=1 AS=llvm-as AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip O=out/

# Check if Image exists. If not, stop executing.
if ! [ -a $KERNEL_IMG ];
  then
    echo "An error has occured during compilation. Please check your code."
    tg_post_msg "<b>An error has occured during compilation. Build has failed</b>%0A"
    exit 1
  fi

# Make Flashable Zip
cp "$KERNEL_IMG" "$ANYKERNEL_DIR"
cp "$KERNEL_DTB" "$ANYKERNEL_DIR"/dtb 
cp "$KERNEL_DTBO" "$ANYKERNEL_DIR" 
cd AnyKernel3
zip -r9 UPDATE-AnyKernel3.zip * -x README.md LICENSE UPDATE-AnyKernel3.zip zipsigner.jar
cp UPDATE-AnyKernel3.zip package.zip 
curl -sLo zipsigner-3.0.jar https://github.com/Magisk-Modules-Repo/zipsigner/raw/master/bin/zipsigner-3.0-dexed.jar
java -jar zipsigner-3.0.jar UPDATE-AnyKernel3.zip Sunscape-$GITBRNCH-$BUILD_ID.zip
BUILD_END=$(date +"%s")
DIFF=$((BUILD_END - BUILD_START))
tg_post_build "Sunscape-$GITBRNCH-$BUILD_ID.zip" "Build took : $((DIFF / 60)) minute(s) and $((DIFF % 60)) second(s)"
