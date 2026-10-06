set_perm_recursive $MODPATH 0 0 0755 0644

cos_version=$(getprop ro.build.display.id | cut -d '.' -f 4 | cut -d '(' -f 1)
manufacturer=$(getprop ro.product.odm.manufacturer)
soc=$(getprop ro.soc.model | tr 'a-z' 'A-Z')
marketname=$(getprop ro.vendor.oplus.market.name)
DESC_ZH="为 $marketname 定制的更温和的温控移除工具。"
DESC_EN="A professional thermal control remover for $marketname."
DESC_FR="Un dissolvant de contrôle thermique pour $marketname."

setprop persist.sys.oplus.wifi.sla.game_high_temperature 50
setprop persist.sys.environment.temp 25

mkdir -p $MODPATH/system/vendor/etc
touch $MODPATH/ab_certified

if [[ -f $MODPATH/disable ]]; then
  rm $MODPATH/disable
fi

dirs="/odm /my_product /vendor /system/vendor /product /system"

xml_override() {
  mkdir -p $(dirname $MODPATH$1)

  for file in $(find $dirs -name "$1")
  do
    mkdir -p $(dirname $MODPATH$file)
    rows=$(cat $file)
    for override in "$2"; do
      key=$(echo $override | cut -f1 -d '=')
      value=$(echo $override | cut -f2 -d '=')
      rows=$(echo "$rows" | sed "s/<$key>.*</<$key>$value</")
    done
    echo "$rows" > $MODPATH$file
  done
}

# sys_thermal_control_config.xml (exact match only)
boolValues="feature_enable_item feature_safety_test_enable_item aging_thermal_control_enable_item"
intValues="aging_cpu_level_item high_temp_safety_level_item game_high_perf_mode_item normal_mode_item ota_mode_item racing_mode_item"
today_version=$(date +"%Y%m%d01")
for file in $(find $dirs -name "sys_thermal_control_config.xml")
do
  mkdir -p $(dirname $MODPATH$file)
  if head -c 32 "$file" | grep -q '<?xml\|<sys_thermal'; then
    rows=$(cat $file | grep -v -E '(<gear_config|cpu=|fps=|<scene_|</scene_|<category_|</category_|<subitem|<level|\.)')

    for key in $boolValues; do
      rows=$(echo "$rows" | sed "s/<$key.*\/>/<$key booleanVal=\"false\" \/>/")
    done

    for key in $intValues; do
      rows=$(echo "$rows" | sed "s/<$key.*\/>/<$key intVal=\"-1\" \/>/")
    done

    echo "$rows" | tr -s '\n' > $MODPATH$file
  else
    sed "s/<version>.*<\/version>/<version>${today_version}<\/version>/" "$MODPATH/sys_thermal_control_config_default.xml" > $MODPATH$file
  fi
done

# sys_thermal_control_config_gt.xml and other variants (default processing)
for file in $(find $dirs -name "sys_thermal_control_config_*.xml")
do
  mkdir -p $(dirname $MODPATH$file)
  if head -c 32 "$file" | grep -q '<?xml\|<sys_thermal'; then
    rows=$(cat $file | grep -v -E '(<gear_config|cpu=|fps=|<scene_|</scene_|<category_|</category_|<subitem|<level|\.)')

    for key in $boolValues; do
      rows=$(echo "$rows" | sed "s/<$key.*\/>/<$key booleanVal=\"false\" \/>/")
    done

    for key in $intValues; do
      rows=$(echo "$rows" | sed "s/<$key.*\/>/<$key intVal=\"-1\" \/>/")
    done

    echo "$rows" | tr -s '\n' > $MODPATH$file
  fi
done

# sys_thermal_config.xml
xml_override 'sys_thermal_config.xml' "isOpen=0
more_heat_threshold=550
heat_threshold=530
less_heat_threshold=500
preheat_threshold=480
preheat_dex_oat_threshold=460
thermal_battery_temp=0
is_feature_on=0
is_upload_log=0
is_upload_errlog=0"

# sys_high_temp_protect_*。xml
xml_override 'sys_high_temp_protect*xml' "isOpen=0
HighTemperatureProtectSwitch=false
HighTemperatureShutdownSwitch=false
HighTemperatureFirstStepSwitch=false
HighTemperatureProtectFirstStepIn=550
HighTemperatureProtectFirstStepOut=530
HighTemperatureProtectThresholdIn=570
HighTemperatureProtectThresholdOut=550
HighTemperatureProtectShutDown=750
MediumTemperatureProtectThreshold=10000
HighTemperatureDisableFlashSwitch=false
HighTemperatureDisableFlashLimit=480
HighTemperatureEnableFlashLimit=470
HighTemperatureDisableFlashChargeSwitch=false
HighTemperatureDisableFlashChargeLimit=480
HighTemperatureEnableFlashChargeLimit=470
camera_temperature_limit=520
HighTemperatureControlVideoRecordSwitch=false
HighTemperatureDisableVideoRecordLimit=550
HighTemperatureEnableVideoRecordLimit=520
ToleranceThreshold=50
ToleranceStart=480
ToleranceStop=460"

# thermallevel_to_fps.xml
for file in $(find $dirs -name "thermallevel_to_fps.xml")
do
  mkdir -p $(dirname $MODPATH/system$file)
  cat $file | sed "s/fps=\".*\"/fps=\"144\"/" > $MODPATH/system$file
done

# oppo_display_perf_list.xml
# multimedia_display_perf_list.xml
for file in $(find $dirs -name "oppo_display_perf_list.xml")
do
  mkdir -p $(dirname $MODPATH$file)
  echo -n '' > $MODPATH$file
  skip=0
  while read line; do
    case "$line" in
     *"<name>"*)
       skip=0
       case "$line" in
        *"sf.dps.feature"*|*"com.android"*|*"system_server"*|*"/system"*|*"com.color"*|*"com.oppo"*|*"com.oplus"**"SmartVolume"*)
          skip=0
          echo "  $line" >> $MODPATH$file
        ;;
        *)
          skip=1
        ;;
       esac
     ;;
     '<?xml version="1.0" encoding="UTF-8"?>'|'<filter-conf>'|'</filter-conf>')
         echo "$line" >> $MODPATH$file
     ;;
     *)
       if [[ $skip == 0 ]]; then
         echo "  $line" >> $MODPATH$file
       fi
     ;;
    esac
  done < $file
done

# game_thermal_config.xml
for file in $(find $dirs -name "game_thermal_config.xml")
do
  mkdir -p $(dirname $MODPATH$file)
  echo -n '' > $MODPATH$file
  if [[ $(grep cluster3 $file) != '' ]];then
  echo '<?xml version="1.0" encoding="utf-8"?>
<game_thermal_config>
    <version>20230829</version>
    <filter-name>game_thermal_config</filter-name>
    <heavy_policy>
        <game_control temp="520" cluster0="-1" cluster1="-1" cluster2="-1" cluster3="-1" fps="60"/>
    </heavy_policy>
    <default_policy>
        <game_control temp="430" cluster0="-1" cluster1="-1" cluster2="-1" cluster3="-1" fps="0"/>
        <game_control temp="440" cluster0="-1" cluster1="-1" cluster2="-1" cluster3="-1" fps="0"/>
        <game_control temp="450" cluster0="-1" cluster1="-1" cluster2="-1" cluster3="-1" fps="0"/>
        <game_control temp="460" cluster0="-1" cluster1="-1" cluster2="-1" cluster3="-1" fps="0"/>
        <game_control temp="470" cluster0="-1" cluster1="-1" cluster2="-1" cluster3="-1" fps="0"/>
        <game_control temp="480" cluster0="-1" cluster1="-1" cluster2="-1" cluster3="-1" fps="0"/>
        <game_control temp="490" cluster0="-1" cluster1="-1" cluster2="-1" cluster3="-1" fps="0"/>
        <game_control temp="510" cluster0="-1" cluster1="-1" cluster2="-1" cluster3="-1" fps="0"/>
    </default_policy>
</game_thermal_config>' > $MODPATH$file
  else
  echo '<?xml version="1.0" encoding="utf-8"?>
<game_thermal_config>
    <version>20230829</version>
    <filter-name>game_thermal_config</filter-name>
    <heavy_policy>
        <game_control temp="520" cluster0="-1" cluster1="-1" cluster2="-1" fps="60"/>
    </heavy_policy>
    <default_policy>
        <game_control temp="430" cluster0="-1" cluster1="-1" cluster2="-1" fps="0"/>
        <game_control temp="440" cluster0="-1" cluster1="-1" cluster2="-1" fps="0"/>
        <game_control temp="450" cluster0="-1" cluster1="-1" cluster2="-1" fps="0"/>
        <game_control temp="460" cluster0="-1" cluster1="-1" cluster2="-1" fps="0"/>
        <game_control temp="470" cluster0="-1" cluster1="-1" cluster2="-1" fps="0"/>
        <game_control temp="480" cluster0="-1" cluster1="-1" cluster2="-1" fps="0"/>
        <game_control temp="490" cluster0="-1" cluster1="-1" cluster2="-1" fps="0"/>
        <game_control temp="510" cluster0="-1" cluster1="-1" cluster2="-1" fps="0"/>
    </default_policy>
</game_thermal_config>' > $MODPATH$file
  fi
done

# QEGA_Config.txt
for file in $(find $dirs -name "QEGA_Config.txt")
do
  mkdir -p $(dirname $MODPATH$file)
  echo "SkinTemperatureNode:   xo-therm
SkinNodeThrottleTemp:  42000
#GameID   GameAPK    MaxTemperature  MaxCurrent  AvgCurrent
100001    hok         42000          1200        900
0         adaptive    42000          1200        900" > $MODPATH$file
done

# devices_config.json
for file in $(find $dirs -name "devices_config.json")
do
  mkdir -p $(dirname $MODPATH$file)
  echo -n '' > $MODPATH$file
  while read line; do
    case "$line" in
     *'"high.capacity.threshold": 100'*)
       echo "$line" >> $MODPATH$file
     ;;
     *'"battery.temperate.range":'*)
       echo '"battery.temperate.range": "[100,500]",' >> $MODPATH$file
     ;;
     *'"high.capacity.threshold":'*)
       echo '"high.capacity.threshold": 85' >> $MODPATH$file
     ;;
     *)
       echo "$line" >> $MODPATH$file
     ;;
    esac
  done < $file
done

# qapegameconfig.txt
for file in $(find $dirs -name "qapegameconfig.txt")
do
  mkdir -p $(dirname $MODPATH$file)
  echo "#GameID   GameAPK          MaxTemperature  MaxCurrent  AvgCurrent //Current here means device consuming current (1000 means device is consuming 1000 mA)
100001    hok                 42000          1150        900
100002    codm                42000          1150        900
100010    hok_oversea         42000          1150        900
100100    GP                  42000          1150        900
120000    com.netease.allstar 42000          1150        900
120100    Infinity_Nikki      42000          1150        900
120200    NARAKA_BLADEPOINT   42000          1150        900
120300    JusticeOnline       42000          1150        900
120400    Seasun_JXOnline3    42000          1150        900
120500    Tencent_DFM         42000          1150        900
120600    Tencent_PRacing     42000          1150        900
120700    WutheringWaves      42000          1150        900
120800    PerfectWorld_P5X    42000          1150        900
120900    Netease_Diablo      42000          1150        900
121000    Racing_Master       42000          1150        900
121100    Tarisland           42000          1150        900
121200    Arena_Breakout      42000          1150        900
121300    Tencent_DNF         42000          1150        900
121400    Tencent_LOL         42000          1150        900
121500    Tencent_Spatula     42000          1150        900
121600    Genshin             42000          1150        900
122700    StarRail            42000          1150        900
122800    ZenlessZoneZero     42000          1150        900
0         Default             42000          1150        100" > $MODPATH$file
done

if [[ -f $MODPATH/orms_core_config.xml ]]; then
  mkdir -p $MODPATH/odm/etc/orms
  cp -f $MODPATH/orms_core_config.xml $MODPATH/odm/etc/orms/orms_core_config.xml
fi

lang=$(getprop persist.sys.locale | cut -d '-' -f 1)

case $lang in
zh)
    DESC=$DESC_ZH
    ;;
fr)
    DESC=$DESC_FR
    ;;
*)
    DESC=$DESC_EN
    ;;
esac

sed -i "s/^description=.*$/description=$DESC/" "$MODPATH/module.prop"

set_perm_recursive "$MODPATH"/odm 0 0 0755 0644 u:object_r:vendor_configs_file:s0
set_perm_recursive "$MODPATH"/system 0 0 0755 0644 u:object_r:vendor_configs_file:s0