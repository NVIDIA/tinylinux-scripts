#!/bin/bash

# Copyright (c) 2009-2016, NVIDIA CORPORATION.  All rights reserved.
# See LICENSE file for details.

set -e

die()
{
    echo "$@"
    exit 1
}

[[ `id -u` -eq 0 ]] || die "This script must be run with root privileges"

VERSION="${1:-$(date "+%y.%m")}"
echo "Creating version $VERSION"

[[ -d "$VERSION" ]] && die "Directory $VERSION in the way"
mkdir "$VERSION"

ls "`dirname $0`/profiles" | while read PROFILE; do
    [ -e "`dirname $0`/profiles/$PROFILE/skipdefault" ] && continue # Skip some profiles
    `dirname $0`/build_tiny_linux.sh -r -v "$VERSION" "$PROFILE"
    mv "buildroot/$PROFILE.zip" "$VERSION"
    sed "s/$/\r/" < "buildroot/newroot/etc/release" > "$VERSION/$PROFILE.txt"
done

`dirname $0`/build_mods_driver.sh prepare
mv build_mods_driver.tar.bz2 "$VERSION"/

echo
echo "All done!"
