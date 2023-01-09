#!/bin/bash
set -eo pipefail

# Default to S
ver="${1:-s}"
[[ $# -ge 1 ]] && shift 1
if [[ $# -ge 0 ]]; then
  armbian_extra_flags=("$@")
  echo "Passing additional args to Armbian ${armbian_extra_flags[*]}"
else
  armbian_extra_flags=("")
fi

C=$(pwd)
A=../../armbian
T="rockpi-${ver}"
P="rockpi${ver}"
B="edge"
# Make sure we grab the right version
ARMBIAN_VERSION=$(cat ${A}/VERSION)

# Custom patches
echo "Adding custom patches"
ls "${C}/patches/"
mkdir -p ${A}/userpatches/kernel/media-current/
cp "${C}/patches/"*.patch "${A}"/userpatches/kernel/media-current/

# Custom kernel Config
echo "Copy custom Kernel config"
ls "${C}/kernel-config/"*.config
cp "${C}/kernel-config/"*.config "${A}"/userpatches/

# Select specific Kernel and/or U-Boot version
rm -rf "${A}"/userpatches/lib.config
if [ -e "${C}/kernel-ver/${P}"*.config ]
then
  echo "Copy specific kernel/uboot version config"
  cp "${C}/kernel-ver/${P}"*.config "${A}"/userpatches/lib.config
fi

cd ${A}
ARMBIAN_HASH=$(git rev-parse --short HEAD)
echo "Building for RockPi-${ver} -- with Armbian ${ARMBIAN_VERSION} -- $B"

./compile.sh docker KERNEL_ONLY=yes BOARD="${T}" BRANCH=${B} RELEASE=buster KERNEL_CONFIGURE=no EXTERNAL=yes BUILD_KSRC=no BUILD_DESKTOP=no "${armbian_extra_flags[@]}"

echo "Done!"

cd "${C}"
echo "Creating platform ${P} files"
[[ -d ${P} ]] && rm -rf "${P}"
mkdir -p "${P}/u-boot"
mkdir -p "${P}/lib/firmware"
mkdir -p "${P}"/boot/overlay-user
# Keep a copy for later just in case
cp "${A}/output/debs/linux-headers-${B}-rockchip64_${ARMBIAN_VERSION}"_* "${C}"

dpkg-deb -x "${A}/output/debs/linux-dtb-${B}-rockchip64_${ARMBIAN_VERSION}"_* "${P}"
dpkg-deb -x "${A}/output/debs/linux-image-${B}-rockchip64_${ARMBIAN_VERSION}"_* "${P}"
dpkg-deb -x "${A}/output/debs/linux-u-boot-${B}-${T}_${ARMBIAN_VERSION}"_* "${P}"
dpkg-deb -x "${A}/output/debs/armbian-firmware_${ARMBIAN_VERSION}"_* "${P}"

# Copy bootloader stuff
cp "${P}"/usr/lib/linux-u-boot-${B}-*/uboot.img "${P}/u-boot"
cp "${P}"/usr/lib/linux-u-boot-${B}-*/trust.bin "${P}/u-boot"
cp "${P}"/usr/lib/linux-u-boot-${B}-*/idbloader.bin "${P}/u-boot"

mv "${P}"/boot/dtb* "${P}"/boot/dtb
mv "${P}"/boot/vmlinuz* "${P}"/boot/Image

# Clean up unneeded parts
rm -rf "${P}/lib/firmware/.git"
rm -rf "${P:?}/usr" "${P:?}/etc"

# Compile and copy over overlay(s) files
for dts in "${C}"/overlay-user/overlays-"${P}"/*.dts; do
  dts_file=${dts%%.*}
  if [ -s "${dts_file}.dts" ]
  then
    echo "Compiling ${dts_file}"
    dtc -O dtb -o "${dts_file}.dtbo" "${dts_file}.dts"
    cp "${dts_file}.dtbo" "${P}"/boot/overlay-user
  fi
done

if [ ${ver} = "s" ]
then
  cp "${A}"/config/bootscripts/boot-rockpis.cmd "${P}"/boot/boot.cmd
  echo "Changing debug UART baudrate to 115200, ${P}"
  sed -i "s/ttyS0,1500000/ttyS0,115200/g" "${P}"/boot/boot.cmd
else
  cp "${A}"/config/bootscripts/boot-rockchip64.cmd "${P}"/boot/boot.cmd
  echo "Changing debug UART baudrate to 115200, other"
  sed -i "s/ttyS2,1500000/ttyS2,115200/g" "${P}"/boot/boot.cmd
fi

touch "${P}"/boot/.next # Signal mainline kernel
mkimage -C none -A arm -T script -d "${P}"/boot/boot.cmd "${P}"/boot/boot.scr


# Prepare boot parameters
cp "${C}"/bootparams/"${P}".armbianEnv.txt "${P}"/boot/armbianEnv.txt

echo "Creating device tarball.."
tar cJf "${P}_${B}.tar.xz" "$P"

echo "Renaming tarball for Build scripts to pick things up"
mv "${P}_${B}.tar.xz" "${P}.tar.xz"
KERNEL_VERSION="$(basename ./"${P}"/boot/config-*)"
KERNEL_VERSION=${KERNEL_VERSION#*-}
echo "Creating a version file Kernel: ${KERNEL_VERSION}"
cat <<EOF >"${C}/version"
BUILD_DATE=$(date +"%m-%d-%Y")
ARMBIAN_VERSION=${ARMBIAN_VERSION}
ARMBIAN_HASH=${ARMBIAN_HASH}
KERNEL_VERSION=${KERNEL_VERSION}
EOF

echo "Cleaning up.."
rm -rf "${P}"
