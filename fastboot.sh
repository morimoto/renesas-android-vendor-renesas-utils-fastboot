#!/bin/bash -e

. $(dirname $(readlink -f $0))/fastboot_functions.sh

BOOT_FIRST=false
BOOTLOADER=true
LEGACY_BL=false
RESETENV=true
OEMERASE=true
SLOT=a
PWD=`pwd`

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

if [ -n "$ANDROID_PRODUCT_OUT" ] ; then
    echo "ANDROID_PRODUCT_OUT is set. Using images from output dir: ${ANDROID_PRODUCT_OUT}"
    export FASTBOOT=${FASTBOOT-"${ANDROID_HOST_OUT}/bin/fastboot"}
    export PRODUCT_OUT=${PRODUCT_OUT-"${ANDROID_PRODUCT_OUT}"}
else
    echo "ANDROID_PRODUCT_OUT is not set. Using images from current dir ${PWD}"
    # Pre-packaged DB
    export PRODUCT_OUT=${PWD}
    export FASTBOOT="$PRODUCT_OUT/fastboot"
fi

# =============================================================================
# pre-run
# =============================================================================
# Verify fastboot program is available
# Verify user permission to run fastboot
# Verify fastboot detects a device, otherwise exit

if [ -n "${SERIAL}" ] ; then
    export FASTBOOT_SERIAL="${FASTBOOT} ${SERIAL}"
else
    export FASTBOOT_SERIAL="${FASTBOOT}"
fi

if [ -f ${FASTBOOT} ]; then
    fastboot_status=`${FASTBOOT_SERIAL} devices 2>&1`
    if [ `echo $fastboot_status | grep -wc "no permissions"` -gt 0 ]; then
        cat <<-EOF >&2
        -------------------------------------------
        Fastboot requires administrator permissions
        Please run the script as root or create a
        fastboot udev rule, e.g:
         % cat /etc/udev/rules.d/99_android.rules
            SUBSYSTEM=="usb",
            SYSFS{idVendor}=="0451"
            OWNER="<username>"
            GROUP="adm"
        -------------------------------------------
	EOF
        exit 1
    elif [ "X$fastboot_status" = "X" ]; then
        echo "No device detected. Please ensure that" \
             "fastboot is running on the target device"
        exit -1;
    else
        device=`echo $fastboot_status | awk '{print$1}'`
        echo -e "\nFastboot - device detected: $device\n"
    fi
else
    echo "Error: fastboot executable is not available at ${PRODUCT_OUT}"
    exit -1;
fi

# poll the board to find out its configuration
product=`${FASTBOOT_SERIAL} getvar product 2>&1 | grep product | awk '{print$2}'`
platform=`${FASTBOOT_SERIAL} getvar platform 2>&1 | grep platform | awk '{print$2}'`
revision=`${FASTBOOT_SERIAL} getvar revision 2>&1 | grep revision | awk '{print$2}'`

# Create the filename
dtboimg="${PRODUCT_OUT}/dtbo.img"
bootimg="${PRODUCT_OUT}/boot.img"
vbmetaimg="${PRODUCT_OUT}/vbmeta.img"
superimg="${PRODUCT_OUT}/super.img"
bootloaderimg="${PRODUCT_OUT}/bootloader.img"
bootparam="${PRODUCT_OUT}/bootparam_sa0.bin"
bl2="${PRODUCT_OUT}/bl2.bin"
cert="${PRODUCT_OUT}/cert_header_sa6.bin"
bl31="${PRODUCT_OUT}/bl31.bin"
tee="${PRODUCT_OUT}/tee.bin"
uboot="${PRODUCT_OUT}/u-boot.bin"
packipl="${PRODUCT_OUT}/pack_ipl"
platformtxt="${PRODUCT_OUT}/platform.txt"

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

if [[ $OEMERASE = false ]] ; then
    echo "**************** --noerase argument is set"
    echo "**************** Skipping operation of erasing secure storage"
else
    verify_cmd ${FASTBOOT_SERIAL} oem erase
    echo "Waiting 30 sec for erasing secure storage ..."
    sleep 3; wait_for_fastboot 30
fi

verify_cmd ${FASTBOOT_SERIAL} reboot fastboot
echo "Waiting 30 sec for fastbootd ..."
sleep 3; wait_for_fastboot 30

verify_cmd ${FASTBOOT_SERIAL} flash super ${superimg}

verify_cmd ${FASTBOOT_SERIAL} reboot bootloader
echo "Waiting 30 sec for fastboot ..."
sleep 3; wait_for_fastboot 30

verify_cmd ${FASTBOOT_SERIAL} format userdata
verify_cmd ${FASTBOOT_SERIAL} erase metadata

# Reboot now
verify_cmd ${FASTBOOT_SERIAL} reboot
echo "SUCCESS. Script finished successfully"
exit 0
