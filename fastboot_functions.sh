verify_cmd ()
{
    $@
    result=$?
    cmd=$@
    if [ $result != 0 ]; then
        echo "ERROR. Last command [$cmd] finished with result [$result]"
        exit $result
    else
        echo "SUCCESS. Last command [$cmd] finished with result [$result]"
    fi
}

fastboot_check()
{
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
        return -1
        elif [ "X$fastboot_status" = "X" ]; then
            echo "No device detected. Please ensure that" \
                 "fastboot is running on the target device"
            return 1;
        else
            device=`echo $fastboot_status | awk '{print$1}'`
            echo -e "\nFastboot - device detected: $device\n"
            return 0
        fi
    else
        echo "Error: fastboot executable is not available at ${PRODUCT_OUT}"
        return -1;
    fi
}

adb_reboot()
{
    if [ ! -f ${ADB} ]; then
        echo "Error: adb is not available at ${ADB}" >&2
        exit -1;
    fi

    A=$(${ADB_SERIAL} devices | grep -P "\d+\W+device" || :)
    if [ "$A" = "" ]; then
        echo "No adb devices found"
        return -1
    else
        echo "Rebooting via ADB..."
        ${ADB_SERIAL} reboot bootloader
        return 0
    fi
}

adb_wait_device()
{
    if [ ! -f ${ADB} ]; then
        echo "Error: adb is not available at ${ADB}" >&2
        exit -1;
    fi

    verify_cmd ${ADB} wait-for-device

    A=$(${ADB} shell getprop sys.boot_completed | tr -d '\r')
    while [ "$A" != "1" ]; do
        sleep 1
        A=$(${ADB} shell getprop sys.boot_completed | tr -d '\r')
    done
}

wait_for_fastboot ()
{
    time_wait=""

    if [ "$1" = "" ]; then
        time_wait=30;
    else
        if [[ $1 =~ ^[1-9][0-9]*$ ]] ; then
            time_wait=$1;
        else
            time_wait=30;
        fi
    fi

    printf "\nWaiting for device about $time_wait sec: "
    for (( i=time_wait; i > 0; i-- ))
    do
        if [ -f ${FASTBOOT} ]; then

            fastboot_status=$(${FASTBOOT_SERIAL} devices 2>/dev/null)
            result=$?

            if [ $result != 0 ]; then
                echo "ERROR. fastboot status finished with result [$result]"
                exit $result
            fi

            if [ "X$fastboot_status" = "X" ]; then
                printf ".";
            else
                device=`echo $fastboot_status | awk '{print$1}'`
                echo -e "\nFastboot - device detected: $device\n"
                return 0;
            fi
        else
            echo "Error: fastboot executable is not available at ${PRODUCT_OUT}"
            exit -1;
        fi

        sleep 1;
    done

    echo ""
    echo "Warning: Please ensure that fastboot is running on the"\
         "target device. Wait time is up"
    return 1;
}

soft_verify_file ()
{
    if [ ! -f "$*" ]; then
        echo "WARNING. File [$*] not found"
        return 1
    else
        echo "SUCCESS. File [$*] found"
        return 0
    fi
}

verify_file ()
{
    if [ ! -f "$*" ]; then
        echo "ERROR. File [$*] not found"
        exit 1
    else
        echo "SUCCESS. File [$*] found"
    fi
}

flash_bootloader_fastboot ()
{
    if [[ $BOOTLOADER = false ]] ; then
        echo "**************** --nobl argument is set"
        echo "**************** skipping flash bootloader section"
        return
    fi

    if [ ! -e "${bootloaderimg}" ] ; then
        echo "bootloader.img not found"
        echo "Try to build bootloader.img"
        echo "Checking required files exist..."
        verify_bins
        if [[ $? != 0 ]]; then
            echo
            echo "**************** NO bootloader binaries found."
            echo "**************** It's ok, skipping flash bootloader section"
            echo
            return
        else
            echo "Run packipl"
            verify_cmd $packipl all ./
        fi
    fi

    echo "Flash bootloader"
    verify_cmd ${FASTBOOT_SERIAL} flash bootloader ${bootloaderimg}

    if [[ $LEGACY_BL = true ]] ; then
        echo "**************** --legacy_bl argument is set"
        echo "**************** Flashing bootloaders to HyperFlash"
        verify_cmd ${FASTBOOT_SERIAL} oem flash all
        echo "Waiting 30 sec for bootloaders update ..."
        sleep 5; wait_for_fastboot 30
    else
        verify_cmd ${FASTBOOT_SERIAL} reboot-bootloader
        sleep 3; wait_for_fastboot 30
    fi

    if [[ $RESETENV = false ]] ; then
        echo "**************** --noresetenv argument is set"
        echo "**************** Skipping operation of reset default environment"
    else
        verify_cmd ${FASTBOOT_SERIAL} oem setenv default
    fi

    verify_cmd ${FASTBOOT_SERIAL} oem format
    verify_cmd ${FASTBOOT_SERIAL} reboot-bootloader
}

flash_bootloader_only_bl2 ()
{
    verify_cmd ${ADB} root
    adb_wait_device
    verify_cmd ${ADB} push ${bl2} ${DATA}
    echo "Flashing bl2.."
    verify_cmd ${ADB} shell ${HYPER_CA} -w BL2 ${DATA}/${bl2##*/}
}

verify_bins ()
{
    if [ ! -f "$bootparam" ]; then
        return 1
    fi
    if [ ! -f "$bl2" ]; then
        return 1
    fi
    if [ ! -f "$cert" ]; then
        return 1
    fi
    if [ ! -f "$bl31" ]; then
        return 1
    fi
    if [ ! -f "$tee" ]; then
        return 1
    fi
    if [ ! -f "$uboot" ]; then
        return 1
    fi
    if [ ! -f "$pack_ipl" ]; then
        return 1
    fi
}

check_adb ()
{
	if [ -f ${ADB} ]; then
	adb_status=`${ADB} devices | sed -n 2p 2>&1`
	if [ "X$adb_status" = "X" ]; then
		echo "No device detected. Please ensure that" \
			 "target device is connected and booted"
		exit -1;
	else
		device=`echo $adb_status  |awk '{print$1}'`
		echo -e "\nadb - device detected: $device\n"
	fi
	else
	echo "Error: adb is not available at ${ADB}"
	exit -1;
	fi
}

check_fastboot()
{
	if [ -f ${FASTBOOT} ]; then

		fastboot_status=$(${FASTBOOT_SERIAL} devices 2>/dev/null)
		result=$?
		if [ $result != 0 ]; then
			echo "ERROR. fastboot status finished with result [$result]"
			exit $result
		fi

		if [ "X$fastboot_status" = "X" ]; then
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
}

