#!/bin/bash -e

BOOT_FIRST=false
BOOTLOADER=true
HYPER_BL2=false
LEGACY_BL=false
BOOTSTRAP=true
RESETENV=true
OEMERASE=true
SLOT=a
PWD=`pwd`
FLASH_BL2_EXIT=false
DATA="/data/media"
HYPER_CA="hyper_ca_legacy"

if [ -n "$ANDROID_PRODUCT_OUT" ] ; then
    echo "ANDROID_PRODUCT_OUT is set. Using images from output dir: ${ANDROID_PRODUCT_OUT}"
    export FASTBOOT=${FASTBOOT-"${ANDROID_HOST_OUT}/bin/fastboot"}
    export COMMON_DIR="${ANDROID_BUILD_TOP}/device/renesas/common"
    export ADB=${ADB-"${ANDROID_HOST_OUT}/bin/adb"}
    export PRODUCT_OUT=${PRODUCT_OUT-"${ANDROID_PRODUCT_OUT}"}
    export MAKEFS=${FASTBOOT-"${ANDROID_HOST_OUT}/bin/mke2fs"}
else
    echo "ANDROID_PRODUCT_OUT is not set. Using images from current dir ${PWD}"
    # Pre-packaged DB
    export PRODUCT_OUT=${PWD}
    export COMMON_DIR="."
    export ADB="$PRODUCT_OUT/adb"
    export FASTBOOT="$PRODUCT_OUT/fastboot"
    export MAKEFS="$PRODUCT_OUT/mke2fs"
fi

# Create the filename
dtboimg="${PRODUCT_OUT}/dtbo.img"
bootimg="${PRODUCT_OUT}/boot.img"
vbmetaimg="${PRODUCT_OUT}/vbmeta.img"
superimg="${PRODUCT_OUT}/super.img"
systemimg="${PRODUCT_OUT}/system.img"
vendorimg="${PRODUCT_OUT}/vendor.img"
productimg="${PRODUCT_OUT}/product.img"
userdataimg="${PRODUCT_OUT}/userdata.img"
odmimg="${PRODUCT_OUT}/odm.img"
bootloaderimg="${PRODUCT_OUT}/bootloader.img"
bootparam="${PRODUCT_OUT}/bootparam_sa0.bin"
bl2="${PRODUCT_OUT}/bl2.bin"
cert="${PRODUCT_OUT}/cert_header_sa6.bin"
bl31="${PRODUCT_OUT}/bl31.bin"
tee="${PRODUCT_OUT}/tee.bin"
uboot="${PRODUCT_OUT}/u-boot.bin"
packipl="${PRODUCT_OUT}/pack_ipl"
platformtxt="${PRODUCT_OUT}/platform.txt"

usage ()
{
    echo "Usage: %fastboot.sh [--nobl --slot=<a or b>]"
    echo "options:"
    echo "  --nobl Don't flash bootloader"
    echo "  --slot=<a or b> Select specified slot for flashing"
    echo "  --serial=0000 Flashing device serial number"
    echo "  --noerase Don't erase Secure Storage"
    echo "  --noresetenv Don't reset u-boot environments"
    echo "  --boot_first Flash boot dtb and vbmeta before IPL update"
    echo "  --legacy_bl Use legacy mechanism for flashing bootloaders to HyperFlash via recovery"
    echo "  --flash_bl2 (Right before that script finished its work) BL2 will be uploaded/flashed"
    echo "  --fbl2_exit Flash/Update BL2 only and exit"
    echo "  --nobootstrap Don't use bootstrapping (flashing 'super.img'), as it will flash _a slot"

    exit 1;
}

for i in "$@"
do
case $i in
    --serial=*)
    SERIAL="-s ${i#*=}"
    shift
    ;;
    --slot=*)
    SLOT="${i#*=}"
    shift
    ;;
    --nobl)
    BOOTLOADER=false
    shift
    ;;
    --flash_bl2)
    HYPER_BL2=true
    shift
    ;;
    -h|--help)
    usage
    shift
    ;;
    --noresetenv)
    RESETENV=false
    shift
    ;;
    --noerase)
    OEMERASE=false
    shift
    ;;
    --boot_first)
    BOOT_FIRST=true
    shift
    ;;
    --legacy_bl)
    LEGACY_BL=true
    shift
    ;;
    --fbl2_exit)
    FLASH_BL2_EXIT=true
    shift
    ;;
    --nobootstrap)
    BOOTSTRAP=false
    shift
    ;;

    *)
    echo "Unknown option: ${i}"
    exit -1;
    ;;
esac
done

if [ -z "$SLOT" ] ; then
    echo
    echo "ERROR: slot is not set"
    echo
    exit -1;
fi

. $(dirname $(readlink -f $0))/fastboot_functions.sh

if [[ ${FLASH_BL2_EXIT} = true ]]; then
    verify_file ${bl2}
    adb_wait_device
    flash_bootloader_only_bl2
    exit 0;
fi

# =============================================================================
# pre-run
# =============================================================================
# Verify fastboot program is available
# Verify user permission to run fastboot
# Verify fastboot detects a device, otherwise exit

if [ -n "${SERIAL}" ] ; then
    export FASTBOOT_SERIAL="${FASTBOOT} ${SERIAL}"
    export ADB_SERIAL="${ADB} ${SERIAL}"
else
    export FASTBOOT_SERIAL="${FASTBOOT}"
    export ADB_SERIAL="${ADB}"
fi

fastboot_check || result=$?
if [[ "$result" == 1 ]]; then
    echo "Trying to reboot using adb"
    adb_reboot
    sleep 5
    fastboot_check
elif [[ ! -z "$result" && "$result" != 0  ]]; then
    exit -1
fi

# poll the board to find out its configuration
product=`${FASTBOOT_SERIAL} getvar product 2>&1 | grep product | awk '{print$2}'`
platform=`${FASTBOOT_SERIAL} getvar platform 2>&1 | grep platform | awk '{print$2}'`
revision=`${FASTBOOT_SERIAL} getvar revision 2>&1 | grep revision | awk '{print$2}'`

# Verify that all the files required for the fastboot flash
# process are available
echo "Product...: $product"
echo "Platform..: $platform-$revision"
echo "Slot......: $SLOT"
echo "fastboot..: $FASTBOOT"
echo

if [ -f "${platformtxt}" ]; then
    platformfromtxt=`cat ${platformtxt}`
    if [ ${platformfromtxt} != ${platform} ]; then
        echo "ERROR: Invalid target device platform ${platform}. Current binaries for ${platformfromtxt}"
        echo
        exit -1;
    fi
fi

verify_file ${dtboimg}
verify_file ${bootimg}
verify_file ${vbmetaimg}
verify_file ${superimg}

# =============================================================================
# end pre-run
# =============================================================================

# Select slot before flashing
verify_cmd ${FASTBOOT_SERIAL} --set-active=${SLOT}

# Before BL flash, must be reflashed boot.img, DTB and vbmeta
if [[ $BOOT_FIRST = true ]] ; then
    verify_cmd ${FASTBOOT_SERIAL} flash boot ${bootimg}
    verify_cmd ${FASTBOOT_SERIAL} flash vbmeta ${vbmetaimg}
else
    echo "--boot_first is not specified - skipping boot and adb flashing.."
fi

####################bootloader section start
flash_bootloader_fastboot
####################bootloader section end

echo "Flash Android partitions"

verify_cmd ${FASTBOOT_SERIAL} --set-active=${SLOT}
verify_cmd ${FASTBOOT_SERIAL} flash dtbo ${dtboimg}
verify_cmd ${FASTBOOT_SERIAL} flash boot ${bootimg}
verify_cmd ${FASTBOOT_SERIAL} flash vbmeta ${vbmetaimg}

verify_cmd ${FASTBOOT_SERIAL} reboot fastboot
echo "Waiting 30 sec for fastbootd ..."
sleep 3; wait_for_fastboot 30

if [[ $OEMERASE = false ]] ; then
    echo "**************** --noerase argument is set"
    echo "**************** Skipping operation of erasing secure storage"
else
    verify_cmd ${FASTBOOT_SERIAL} oem erase
    echo "Waiting 30 sec for erasing secure storage ..."
    sleep 3; wait_for_fastboot 30
fi

# For A/B devices, super partition always contains sub-partitions in
# the _a slot, because this image should only be used for
# bootstrapping / initializing the device. When flashing the image,
# bootloader fastboot should always mark _a slot as bootable.

if [[ $BOOTSTRAP = true ]] || [[ $SLOT == "a" ]] ; then
    verify_cmd ${FASTBOOT_SERIAL} flash super ${superimg}
fi

if [ -f ${userdataimg} ]; then
#Flash userdata image if available or just format partition otherwise
    echo "**************** flash userdata =="
    verify_cmd ${FASTBOOT_SERIAL} flash userdata ${userdataimg}
else
    echo "**************** format userdata =="
    if [ -f "${MAKEFS}" ] ; then
	verify_cmd ${FASTBOOT_SERIAL} format userdata
    else
	echo "Error: mke2fs is not available at ${MAKEFS}"
	exit -1;
    fi
fi

# Only for slot _b we need to flash rest dynamic partitions manually
if [[ $SLOT == "b" ]] ; then
    verify_file ${systemimg}
    verify_file ${vendorimg}
    verify_file ${productimg}
    verify_file ${odmimg}

    verify_cmd ${FASTBOOT_SERIAL} flash system ${systemimg}
    verify_cmd ${FASTBOOT_SERIAL} flash vendor ${vendorimg}
    verify_cmd ${FASTBOOT_SERIAL} flash product ${productimg}
    verify_cmd ${FASTBOOT_SERIAL} flash odm ${odmimg}
fi

verify_cmd ${FASTBOOT_SERIAL} reboot bootloader
echo "Waiting 30 sec for fastboot ..."
sleep 3; wait_for_fastboot 30

verify_cmd ${FASTBOOT_SERIAL} format userdata
verify_cmd ${FASTBOOT_SERIAL} erase metadata

# Reboot now
verify_cmd ${FASTBOOT_SERIAL} reboot

# Update BL2 on HyperFlash
if [[ ${HYPER_BL2} = true ]]; then
    adb_wait_device
    flash_bootloader_only_bl2
fi

echo "SUCCESS. Script finished successfully"
exit 0

