#!/usr/bin/env bash
# fetch-kvm-source.sh <kver> [--verify] [--outdir DIR]
#
# Pull arch/x86/kvm and virt/kvm from the kernel source tag v<kver> into
#   <outdir>/<kver>/{arch/x86/kvm,virt/kvm}
# and record what was fetched:
#   <outdir>/<kver>/SOURCE-INFO       repo URL, tag, resolved commit, date
#   <outdir>/<kver>/SOURCE-SHA256SUMS sha256 of every fetched file
#
# This only writes below <outdir> (default: ./src next to this script) and a
# temporary directory. It never touches /usr/src, /lib/modules or any running
# system. Run it on the machine that will build the module (the nested L1
# guest), not on the PVE host.
#
# Environment:
#   KVM_SRC_GIT  git URL to fetch from
#                (default: https://github.com/gregkh/linux.git, which carries
#                 the mainline and stable v* tags; git.kernel.org stable works too)
#   KVM_SRC_TAG  override the tag (default: v<kver>)
#
# --verify re-hashes an existing <outdir>/<kver> and compares it with the
# recorded SOURCE-SHA256SUMS (no network).
#
# NOTE: <kver> is the *upstream* version (6.12.111), not a distro release
# string. The mapping from a distro/Proxmox kernel to an upstream tag is not
# always 1:1 (Proxmox kernels carry Ubuntu patches); see README.md.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
outdir="$here/src"
verify=0
kver=""

usage() {
    sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --verify) verify=1 ;;
        --outdir)
            [ $# -ge 2 ] || { echo "--outdir needs a value" >&2; exit 2; }
            outdir=$2
            shift
            ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *)
            [ -z "$kver" ] || { echo "only one <kver> allowed" >&2; exit 2; }
            kver=$1
            ;;
    esac
    shift
done

[ -n "$kver" ] || { usage >&2; exit 2; }
if ! [[ $kver =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?(-rc[0-9]+)?$ ]]; then
    echo "kver must look like 6.12 / 6.12.111 / 7.0-rc3 (upstream version only), got: $kver" >&2
    exit 2
fi

dest="$outdir/$kver"
sums="$dest/SOURCE-SHA256SUMS"
paths=(arch/x86/kvm virt/kvm)

hash_tree() { # print "<sha256>  <relpath>" for every file, sorted by path
    (cd "$dest" && LC_ALL=C find "${paths[@]}" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
}

if [ "$verify" -eq 1 ]; then
    [ -f "$sums" ] || { echo "no recorded sums at $sums (run without --verify first)" >&2; exit 1; }
    if hash_tree | diff -u "$sums" - >&2; then
        echo "OK: $dest matches $sums"
        exit 0
    fi
    echo "MISMATCH: $dest differs from $sums" >&2
    exit 1
fi

repo=${KVM_SRC_GIT:-https://github.com/gregkh/linux.git}
tag=${KVM_SRC_TAG:-v$kver}

if [ -e "$dest" ]; then
    echo "$dest already exists; remove it first (rm -rf) to re-fetch" >&2
    exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "fetching $tag from $repo (shallow; this downloads the whole tag, a few hundred MB, if the server ignores partial-clone filters)" >&2
git init -q "$tmp/repo"
git -C "$tmp/repo" remote add origin "$repo"
git -C "$tmp/repo" sparse-checkout set --no-cone "/${paths[0]}/" "/${paths[1]}/"
git -C "$tmp/repo" fetch -q --depth 1 --filter=blob:none origin "refs/tags/$tag:refs/tags/$tag"
git -C "$tmp/repo" checkout -q "refs/tags/$tag"

commit=$(git -C "$tmp/repo" rev-parse "refs/tags/$tag^{commit}")
cdate=$(git -C "$tmp/repo" log -1 --format=%cI "$commit")

mkdir -p "$dest"
for p in "${paths[@]}"; do
    [ -d "$tmp/repo/$p" ] || { echo "missing $p in $tag" >&2; rm -rf "$dest"; exit 1; }
    mkdir -p "$dest/$(dirname "$p")"
    cp -a "$tmp/repo/$p" "$dest/$p"
done

hash_tree >"$sums"
{
    echo "repo=$repo"
    echo "tag=$tag"
    echo "commit=$commit"
    echo "commit_date=$cdate"
    echo "fetched_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "files=$(wc -l <"$sums")"
} >"$dest/SOURCE-INFO"

echo "OK: $dest ($(wc -l <"$sums") files, commit $commit)"
echo "sha256 list: $sums"
echo "Compare the commit against the tag on a second, independent source before trusting it."
