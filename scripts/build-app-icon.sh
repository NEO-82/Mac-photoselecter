#!/bin/bash
# Xcode build phase: convert the supplied artwork to the standard macOS icon sizes.
set -euo pipefail

source_image="$SRCROOT/Resources/AppIcon.png"
iconset_dir="$DERIVED_FILE_DIR/AppIcon.iconset"
icon_file="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/AppIcon.icns"
mkdir -p "$iconset_dir" "$(dirname "$icon_file")"

for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$source_image" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    /usr/bin/sips -z "$retina_size" "$retina_size" "$source_image" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil --convert icns --output "$icon_file" "$iconset_dir"
echo 'App icon: 정광이 골든리트리버 (16–1024 pixels)'
