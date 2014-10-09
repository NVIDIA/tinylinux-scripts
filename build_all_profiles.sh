#!/bin/sh

set -e

die()
{
    echo "$@"
    exit 1
}

[ `id -u` -eq 0 ] || die "This script must be run with root privileges"

VERSION="$1"
[ "$VERSION" ] || VERSION=`date "+%y.%m"`
echo "Creating version $VERSION"

[ -d "$VERSION" ] && die "Directory $VERSION in the way"
mkdir "$VERSION"

ls "`dirname $0`/profiles" | while read PROFILE; do
    [ -e "`dirname $0`/profiles/$PROFILE/tegra" ] && continue # Skip Tegra profiles
    `dirname $0`/build_tiny_linux.sh -r -v "$VERSION" "$PROFILE"
    mv "buildroot/$PROFILE.zip" "$VERSION"
    sed "s/$/\r/" < "buildroot/newroot/etc/release" > "$VERSION/$PROFILE.txt"
done

echo
echo "All done!"
