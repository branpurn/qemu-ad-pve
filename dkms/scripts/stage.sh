#!/usr/bin/env bash
# stage.sh <upstream-version> <builddir>
# Copy the fetched KVM source into <builddir>, apply patches/*.patch, and
# redirect the two $(srctree) references in arch/x86/kvm/Makefile to the copy
# so an external (M=) build uses the staged files instead of the headers tree.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[ $# -eq 2 ] || { echo "usage: $0 <upstream-version> <builddir>" >&2; exit 2; }
ver=$1
build=$2
src="$here/src/$ver"

[ -d "$src" ] || {
    echo "missing $src: run ./fetch-kvm-source.sh $ver first" >&2
    exit 1
}
"$here/fetch-kvm-source.sh" "$ver" --outdir "$here/src" --verify

rm -rf "$build"
mkdir -p "$build/arch/x86" "$build/virt"
cp -a "$src/arch/x86/kvm" "$build/arch/x86/kvm"
cp -a "$src/virt/kvm" "$build/virt/kvm"

shopt -s nullglob
for p in "$here"/patches/*.patch; do
    echo "applying $(basename "$p")"
    patch -d "$build" -p1 --forward --fuzz=2 --no-backup-if-mismatch <"$p" ||
        { echo "patch $(basename "$p") does not apply to $ver; rebase it" >&2; exit 1; }
done

mk="$build/arch/x86/kvm/Makefile"
# Literal $(src)/$(srctree) are Makefile syntax, not shell expansions.
# shellcheck disable=SC2016
sed -i \
    -e 's|\$(srctree)/arch/x86/kvm|$(src)|g' \
    -e 's|\$(srctree)/virt/kvm/Makefile.kvm|$(src)/../../../virt/kvm/Makefile.kvm|g' \
    "$mk"
# trace.h files set TRACE_INCLUDE_PATH=../../arch/x86/kvm and are found through an
# include dir two levels below the tree root; virt/kvm in the staged copy is one.
# shellcheck disable=SC2016
printf '\n# added by stage.sh\nccflags-y += -I $(src)/../../../virt/kvm\n' >>"$mk"
if grep -n 'srctree' "$mk"; then
    echo "warning: remaining \$(srctree) references in $mk (see above); this kernel version may need stage.sh updates" >&2
fi
echo "staged $ver in $build"
