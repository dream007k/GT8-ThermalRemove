MODDIR=${0%/*}

# Mounts are done in service.sh to run after all overlays are in place.
# post-fs-data.sh only pre-copies to anyfs upperdir as a fallback.

ANYFS_UPPER="/dev/anyfs/upper"

copy_to_anyfs() {
    for file in "$MODDIR/$1"/*; do
        [ -e "$file" ] || continue
        local sub_item=$(basename "$file")
        local target_path="$1/$sub_item"
        if [ -f "$file" ]; then
            local target_dir=$(dirname "$target_path")
            if [ -d "$ANYFS_UPPER/$(echo "$target_dir" | cut -d'/' -f1-3)" ]; then
                mkdir -p "$ANYFS_UPPER/$target_dir"
                cp -f "$file" "$ANYFS_UPPER/$target_dir/$sub_item"
                chcon --reference "$target_path" "$ANYFS_UPPER/$target_dir/$sub_item" 2>/dev/null
            fi
        elif [ -d "$file" ]; then
            copy_to_anyfs "$target_path"
        fi
    done
}

copy_to_anyfs "/odm"
copy_to_anyfs "/my_product"
