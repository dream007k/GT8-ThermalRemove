#!/system/bin/sh
# 公共函数库：供 action.sh 和 service.sh 共用

# 检查应用是否在配置列表中
# 参数: $1=配置文件路径 $2=应用包名
# 返回: 0=在列表中 1=不在列表中
is_in_list() {
    list="$1"
    app="$2"
    [ -r "$list" ] || return 1
    [ -z "$app" ] && return 1
    awk -v app="$app" -F '#' '{
        gsub(/^[ \t\r]+|[ \t\r]+$/, "", $1)
        if ($1 == app) { found=1; exit }
    }
    END { exit (found ? 0 : 1) }' "$list"
}
