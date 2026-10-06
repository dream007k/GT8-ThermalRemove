#!/system/bin/sh
MODDIR="${0%/*}"

replace_files() {
  local folder="$1"
  find "$MODDIR/$folder" -type f 2>/dev/null | while read -r src; do
    local dst="${src#$MODDIR}"
    [ -f "$dst" ] && mount --bind "$src" "$dst"
  done
}

mount_folders='my_product my_heytap my_stock odm'
if [ "$KSU" = "true" ] || [ $(which ksud) != "" ] || [ $(which apd) != "" ]; then
  mount_folders='my_product my_heytap my_stock'
fi

for folder in $mount_folders; do
  if [ -d $MODDIR/$folder ]; then
    replace_files "$folder"
  fi
done

(
  while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 1
  done
  sleep 3
  [ -x "$MODDIR/thermal_spoof.sh" ] && sh "$MODDIR/thermal_spoof.sh"
) &

exit 0
