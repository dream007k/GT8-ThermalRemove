MODDIR=${0%/*}

# Mount module files on top of any overlays (must be in service.sh, not post-fs-data.sh)
mount_recursive() {
    for file in "$MODDIR/$1"/*; do
        [ -e "$file" ] || continue
        local sub_item=$(basename "$file")
        local target_path="$1/$sub_item"
        if [ -f "$file" ]; then
            mount --bind "$file" "$target_path"
        elif [ -d "$file" ]; then
            mount_recursive "$target_path"
        fi
    done
}
mount_recursive "/odm"
mount_recursive "/my_product"

manufacturer=$(getprop ro.product.odm.manufacturer)
soc=$(getprop ro.soc.model | tr 'a-z' 'A-Z')
cos_version=$(getprop ro.build.display.id | cut -d '.' -f 4 | cut -d '(' -f 1)

lock_val() {
    for file in $(find $2); do
        file="$(realpath $file)"
        umount "$file"
        chmod +w "$file"
        echo "$1" >"$file"
        chmod -w "$file"
        restorecon -R -F "$file" > /dev/null 2>&1
    done
}

mask_val() {
    for file in $(find $2); do
        lock_val "$1" "$file"

        TIME="$(date "+%s%N")"
        echo "$1" >"/dev/mount_masks/mount_mask_$TIME"
        mount --bind "/dev/mount_masks/mount_mask_$TIME" "$file"
        restorecon -R -F "$file" > /dev/null 2>&1
    done
}

apply_testmode() {
    dumpsys horae testmode
    for i in $(seq 0 2); do
        echo "$i 29500" > /proc/shell-temp
    done
}

wait_until_login() {
    until [ -d "/data/data/android" ]; do
        sleep 1
    done
}

if [[ $manufacturer == 'OnePlus' ]] && [[ $soc == 'SM8650' ]] && [[ $cos_version -lt 700 ]]; then
  t=29500
  for tz in /sys/class/thermal/*
  do
    if [[ -f $tz/temp ]]; then
      case $(cat $tz/type) in
        rear-tof-therm|cam-flash-therm)
          echo $t > $tz/emul_temp
        ;;
        batt-therm|usb-therm)
          echo $t > $tz/emul_temp
        ;;
        wlan-therm|xo-therm|oplus_thermal_ipa)
          echo $t > $tz/emul_temp
        ;;
        shell*)
          echo $t > $tz/emul_temp
        ;;
      esac
    fi
  done
else
  stop vendor.oplus.ormsHalService-aidl-default
fi

lock_val "0" /sys/class/kgsl/kgsl-3d0/max_pwrlevel
lock_val "2147483647" /sys/class/kgsl/kgsl-3d0/max_gpu_clk
lock_val "2147483647" /sys/class/kgsl/kgsl-3d0/max_clock_mhz
renice -n -19 -p $(pidof vendor-oplus-hardware-touch-V2-service)
renice -n -19 -p $(pidof touchDaemon)

wait_until_login
apply_testmode

sleep 60

spoofed=$(dumpsys horae | grep '^Temp:' | head -1 | tr -d 'Temp:')
if [ "$(echo "$spoofed != 29.50" | bc)" -eq 1 ] 2>/dev/null || [ "$spoofed" != "29.50" ]; then
    apply_testmode
fi