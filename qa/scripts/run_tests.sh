#!/bin/bash
# Independent QA harness for qemu-ad-pve.sh wrapper + installer helpers.
# VERSION: PR #7 (section 15 added; 14a/14a2/14k/14t changed for the intentional --disable-libusb -> --enable-libusb switch, run_tests.pre_pr7.sh = the PR #6 version)
# (earlier) VERSION: PR #6 (section 14 added; sections 1-13 unchanged, run_tests.pre_pr6.sh = the PR #5 version)
# (earlier) VERSION: PR #5 (section 13 added; sections 1-12 unchanged, run_tests.pre_pr5.sh = the PR #4 version)
# (earlier) VERSION: PR #4 (updated 2026-10-01). Expectations for 4h/4i/4j (whitespace/CRLF lines) and 10d (LIST_FILE=/opt/...)
# were CHANGED to the PR #4 behaviour (N3/N1). The PR #3-era expectations are preserved in run_tests.pre_pr4.sh
# (run that one against main 1cc3181 / PR #3 code; it fails 4h/4i/4j/10d on PR #4 BY DESIGN).
# Usage: run_tests.sh [/path/to/qemu-ad-pve.sh]   (required)
# Self-contained: needs bash, cc, python3, perl, dpkg-divert (optional), setpriv/su (optional).
# Everything runs in a mktemp dir. It never touches /usr/bin/kvm*, /etc/qemu-ad, /var/lib/dpkg:
# all paths are rewritten through WRAPPER_PATH/VENDOR_PATH/LIST_FILE/LOG_FILE/PREFIX/DPKG_LOCK.
# For belt and braces run it under qa/scripts/sandbox.sh (bwrap, real fs read-only).
set -u
# synthetic fixture ids used throughout (no real-world meaning); "10" and "1010" below are prefix/suffix variants of QID1
QID1=$((100+1)); QID2=100; QID3=$((100+2))
[[ -n ${1:-} ]] || { echo "usage: $0 /path/to/qemu-ad-pve.sh" >&2; exit 64; }
SCRIPT=$(readlink -f "$1")
W=$(mktemp -d "${TMPDIR:-/tmp}/qad-qa.XXXXXX"); trap 'command rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }
note(){ printf 'INFO  %s\n' "$1"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1"${3:+ -- $3}; fi; }
command -v cc >/dev/null || { echo "need cc"; exit 2; }
grep -q '^main "\$@"$' "$SCRIPT" || { echo "unexpected script tail"; exit 2; }
sed '$d' "$SCRIPT" > "$W/lib.sh"      # library = script minus final main call

# ---- stub QEMU: records marker, argv[0], /proc/self/cmdline[0] and every arg, NUL-separated, to OUT
cat > "$W/stub.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
static void onsig(int s){ FILE*f=fopen(OUT ".sig","w"); if(f){fprintf(f,"%d",s);fclose(f);} _exit(40+s); }
int main(int c,char**v){
  char cl[8192]; size_t n=0; FILE*p=fopen("/proc/self/cmdline","r"); if(p){n=fread(cl,1,sizeof cl-1,p);fclose(p);} cl[n]=0;
  /* behaviours */
  for(int i=1;i<c;i++){
    if(!strcmp(v[i],"--exit3")) return 3;
    if(!strcmp(v[i],"--cat")){ int ch; while((ch=getchar())!=EOF) putchar(ch); return 0; }
    if(!strcmp(v[i],"--sleep")){ signal(SIGTERM,onsig); FILE*f=fopen(OUT ".pid","w"); fprintf(f,"%d",getpid()); fclose(f); sleep(30); return 0; }
  }
  FILE*f=fopen(OUT,"w"); fwrite(MARK,1,strlen(MARK)+1,f); fwrite(v[0],1,strlen(v[0])+1,f); fwrite(cl,1,strlen(cl)+1,f);
  for(int i=1;i<c;i++) fwrite(v[i],1,strlen(v[i])+1,f); fclose(f); return 0; }
EOF
cc -DMARK='"VENDOR"' -DOUT="\"$W/out\"" -o "$W/kvm.pve" "$W/stub.c" || exit 2
cc -DMARK='"SIDE"'   -DOUT="\"$W/out\"" -o "$W/qemu-system-x86_64" "$W/stub.c" || exit 2

# ---- render the REAL generated wrapper from the script's own generator
mkdir -p "$W/etc" "$W/var"
render() { # render <outfile> [VENDOR] [SIDE]
  bash -c "source '$W/lib.sh'; set +eu; WRAPPER_PATH=/usr/bin/kvm VENDOR_PATH='${2:-$W/kvm.pve}' SIDE_BIN='${3:-$W/qemu-system-x86_64}' LIST_FILE='$W/etc/vms' LOG_FILE='$W/var/wrapper.log'; write_wrapper '$1'" >/dev/null
}
render "$W/kvm"; bash -n "$W/kvm" || { echo "generated wrapper fails bash -n"; exit 2; }
chmod 755 "$W/kvm"

out=() ; load() { out=(); [[ -e $W/out ]] && mapfile -d '' -t out < "$W/out"; }
run() { command rm -f "$W/out"; "$W/kvm" "$@" </dev/null >"$W/stdout" 2>"$W/stderr"; RC=$?; load; }   # out[0]=marker [1]=argv0 [2]=/proc cmdline0 [3..]=args
args() { printf '%s\0' "${out[@]:3}"; }
same_args() { # same_args expected... : compare out[3..] with parameters byte-for-byte
  local a b; a=$(printf '%s\0' "$@" | od -An -c); b=$(args | od -An -c); [[ $a == "$b" ]]; }
vm() { printf '%s\n' "$@" > "$W/etc/vms"; }
PIDF() { echo "/var/run/qemu-server/$1.pid"; }
KVMRE='kvm$'

echo "== 1. argv[0] / qemu-server parse_cmdline contract (HIGH finding)"
vm "${QID1}"
run -id "${QID1}" -name vm -pidfile "$(PIDF ${QID1})" -daemonize
chk "1a listed -> SIDE"                                '[[ ${out[0]} == SIDE ]]'
chk "1b side argv[0] == /usr/bin/kvm"                  '[[ ${out[1]} == /usr/bin/kvm ]]'
chk "1c side /proc/self/cmdline first field == /usr/bin/kvm (what qemu-server reads)" '[[ ${out[2]} == /usr/bin/kvm ]]'
run -id "${QID3}" -name vm -pidfile "$(PIDF ${QID3})" -daemonize
chk "1d unlisted -> VENDOR"                            '[[ ${out[0]} == VENDOR ]]'
chk "1e vendor argv[0] == /usr/bin/kvm (NOT /usr/bin/kvm.pve)" '[[ ${out[1]} == /usr/bin/kvm && ${out[2]} == /usr/bin/kvm ]]'
rx() { perl -e '$c=shift; exit(($c =~ m|kvm$| || $c =~ m@(?:^|/)qemu-[^/]+$@) ? 0 : 1)' "$1"; }  # verbatim from PVE::QemuServer::Helpers::parse_cmdline
chk "1f PVE parse_cmdline regex accepts vendor-path argv[0]"  'rx "${out[2]}"'
run -pidfile "$(PIDF ${QID1})"; chk "1g PVE regex accepts side-path argv[0]" 'rx "${out[2]}"'
chk "1h control: regex REJECTS /usr/bin/kvm.pve (the old argv[0])" '! rx /usr/bin/kvm.pve'
chk "1i control: regex rejects side path argv[0] if exec'd plainly (/opt/qemu-ad/bin/qemu-system-x86_64 would match, kvm.pve would not)" 'rx /opt/qemu-ad/bin/qemu-system-x86_64 && ! rx /usr/bin/kvm.pve'
# the vendor binary must still be run from its own file (exec -a changes argv[0] only)
chk "1j stub binary identity: vendor stub marker is VENDOR even though argv[0]=kvm" '[[ -x $W/kvm.pve ]]'

echo "== 2. routing and argv fidelity"
vm "${QID1}"
run -id "${QID1}" -pidfile "$(PIDF ${QID1})" -x;                      chk "2a pidfile form (listed)" '[[ ${out[0]} == SIDE ]]'
run -chardev "socket,id=qmp,path=/var/run/qemu-server/${QID1}.qmp,server=on,wait=off" -x; chk "2b QMP chardev form (listed)" '[[ ${out[0]} == SIDE ]]'
run -chardev "socket,id=qmp,path=/var/run/qemu-server/${QID1}.qmp" -x;  chk "2b' QMP path without trailing option" '[[ ${out[0]} == SIDE ]]'
run -mon chardev=qmp -S;                                    chk "2c no VMID visible -> VENDOR" '[[ ${out[0]} == VENDOR ]]'
run -id "${QID1}" -pidfile "$(PIDF ${QID1})" -name n;                 chk "2d side path: '-id ${QID1}' stripped"  'same_args -pidfile "$(PIDF '"${QID1}"')" -name n'
run -id "${QID3}" -pidfile "$(PIDF ${QID3})" -name n;                 chk "2e vendor path: '-id ${QID3}' kept"    'same_args -id '"${QID3}"' -pidfile "$(PIDF '"${QID3}"')" -name n'
nl=$'\n'
A=(-id "${QID3}" -name 'a b' -smbios "type=1,product=x${nl}y" '' -drive 'file=/m/a+pve1/d,if=none' '-x' '--' '-' 'q"uote' "s'quote" '$HOME' '`id`' '*' '?[a]' 'back\slash' $'tab\there' -pidfile "$(PIDF ${QID3})" '')
run "${A[@]}"; chk "2f vendor path byte-identical (spaces, empty args, newline, quotes, \$, backticks, globs, leading dashes, +pve)" 'same_args "${A[@]}" && [[ $RC -eq 0 ]]'
B=(-name 'a b' -smbios "type=1,product=x${nl}y" '' '--' '-' 'q"uote' "s'quote" '$HOME' '`id`' '*' '?[a]' 'back\slash' $'tab\there' -pidfile "$(PIDF ${QID1})" '')
run "${B[@]}"; chk "2g side path byte-identical for the same special args (no -id)" '[[ ${out[0]} == SIDE ]] && same_args "${B[@]}"'
touch "$W/globme1" "$W/globme2"; (cd "$W" && "$W/kvm" '*' -pidfile "$(PIDF ${QID3})" >/dev/null </dev/null); load; chk "2h glob '*' not expanded even with matching files in cwd" '[[ ${out[3]} == "*" ]]'
run; chk "2i no args at all -> VENDOR, rc 0" '[[ ${out[0]} == VENDOR && $RC -eq 0 ]]'
run --version; chk "2j --version -> VENDOR" '[[ ${out[0]} == VENDOR ]] && same_args --version'

echo "== 3. +pveN stripping (side path only, only after -machine/-M)"
P=(-pidfile "$(PIDF ${QID1})")
run -machine 'type=pc-q35-10.1+pve1,accel=kvm' "${P[@]}"; chk "3a +pve1 stripped"  'same_args -machine type=pc-q35-10.1,accel=kvm "${P[@]}"'
run -machine 'pc-q35-10.1+pve10' "${P[@]}";                chk "3b +pve10 stripped" 'same_args -machine pc-q35-10.1 "${P[@]}"'
run -M 'pc-q35-10.1+pve2' "${P[@]}";                       chk "3c -M stripped"     'same_args -M pc-q35-10.1 "${P[@]}"'
run -machine 'a+pve1,b=c+pve22,d' "${P[@]}";               chk "3d multiple in one value" 'same_args -machine a,b=c,d "${P[@]}"'
run -machine x+pve1 -machine y+pve2 "${P[@]}";             chk "3e two -machine args" 'same_args -machine x -machine y "${P[@]}"'
run -name 'x+pve5' -smbios 'type=1,product=a+pve7' -drive 'file=/m/a+pve1/d' -device 'foo+pve3' "${P[@]}"
chk "3f +pve in name/smbios/disk/device NOT stripped" 'same_args -name x+pve5 -smbios type=1,product=a+pve7 -drive file=/m/a+pve1/d -device foo+pve3 "${P[@]}"'
run -machine 'pc-q35-10.1+pve' "${P[@]}";                  chk "3g '+pve' without digits untouched" 'same_args -machine pc-q35-10.1+pve "${P[@]}"'
run -machine 'pc-q35-10.1+pve1' -pidfile "$(PIDF ${QID3})";     chk "3h VENDOR path never strips +pve" '[[ ${out[0]} == VENDOR ]] && same_args -machine pc-q35-10.1+pve1 -pidfile "$(PIDF '"${QID3}"')"'
run -name -machine 'pc-q35+pve1' "${P[@]}";                note "3i edge: '-name -machine X+pve1' (option-looking value): X is stripped => ${out[*]:3}"
run -machine "pc-q35-10.1+pve1" -id "${QID1}" "${P[@]}";         chk "3j -id after -machine on side: both handled" 'same_args -machine pc-q35-10.1 "${P[@]}"'
run -machine -id "${QID1}" "${P[@]}";                            note "3k edge: '-machine -id ${QID1}' (invalid cmdline) => ${out[*]:3}"

echo "== 4. VMID matching"
vm 10;   run -pidfile "$(PIDF ${QID1})";   chk "4a list=10, vm ${QID1} -> VENDOR" '[[ ${out[0]} == VENDOR ]]'
vm "${QID1}";  run -pidfile "$(PIDF 10)";    chk "4b list=${QID1}, vm 10 -> VENDOR" '[[ ${out[0]} == VENDOR ]]'
vm "${QID1}";  run -pidfile "$(PIDF ${QID1}0)";  chk "4c list=${QID1}, vm ${QID1}0 -> VENDOR" '[[ ${out[0]} == VENDOR ]]'
vm "${QID1}0"; run -pidfile "$(PIDF ${QID1})";   chk "4d list=${QID1}0, vm ${QID1} -> VENDOR" '[[ ${out[0]} == VENDOR ]]'
printf '# '"${QID1}"'\n\n10\n'"${QID1}"'\n'"${QID1}0"'\n' > "$W/etc/vms"; run -pidfile "$(PIDF ${QID1})"; chk "4e comments/blank lines around exact line -> SIDE" '[[ ${out[0]} == SIDE ]]'
printf '# '"${QID1}"'\n' > "$W/etc/vms";            run -pidfile "$(PIDF ${QID1})"; chk "4f '# ${QID1}' only -> VENDOR" '[[ ${out[0]} == VENDOR ]]'
printf ''"${QID1}"' # note\n' > "$W/etc/vms";       run -pidfile "$(PIDF ${QID1})"; chk "4g trailing comment -> VENDOR (documented)" '[[ ${out[0]} == VENDOR ]]'
printf ''"${QID1}"' \n' > "$W/etc/vms";             run -pidfile "$(PIDF ${QID1})"; chk "4h [PR4/N3] trailing space -> SIDE (whitespace ignored)" '[[ ${out[0]} == SIDE ]]'
printf ' '"${QID1}"'\n' > "$W/etc/vms";             run -pidfile "$(PIDF ${QID1})"; chk "4i [PR4/N3] leading space -> SIDE" '[[ ${out[0]} == SIDE ]]'
printf ''"${QID1}"'\r\n' > "$W/etc/vms";            run -pidfile "$(PIDF ${QID1})"; chk "4j [PR4/N3] CRLF -> SIDE" '[[ ${out[0]} == SIDE ]]'
printf '\t'"${QID1}"'\t\r\n' > "$W/etc/vms";        run -pidfile "$(PIDF ${QID1})"; chk "4h2 [PR4] tab-padded + CR -> SIDE" '[[ ${out[0]} == SIDE ]]'
printf ''"${QID2}"'\r\n'"${QID1}"'\r\n'"${QID3}"'\r\n' > "$W/etc/vms"; run -pidfile "$(PIDF ${QID1})"; chk "4h3 [PR4] CRLF list, middle id -> SIDE" '[[ ${out[0]} == SIDE ]]'
printf ''"${QID2}"'\r\n'"${QID1}"'\r\n'"${QID3}"'\r\n' > "$W/etc/vms"; run -pidfile "$(PIDF 10)"; chk "4h4 [PR4] CRLF list, vm 10 (prefix of ${QID2}/${QID1}/${QID3}) -> VENDOR" '[[ ${out[0]} == VENDOR ]]'
printf ''"${QID2}"'\r\n'"${QID1}"'\r\n'"${QID3}"'\r\n' > "$W/etc/vms"; run -pidfile "$(PIDF ${QID1}0)"; chk "4h5 [PR4] CRLF list, vm ${QID1}0 -> VENDOR" '[[ ${out[0]} == VENDOR ]]'
printf ''"${QID1}0"'\r\n10\r\n' > "$W/etc/vms"; run -pidfile "$(PIDF ${QID1})"; chk "4h6 [PR4] CRLF list ${QID1}0,10, vm ${QID1} -> VENDOR (no substring match)" '[[ ${out[0]} == VENDOR ]]'
printf '5\r\n'"${QID1}"'' > "$W/etc/vms";            run -pidfile "$(PIDF ${QID1})"; chk "4h7 [PR4] last line, no newline at all -> SIDE" '[[ ${out[0]} == SIDE ]]'
printf '5\r\n'"${QID1}"'\r' > "$W/etc/vms";          run -pidfile "$(PIDF ${QID1})"; chk "4h8 [PR4] last line CR only, no LF -> SIDE" '[[ ${out[0]} == SIDE ]]'
printf '5\n'"${QID1}"'   ' > "$W/etc/vms";           run -pidfile "$(PIDF ${QID1})"; chk "4h9 [PR4] last line trailing spaces no newline -> SIDE" '[[ ${out[0]} == SIDE ]]'
printf '\r\n\n  \n'"${QID1}"'\n' > "$W/etc/vms";    run -pidfile "$(PIDF ${QID1})"; chk "4h10 [PR4] blank/CR-only/space-only lines around -> SIDE" '[[ ${out[0]} == SIDE ]]'
printf '\r\n\n  \n' > "$W/etc/vms";         run -pidfile "$(PIDF ${QID1})"; chk "4h11 [PR4] only blank lines -> VENDOR" '[[ ${out[0]} == VENDOR ]]'
printf '1 01\n10 1\n' > "$W/etc/vms";        run -pidfile "$(PIDF ${QID1})"; chk "4h12 [PR4] internal whitespace (1 01 / 10 1) -> VENDOR" '[[ ${out[0]} == VENDOR ]]'
printf ''"${QID1}"'\r\n' > "$W/etc/vms";             run -pidfile "$(PIDF 0${QID1})"; chk "4h13 [PR4] CRLF list ${QID1}, vm path 0${QID1} -> VENDOR (no numeric coercion)" '[[ ${out[0]} == VENDOR ]]'
printf ''"0${QID1}"'\r\n' > "$W/etc/vms";            run -pidfile "$(PIDF ${QID1})"; chk "4h14 [PR4] CRLF list 0${QID1} (leading zero), vm ${QID1} -> VENDOR" '[[ ${out[0]} == VENDOR ]]'
printf ''"${QID1}"'\t# note\r\n' > "$W/etc/vms";     run -pidfile "$(PIDF ${QID1})"; chk "4h15 [PR4] 'id<TAB># note' CRLF -> VENDOR (comment after id does NOT match; documented)" '[[ ${out[0]} == VENDOR ]]'
printf '# c\r\n  # '"${QID1}"'\r\n' > "$W/etc/vms"; run -pidfile "$(PIDF ${QID1})"; chk "4h16 [PR4] indented '# ${QID1}' comment never matches -> VENDOR" '[[ ${out[0]} == VENDOR ]]'
printf '+'"${QID1}"'\n101x\nx101\n'"${QID1}"';ls\n$(id)\n.*\n' > "$W/etc/vms"; run -pidfile "$(PIDF ${QID1})"; chk "4h17 [PR4] regex/shell-ish junk lines never match ${QID1} -> VENDOR" '[[ ${out[0]} == VENDOR ]]'
printf '.*\n[0-9]*\n1.1\n' > "$W/etc/vms";  run -pidfile "$(PIDF ${QID1})"; chk "4h18 [PR4] list lines are literal, not regex ('.*','[0-9]*','1.1') -> VENDOR" '[[ ${out[0]} == VENDOR ]]'
printf ''"0${QID1}"'\n' > "$W/etc/vms";            run -pidfile "$(PIDF ${QID1})"; chk "4k list '0${QID1}' vs vm ${QID1} -> VENDOR" '[[ ${out[0]} == VENDOR ]]'
printf ''"${QID1}"'\n' > "$W/etc/vms";             run -pidfile /var/run/qemu-server/"0${QID1}".pid; chk "4l vm path 0${QID1} vs list ${QID1} -> VENDOR (no numeric coercion)" '[[ ${out[0]} == VENDOR ]]'
printf ''"${QID1}"'' > "$W/etc/vms";               run -pidfile "$(PIDF ${QID1})"; chk "4m no trailing newline at EOF -> SIDE" '[[ ${out[0]} == SIDE ]]'
printf ''"${QID1}"'\n' > "$W/etc/vms";             run -pidfile /var/run/qemu-server/-1.pid -chardev socket,path=/var/run/qemu-server/-1.qmp; chk "4n qemu-server probe vmid -1 -> VENDOR" '[[ ${out[0]} == VENDOR ]]'
run -drive "file=/mnt/qemu-server/${QID1}.pid" -pidfile "$(PIDF ${QID3})"; note "4o edge: unrelated arg containing '/qemu-server/${QID1}.pid' (first match wins) routes to ${out[0]}"
run -name vm -smbios "type=1,serial=a${nl}/var/run/qemu-server/${QID1}.pid" -pidfile "$(PIDF ${QID3})"; note "4p edge: newline-embedded fake path in smbios arg routes to ${out[0]}"

echo "== 5. list file missing / unreadable (running as uid $(id -u))"
vm "${QID1}"; command rm -f "$W/etc/vms"; run -pidfile "$(PIDF ${QID1})"; chk "5a missing list -> VENDOR rc 0, no stderr" '[[ ${out[0]} == VENDOR && $RC -eq 0 && ! -s $W/stderr ]]'
vm "${QID1}"; chmod 000 "$W/etc/vms"
if [[ $(id -u) -ne 0 ]]; then run -pidfile "$(PIDF ${QID1})"; chk "5b chmod 000 list (non-root) -> VENDOR rc 0" '[[ ${out[0]} == VENDOR && $RC -eq 0 ]]' "stderr: $(cat "$W/stderr")"
else
  note "5b running as root: chmod 000 does not hide the file; trying setpriv to nobody"
  if command -v setpriv >/dev/null; then chmod 755 "$W" ; command rm -f "$W/out"; setpriv --reuid=65534 --regid=65534 --clear-groups "$W/kvm" -pidfile "$(PIDF ${QID1})" >/dev/null 2>&1; rc=$?; load; chk "5b unreadable list as nobody -> VENDOR" '[[ ${out[0]} == VENDOR && $rc -eq 0 ]]'; fi
fi
chmod 644 "$W/etc/vms"
vm "${QID1}"; mkdir -p "$W/dirlist"; sed "s#^list=.*#list=$W/dirlist#" "$W/kvm" > "$W/kvm.dl"; chmod 755 "$W/kvm.dl"; command rm -f "$W/out"; "$W/kvm.dl" -pidfile "$(PIDF ${QID1})" >/dev/null 2>&1; rc=$?; load; chk "5c list path is a directory -> VENDOR rc 0" '[[ ${out[0]} == VENDOR && $rc -eq 0 ]]'

echo "== 6. exec semantics"
vm "${QID1}"
for who in "${QID1}" "${QID3}"; do run --exit3 -pidfile "$(PIDF $who)"; chk "6a exit code 3 propagates (vm $who)" '[[ $RC -eq 3 ]]'; done
r=$(printf 'hello\nworld\n' | "$W/kvm" --cat -pidfile "$(PIDF ${QID1})"); chk "6b stdin passthrough (side)" '[[ $r == "hello${nl}world" ]]'
r=$(printf 'hello\nworld\n' | "$W/kvm" --cat -pidfile "$(PIDF ${QID3})"); chk "6b stdin passthrough (vendor)" '[[ $r == "hello${nl}world" ]]'
for who in "${QID1}" "${QID3}"; do
  command rm -f "$W/out.pid" "$W/out.sig"; "$W/kvm" --sleep -pidfile "$(PIDF $who)" >/dev/null 2>&1 & wp=$!
  for _ in $(seq 50); do [[ -s $W/out.pid ]] && break; sleep 0.1; done
  chk "6c wrapper pid == target pid (wrapper replaced by exec) vm $who" '[[ $(cat "$W/out.pid") == "$wp" ]]'
  kill -TERM "$wp"; wait "$wp"; rc=$?; sleep 0.2
  chk "6c SIGTERM delivered to target (handler ran, rc 55) vm $who" '[[ $(cat "$W/out.sig" 2>/dev/null) == 15 && $rc -eq 55 ]]'
done
render "$W/kvm.ms" "$W/kvm.pve" "$W/nonexistent-side"; chmod 755 "$W/kvm.ms"
command rm -f "$W/out"; "$W/kvm.ms" -pidfile "$(PIDF ${QID1})" >/dev/null 2>"$W/stderr"; rc=$?
chk "6d listed + missing side binary: loud failure rc!=0 with message" '[[ $rc -ne 0 && -s $W/stderr ]]' "rc=$rc $(head -1 "$W/stderr")"
command rm -f "$W/out"; "$W/kvm.ms" -pidfile "$(PIDF ${QID3})" >/dev/null 2>&1; rc=$?; load; chk "6d unlisted unaffected by missing side binary" '[[ $rc -eq 0 && ${out[0]} == VENDOR ]]'
printf '#!/bin/true\n' > "$W/noexec"; chmod 644 "$W/noexec"; render "$W/kvm.ne" "$W/kvm.pve" "$W/noexec"; chmod 755 "$W/kvm.ne"
"$W/kvm.ne" -pidfile "$(PIDF ${QID1})" >/dev/null 2>"$W/stderr"; rc=$?; chk "6e listed + non-executable side binary: rc 126, message" '[[ $rc -eq 126 && -s $W/stderr ]]' "rc=$rc"
note "6f listed + broken side: there is NO fallback to vendor (by design, README says bad side build only affects listed VMs)"

echo "== 7. env hazards (env -i, no PATH/HOME, unwritable log)"
vm "${QID1}"
command rm -f "$W/out"; env -i "$W/kvm" -id "${QID1}" -pidfile "$(PIDF ${QID1})" -machine a+pve1 >/dev/null 2>"$W/stderr"; rc=$?; load
chk "7a env -i listed: SIDE, rc 0, -id/+pve handled" '[[ ${out[0]} == SIDE && $rc -eq 0 ]] && same_args -pidfile "$(PIDF '"${QID1}"')" -machine a'
command rm -f "$W/out"; env -i "$W/kvm" -pidfile "$(PIDF ${QID3})" >/dev/null 2>"$W/stderr"; rc=$?; load; chk "7b env -i unlisted: VENDOR rc 0" '[[ ${out[0]} == VENDOR && $rc -eq 0 ]]'
chk "7c env -i: no stderr noise" '[[ ! -s $W/stderr ]]' "$(cat "$W/stderr")"
command rm -f "$W/var/wrapper.log"; run -id "${QID1}" -pidfile "$(PIDF ${QID1})"; chk "7d side start logs 'dropped=-id'" 'grep -q "vmid='"${QID1}"' exec .* dropped=-id" "$W/var/wrapper.log"'
chmod 000 "$W/var/wrapper.log"; run -pidfile "$(PIDF ${QID1})"; chk "7e unwritable log: still SIDE rc 0, quiet" '[[ ${out[0]} == SIDE && $RC -eq 0 && ! -s $W/stderr ]]'; chmod 644 "$W/var/wrapper.log"
sed "s#^log=.*#log=$W/nodir/x.log#" "$W/kvm" > "$W/kvm.nl"; chmod 755 "$W/kvm.nl"; command rm -f "$W/out"; "$W/kvm.nl" -pidfile "$(PIDF ${QID1})" >/dev/null 2>"$W/stderr"; rc=$?; load; chk "7f [PR4/N4] log dir missing: still SIDE rc 0 AND stderr empty" '[[ ${out[0]} == SIDE && $rc -eq 0 && ! -s $W/stderr ]]' "stderr=$(cat "$W/stderr")"
mkdir -p "$W/logdir"; sed "s#^log=.*#log=$W/logdir#" "$W/kvm" > "$W/kvm.ld"; chmod 755 "$W/kvm.ld"; command rm -f "$W/out"; "$W/kvm.ld" -pidfile "$(PIDF ${QID1})" >/dev/null 2>"$W/stderr"; rc=$?; load
chk "7f2 [PR4/N4] log path is a directory: SIDE rc 0, stderr empty" '[[ ${out[0]} == SIDE && $rc -eq 0 && ! -s $W/stderr ]]' "stderr=$(cat "$W/stderr")"
sed "s#^log=.*#log=$W/nodir/x.log#" "$W/kvm" > "$W/kvm.nl"; command rm -f "$W/out"; "$W/kvm.nl" -pidfile "$(PIDF ${QID1})" -machine a+pve1 -id "${QID1}" >/dev/null 2>"$W/stderr"; rc=$?; load
chk "7f3 [PR4/N4] log dir missing: argv still stripped correctly, argv[0] still /usr/bin/kvm" 'same_args -pidfile "$(PIDF '"${QID1}"')" -machine a && [[ ${out[1]} == /usr/bin/kvm ]]'
sed "s#^log=.*#log=$W/nodir/x.log#" "$W/kvm" > "$W/kvm.nl"; command rm -f "$W/out"; "$W/kvm.nl" -pidfile "$(PIDF ${QID3})" >/dev/null 2>"$W/stderr"; rc=$?; load
chk "7f4 [PR4/N4] unlisted + missing log dir: VENDOR, rc 0, stderr empty" '[[ ${out[0]} == VENDOR && $rc -eq 0 && ! -s $W/stderr ]]'
sed "s#^log=.*#log=$W/nodir/x.log#" "$W/kvm" > "$W/kvm.nl"; command rm -f "$W/out"; "$W/kvm.nl" --exit3 -pidfile "$(PIDF ${QID1})" >/dev/null 2>"$W/stderr"; rc=$?
chk "7f5 [PR4/N4] exit code of the target (3) still propagates with a missing log dir" '[[ $rc -eq 3 && ! -s $W/stderr ]]'
command rm -f "$W/kvm.nl" "$W/kvm.ld"
for sh in "bash -u" "bash -e" "bash -eu" "bash -o pipefail -eu"; do command rm -f "$W/out"; $sh "$W/kvm" -id "${QID1}" -pidfile "$(PIDF ${QID1})" >/dev/null 2>&1; rc=$?; load; chk "7g wrapper forced under '$sh' still works" '[[ ${out[0]} == SIDE && $rc -eq 0 ]]'; done

echo "== 8. showcmd parity with the wrapper (same argv through both)"
cat > "$W/qm" <<'EOF'
#!/bin/bash
[[ $1 == showcmd ]] || exit 0
cat "$QM_OUT"
EOF
chmod +x "$W/qm"
cat > "$W/qm.out" <<'EOF'
/usr/bin/kvm \
  -id @QID1@ \
  -name 'my vm+pve5,debug-threads=on' \
  -chardev 'socket,id=qmp,path=/var/run/qemu-server/@QID1@.qmp,server=on,wait=off' \
  -pidfile /var/run/qemu-server/@QID1@.pid \
  -smbios 'type=1,product=it'"'"'s' \
  -machine 'hpet=off,type=pc-q35-10.1+pve0' \
  -iscsi 'initiator-name=iqn.1993-08.org.debian:01:abc'
EOF
sed -i "s/@QID1@/$QID1/g" "$W/qm.out"
printf ''"${QID1}"'\n' > "$W/etc/vms"
sc=$(PATH="$W:$PATH" QM_OUT="$W/qm.out" bash -c "source '$W/lib.sh'; set +eu; SIDE_BIN=SIDEBIN LIST_FILE='$W/etc/vms'; showcmd ${QID1}" 2>&1); last=$(tail -1 <<<"$sc")
# what the wrapper really execs, from the same argv:
eval "set -- $(tail -n +2 "$W/qm.out" | sed 's/\\$//' | tr '\n' ' ' | sed 's/^ *//')"
run "$@"
real_line=$(printf '%q ' SIDEBIN "${out[@]:3}")
chk "8a showcmd last line == %q-rendering of argv the wrapper actually execs" '[[ $last == "$real_line" ]]' "showcmd: $last | wrapper: $real_line"
chk "8b showcmd for listed VM says it IS what gets exec'd; -id dropped; name keeps +pve5; machine +pve0 stripped" '[[ $sc == *"IS listed"* && $last != *" -id "* && $last == *+pve5* && $last != *pve0* ]]'
sc2=$(PATH="$W:$PATH" QM_OUT="$W/qm.out" bash -c "source '$W/lib.sh'; set +eu; SIDE_BIN=SIDEBIN LIST_FILE='$W/etc/vms'; showcmd ${QID3}" 2>&1)
chk "8c showcmd for unlisted VM states it uses vendor binary unchanged (no stripping of vendor output)" '[[ $sc2 == *"NOT listed"* && $sc2 == *"+pve0"* ]]'
chk "8d vendor view printed verbatim (qm showcmd --pretty output still contains -id and +pve0)" '[[ $sc == *"-id '"${QID1}"'"* && $sc == *"+pve0"* ]]'
chk "8e README says 'stripped side argv'" 'grep -q "stripped side argv" "$(dirname "$SCRIPT")/README.md"'

echo "== 9. install / uninstall / preflight with real dpkg-divert on a throwaway admindir"
if command -v dpkg-divert >/dev/null; then
  mkdir -p "$W/stubbin" "$W/adm"; : > "$W/adm/diversions"; : > "$W/adm/status"; mkdir -p "$W/adm/updates" "$W/adm/info"
  printf '#!/bin/bash\nexec /usr/bin/dpkg-divert --admindir "%s" "$@"\n' "$W/adm" > "$W/stubbin/dpkg-divert"
  for t in apt-get; do printf '#!/bin/bash\nexit 0\n' > "$W/stubbin/$t"; done
  printf '#!/bin/bash\nd="";while [[ $# -gt 0 ]];do [[ $1 == -C ]]&&{ d=$2;shift;};shift;done;mkdir -p "$d/qemu-9.9.9"; printf "#!/bin/bash\\nexit 0\\n" > "$d/qemu-9.9.9/configure"; chmod +x "$d/qemu-9.9.9/configure"\n' > "$W/stubbin/tar"
  printf '#!/bin/bash\ncase "$1" in clone) d="${@: -1}"; mkdir -p "$d/.git"; echo p > "$d/qemu-9.9.9.patch";; esac\n' > "$W/stubbin/git"
  printf '#!/bin/bash\n[[ ${1:-} == apply ]] && exit 0; exit 0\n' > /dev/null
  printf '#!/bin/bash\nif [[ ${1:-} == install ]]; then mkdir -p "$MK/bin"; printf "#!/bin/bash\\necho QEMU emulator version 9.9.9\\n" > "$MK/bin/qemu-system-x86_64"; chmod +x "$MK/bin/qemu-system-x86_64"; fi; exit 0\n' > "$W/stubbin/make"
  printf '#!/bin/bash\nout="";while [[ $# -gt 0 ]];do [[ $1 == -O ]]&&{ out=$2;shift;};shift;done; echo t > "$out"\n' > "$W/stubbin/wget"
  printf '#!/bin/bash\nexit 0\n' > "$W/stubbin/nproc.unused"
  chmod +x "$W/stubbin/"*
  H=$W/h
  host() { command rm -rf "$H"; mkdir -p "$H/bin" "$H/src" "$H/etc"; : > "$W/adm/diversions"; printf 'vendor-real\n' > "$H/bin/kvm"; chmod 755 "$H/bin/kvm"; }
  # git stub must also make `git -C SRC apply` succeed
  ENVV() { env PATH="$W/stubbin:$PATH" MK="$H/opt" QEMU_VER=9.9.9 QEMU_SHA256= PATCH_SHA256= PREFIX="$H/opt" SRC_ROOT="$H/src" WRAPPER_PATH="$H/bin/kvm" VENDOR_PATH="$H/bin/kvm.pve" LIST_FILE="$H/etc/vms" LOG_FILE="$H/log" DPKG_LOCK="${DPKG_LOCK:-$H/nolock}" "$@"; }
  # EUID check: run the library with need_root neutralised (we are not root and must not be)
  DRIVER='source "$LIBF"; need_root(){ :; }; main "$@"'
  runscript() { ENVV LIBF="$LIBF" bash -c "set -euo pipefail; $DRIVER" qad "$@"; }
  for tag in PR3 BASE; do
    if [[ $tag == PR3 ]]; then LIBF=$W/lib.sh; else
      [[ -n ${BASE_SCRIPT:-} ]] || { note "9-BASE skipped (set BASE_SCRIPT=/path/to/main/qemu-ad-pve.sh to reproduce the old trap bug)"; continue; }
      sed '$d' "$BASE_SCRIPT" > "$W/lib.base.sh"; LIBF=$W/lib.base.sh; fi
    host; runscript install >"$W/inst.out" 2>"$W/inst.err"; rc=$?
    if [[ $tag == PR3 ]]; then
      chk "9a[$tag] 'main install' (set -euo pipefail, bash $BASH_VERSION) exits 0" '[[ $rc -eq 0 ]]' "rc=$rc $(tail -2 "$W/inst.err")"
      chk "9a[$tag] no 'unbound variable'" '! grep -q "unbound variable" "$W/inst.err"'
      chk "9a[$tag] result: wrapper at kvm, vendor at kvm.pve, divert recorded (real dpkg-divert), no staged leftover" 'grep -q "Generated by qemu-ad-pve" "$H/bin/kvm" && grep -qx vendor-real "$H/bin/kvm.pve" && /usr/bin/dpkg-divert --admindir "$W/adm" --list "$H/bin/kvm" | grep -q "$H/bin/kvm.pve" && [[ ! -e $H/bin/kvm.qemu-ad-new ]]'
      runscript install >/dev/null 2>&1; chk "9b[$tag] idempotent second install exits 0" '[[ $? -eq 0 ]]'
    else
      chk "9a[$tag] REPRODUCES old bug: install rc!=0 with 'staged: unbound variable'" '[[ $rc -ne 0 ]] && grep -q "unbound variable" "$W/inst.err"' "rc=$rc"
    fi
  done
  # uninstall
  host; LIBF=$W/lib.sh; runscript install >/dev/null 2>&1; runscript uninstall >/dev/null 2>"$W/un.err"; rc=$?
  chk "9c uninstall rc 0, kvm is vendor again, kvm.pve gone, divert removed" '[[ $rc -eq 0 ]] && grep -qx vendor-real "$H/bin/kvm" && [[ ! -e $H/bin/kvm.pve ]] && ! /usr/bin/dpkg-divert --admindir "$W/adm" --list "$H/bin/kvm" | grep -q .'
  runscript uninstall >/dev/null 2>&1; chk "9c' second uninstall rc 0" '[[ $? -eq 0 ]]'
  # missing kvm preflight (real dpkg-divert --rename silent no-op demonstrated first)
  host; command rm -f "$H/bin/kvm"
  /usr/bin/dpkg-divert --admindir "$W/adm" --local --rename --divert "$H/bin/kvm.pve" "$H/bin/kvm" >"$W/dd.out" 2>&1; ddrc=$?
  note "9d control: real 'dpkg-divert --rename' on missing source: rc=$ddrc, divert recorded=$(/usr/bin/dpkg-divert --admindir "$W/adm" --list "$H/bin/kvm" | wc -l), file created=$([[ -e $H/bin/kvm.pve ]] && echo yes || echo no)"
  host; command rm -f "$H/bin/kvm"; runscript install >"$W/o" 2>"$W/e"; rc=$?
  chk "9d missing kvm: install refuses (rc!=0), clear message, NO divert recorded, no kvm.pve, no wrapper" '[[ $rc -ne 0 ]] && grep -q "does not exist" "$W/e" && ! /usr/bin/dpkg-divert --admindir "$W/adm" --list "$H/bin/kvm" | grep -q . && [[ ! -e $H/bin/kvm.pve && ! -e $H/bin/kvm ]]'
  # real fcntl lock held by another process
  host; printf x > "$W/lockf"
  python3 - "$W/lockf" "$W/lock.ready" <<'PY' &
import fcntl,sys,time
f=open(sys.argv[1],'w'); fcntl.lockf(f,fcntl.LOCK_EX); open(sys.argv[2],'w').write('1'); time.sleep(25)
PY
  lp=$!; for _ in $(seq 50); do [[ -e $W/lock.ready ]] && break; sleep 0.1; done
  note "9e /proc/locks while python lockf holds: $(grep ":$(stat -c %i "$W/lockf")\b" /proc/locks | head -1)"
  DPKG_LOCK=$W/lockf runscript install >/dev/null 2>"$W/e"; rc=$?
  chk "9e fcntl lock held: install refuses (rc!=0) with 'holds', kvm untouched, no divert" '[[ $rc -ne 0 ]] && grep -q "holds" "$W/e" && grep -qx vendor-real "$H/bin/kvm" && ! /usr/bin/dpkg-divert --admindir "$W/adm" --list "$H/bin/kvm" | grep -q .'
  chk "9e control: flock(1) cannot see an fcntl lock" '! flock -n "$W/lockf" true 2>/dev/null || true'
  kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
  command rm -f "$W/lock.ready"; DPKG_LOCK=$W/lockf runscript install >/dev/null 2>&1; chk "9e lock released: install proceeds" '[[ $? -eq 0 && -f $H/bin/kvm.pve ]]'
  # uninstall with lock held
  python3 - "$W/lockf" "$W/lock.ready" <<'PY' &
import fcntl,sys,time
f=open(sys.argv[1],'w'); fcntl.lockf(f,fcntl.LOCK_EX); open(sys.argv[2],'w').write('1'); time.sleep(20)
PY
  lp=$!; for _ in $(seq 50); do [[ -e $W/lock.ready ]] && break; sleep 0.1; done
  DPKG_LOCK=$W/lockf runscript uninstall >/dev/null 2>"$W/e"; rc=$?
  chk "9f lock held: uninstall refuses, wrapper + kvm.pve + divert untouched" '[[ $rc -ne 0 ]] && grep -q "Generated by qemu-ad-pve" "$H/bin/kvm" && [[ -e $H/bin/kvm.pve ]] && /usr/bin/dpkg-divert --admindir "$W/adm" --list "$H/bin/kvm" | grep -q kvm.pve'
  kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
  # lock on a DIFFERENT file with same inode on another fs cannot be tested portably; lock on a different file must not block
  printf y > "$W/otherlock"; python3 - "$W/otherlock" "$W/lock.ready2" <<'PY' &
import fcntl,sys,time
f=open(sys.argv[1],'w'); fcntl.lockf(f,fcntl.LOCK_EX); open(sys.argv[2],'w').write('1'); time.sleep(8)
PY
  lp=$!; for _ in $(seq 50); do [[ -e $W/lock.ready2 ]] && break; sleep 0.1; done
  host; DPKG_LOCK=$W/lockf runscript install >/dev/null 2>&1; chk "9g lock on an unrelated file does not block install" '[[ $? -eq 0 ]]'
  kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
  # kvm presence during install/uninstall (poll)
  host; ( while :; do [[ -e $H/bin/kvm ]] || echo MISSING >> "$W/poll.log"; done ) & pp=$!
  runscript install >/dev/null 2>&1; runscript uninstall >/dev/null 2>&1; kill $pp 2>/dev/null; wait $pp 2>/dev/null
  chk "9h /usr/bin/kvm equivalent never missing during install+uninstall (busy poll)" '[[ ! -s $W/poll.log ]]'
  # symlink-vendor kvm (e.g. alternatives): -P preserves symlink
  host; command rm -f "$H/bin/kvm"; printf 'vend\n' > "$H/bin/real-kvm"; chmod 755 "$H/bin/real-kvm"; ln -s real-kvm "$H/bin/kvm"
  runscript install >/dev/null 2>&1; chk "9i vendor kvm being a symlink: copied as symlink (kvm.pve is link)" '[[ -L $H/bin/kvm.pve ]]'
  runscript uninstall >/dev/null 2>&1; chk "9i uninstall restores symlink" '[[ -L $H/bin/kvm ]]'
  # [PR4/N5] uninstall/install/status after `apt remove pve-qemu-kvm` (kvm.pve gone), REAL dpkg-divert on throwaway admindir
  host; runscript install >/dev/null 2>&1; command rm -f "$H/bin/kvm.pve"
  cp "$H/bin/kvm" "$W/n5.wrapper.sha.src"; divbefore=$(/usr/bin/dpkg-divert --admindir "$W/adm" --list); listbefore=$(ls -la "$H/bin" | awk '{print $1,$5,$9}')
  runscript uninstall >"$W/n5.out" 2>"$W/n5.err"; rc=$?
  chk "9j [PR4/N5] vendor gone: uninstall refuses (rc!=0)" '[[ $rc -ne 0 ]]'
  chk "9j2 [PR4/N5] error names the problem and the recovery (reinstall pve-qemu-kvm, then uninstall)" 'grep -q "is missing" "$W/n5.err" && grep -q "apt install --reinstall pve-qemu-kvm" "$W/n5.err" && grep -q "uninstall" "$W/n5.err"'
  chk "9j3 [PR4/N5] no half-state: divert record unchanged, wrapper still in place byte-identical, still no kvm.pve" '[[ $(/usr/bin/dpkg-divert --admindir "$W/adm" --list) == "$divbefore" ]] && cmp -s "$H/bin/kvm" "$W/n5.wrapper.sha.src" && [[ ! -e $H/bin/kvm.pve && ! -L $H/bin/kvm.pve ]] && [[ $(ls -la "$H/bin" | awk "{print \$1,\$5,\$9}") == "$listbefore" ]]'
  runscript install >"$W/n5.out" 2>"$W/n5.err"; rc=$?
  chk "9k [PR4/N5] vendor gone: install also refuses with the same hint, wrapper untouched, no staged leftover" '[[ $rc -ne 0 ]] && grep -q "apt install --reinstall" "$W/n5.err" && cmp -s "$H/bin/kvm" "$W/n5.wrapper.sha.src" && [[ ! -e $H/bin/kvm.qemu-ad-new ]]'
  st=$(ENVV LIBF="$LIBF" bash -c "source \"\$LIBF\"; need_root(){ :; }; have_pve(){ return 1; }; status" 2>&1)
  chk "9l [PR4/N5] status shows WARNING + hint in that state" '[[ $st == *WARNING* && $st == *"apt install --reinstall"* ]]'
  printf 'vendor-reinstalled\n' > "$H/bin/kvm.pve"   # what dpkg does on `apt install --reinstall pve-qemu-kvm` for a diverted path
  runscript uninstall >/dev/null 2>&1; rc=$?
  chk "9m [PR4/N5] after reinstall of the package: uninstall works, restores vendor binary, divert gone" '[[ $rc -eq 0 ]] && grep -qx vendor-reinstalled "$H/bin/kvm" && ! /usr/bin/dpkg-divert --admindir "$W/adm" --list "$H/bin/kvm" | grep -q .'
  host; runscript install >/dev/null 2>&1; command rm -f "$H/bin/kvm.pve"; printf 'vendor-reinstalled\n' > "$H/bin/kvm.pve"; runscript install >/dev/null 2>"$W/n5i.err"; rc=$?
  chk "9m2 [PR4/N5] hint alternative: after package reinstall, 'install' (keep setup) also works: rc 0, wrapper in place, vendor kept" '[[ $rc -eq 0 ]] && grep -q "Generated by qemu-ad-pve" "$H/bin/kvm" && grep -qx vendor-reinstalled "$H/bin/kvm.pve"'
  host; runscript install >/dev/null 2>&1; st=$(ENVV LIBF="$LIBF" bash -c "source \"\$LIBF\"; need_root(){ :; }; have_pve(){ return 1; }; status" 2>&1)
  chk "9n [PR4/N5] healthy state: status has no WARNING" '[[ $st != *WARNING* ]]'
else note "section 9 skipped: no dpkg-divert"; fi

echo "== 10. purge guards (rm shadowed; nothing is removed)"
purge() { # purge <PREFIX> <LIST_FILE>
  command rm -f "$W/rm.log"
  bash -c "source '$W/lib.sh'; set -euo pipefail; rm(){ echo \"RM \$*\" >> '$W/rm.log'; }; need_root(){ :; }
    dpkg-divert(){ return 0; }; PREFIX=\"\$1\" LIST_FILE=\"\$2\" WRAPPER_PATH='$W/nowrap' VENDOR_PATH='$W/novend'; uninstall --purge" qad "$1" "$2" >/dev/null 2>&1; echo $?; }
for p in '' / /usr /etc /opt /opt/ /usr/local /usr/local/bin /usr/local/lib /srv /unlisted/x relative/opt opt/x /opt/../usr /opt//x /var/lib/x; do
  r=$(purge "$p" /etc/qemu-ad/vms); chk "10a reject PREFIX='$p'" '[[ $r -ne 0 && ! -s $W/rm.log ]]'; done
for p in /opt/qemu-ad /usr/local/qemu-ad /srv/qad; do r=$(purge "$p" /etc/qemu-ad/vms); chk "10b allow PREFIX='$p' (default LIST_FILE)" '[[ $r -eq 0 && -s $W/rm.log ]]'; done
for l in '' / /etc /etc/qemu-ad /etc/passwd /usr/bin/kvm /root/x relative/vms /etc/qemu-ad/../passwd /etc/qemu-ad/ /unlisted/x/vms /var/lib /var/lib/dpkg/x '//etc/qemu-ad/vms' /usr /opt /usr/local /usr/local/ /etc/qemu-ad/. /usr/local/bin /usr/local/share /usr/local/lib /opt/qemu-ad /opt/qemu-ad/ /srv/x/vms /etc/qemu-ad/./vms /var/lib/qemu-ad/. /var/lib/qemu-ad/./x /var/lib/qemu-ad /var/lib/qemu-ad/ '..' '//' /etc/qemu-adx/vms /etc/qemu-ad-x /opt/qad/vms ; do
  r=$(purge /opt/qemu-ad "$l"); chk "10c reject LIST_FILE='$l'" '[[ $r -ne 0 && ! -s $W/rm.log ]]'; done
for l in /etc/qemu-ad/vms /var/lib/qemu-ad/vms /var/lib/qemu-ad/x '/etc/qemu-ad/a b' /etc/qemu-ad/.hidden; do r=$(purge /opt/qemu-ad "$l"); chk "10d allow LIST_FILE='$l' (PR4: only /etc/qemu-ad or /var/lib/qemu-ad)" '[[ $r -eq 0 ]] && grep -qxF "RM -f $l" "$W/rm.log" && grep -qx "RM -rf /opt/qemu-ad" "$W/rm.log"'; done
# [PR4/N1] LIST_FILE=/opt/qad/vms was allowed on PR #3 and is now (intentionally) rejected; rejected list is in 10c
for p in /usr/local/./bin /usr/local/./lib /opt/. /opt/./x /opt/qemu-ad/. /opt/x/./y; do r=$(purge "$p" /etc/qemu-ad/vms); chk "10f [PR4/N1] reject PREFIX='$p' (dot component)" '[[ $r -ne 0 && ! -s $W/rm.log ]]'; done
for p in /usr/local/bin/x /opt/.hidden /opt/a/b; do r=$(purge "$p" /etc/qemu-ad/vms); chk "10g PREFIX='$p' allowed (not a dot COMPONENT / not a system dir itself)" '[[ $r -eq 0 && -s $W/rm.log ]]'; done
r=$(purge /opt/qemu-ad /etc/qemu-ad/vms); chk "10h [PR4/N1] purge uses 'rm -f' for LIST_FILE and 'rm -rf' for PREFIX only" '[[ $r -eq 0 ]] && [[ $(grep -c "^RM -rf" "$W/rm.log") -eq 1 && $(grep -c "^RM -f" "$W/rm.log") -eq 1 && $(grep -c "^RM -rf /etc" "$W/rm.log") -eq 0 ]]'
# directory refusal + symlinks need a real /etc/qemu-ad: fake /etc with a tmpfs in a user+mount namespace (real /etc untouched)
if unshare -Urm bash -c 'mount -t tmpfs none /etc' 2>/dev/null; then
  pn() { unshare -Urm bash -c "mount -t tmpfs none /etc && mkdir -p /etc/qemu-ad/adir && ln -s /usr /etc/qemu-ad/symusr && ln -s adir /etc/qemu-ad/symdir && : > /etc/qemu-ad/vms; source '$W/lib.sh'; set -euo pipefail; rm(){ echo \"RM \$*\" >> '$W/rm.log'; }; need_root(){ :; }; dpkg-divert(){ return 0; }; PREFIX=/opt/qemu-ad LIST_FILE=\"\$1\" WRAPPER_PATH='$W/nowrap' VENDOR_PATH='$W/novend'; uninstall --purge" q "$1" >/dev/null 2>&1; echo $?; }
  for l in /etc/qemu-ad/adir /etc/qemu-ad/symusr /etc/qemu-ad/symdir; do command rm -f "$W/rm.log"; r=$(pn "$l"); chk "10i [PR4/N1] LIST_FILE='$l' (directory or symlink to a directory) refused, nothing removed" '[[ $r -ne 0 && ! -s $W/rm.log ]]'; done
  command rm -f "$W/rm.log"; r=$(pn /etc/qemu-ad/vms); chk "10i control: regular file in the same fake /etc/qemu-ad is allowed" '[[ $r -eq 0 ]] && grep -qxF "RM -f /etc/qemu-ad/vms" "$W/rm.log"'
else note "10i skipped: no unshare -Urm"; fi
# bypass probes: report, not assert (these are findings if they are ALLOWED)
for pl in "PREFIX=/usr/local/./bin" "PREFIX=/usr/local/./lib" "PREFIX=/opt/." "LIST_FILE=/usr/local/bin" "LIST_FILE=/usr/local/share" "LIST_FILE=/etc/qemu-ad/." "LIST_FILE=/opt/qemu-ad" "LIST_FILE=/srv/x/.."; do
  P=/opt/qemu-ad; L=/etc/qemu-ad/vms; [[ $pl == PREFIX=* ]] && P=${pl#PREFIX=} || L=${pl#LIST_FILE=}
  r=$(purge "$P" "$L"); chk "10e [PR4/N1] bypass probe refused: $pl" '[[ $r -ne 0 && ! -s $W/rm.log ]]'; done
# refused purge must not half-uninstall
echo "== 11. add-vm / del-vm"
L() { bash -c "source '$W/lib.sh'; set -euo pipefail; LIST_FILE='$W/lv/vms'; $1" >/dev/null 2>&1; }
for v in 0 00 007 0200 abc 1a '' ' 5' -1 1.5; do mkdir -p "$W/lv"; command rm -f "$W/lv/vms"; L "add_vm '$v'"; rc=$?; chk "11a add-vm rejects '$v'" '[[ $rc -ne 0 && ! -s $W/lv/vms ]]'; done
for v in 1 "${QID2}" 4294967295; do command rm -f "$W/lv/vms"; L "add_vm $v"; chk "11b add-vm accepts $v" '[[ $? -eq 0 ]] && grep -qx $v "$W/lv/vms"'; done
L "add_vm 1"; chk "11c add-vm idempotent" '[[ $(grep -c "^1$" "$W/lv/vms") -eq 1 ]]'
printf ''"${QID2}"'\n'"${QID1}"'\n'"${QID3}"'\n' > "$W/lv/vms"; chmod 640 "$W/lv/vms"; L 'del_vm '"${QID1}"''; chk "11d del-vm removes exactly that id, keeps mode" '[[ $(tr "\n" " " < "$W/lv/vms") == "'"${QID2}"' '"${QID3}"' " && $(stat -c %a "$W/lv/vms") == 640 ]]'
chk "11e del-vm temp file is created beside the list (same fs, atomic mv) and not left" 'grep -q "mktemp \"\${LIST_FILE}.XXXXXX\"" "$SCRIPT" && [[ $(ls "$W/lv" | wc -l) -eq 1 ]]'
for v in 0 007; do printf '5\n' > "$W/lv/vms"; L "del_vm $v"; chk "11f del-vm rejects $v" '[[ $? -ne 0 ]]'; done
# [PR4/N3] CRLF / whitespace semantics shared by add-vm, del-vm
printf ''"${QID2}"'\r\n' > "$W/lv/vms"; L 'add_vm '"${QID2}"''; chk "11g [PR4/N3] add-vm ${QID2} on CRLF list: no duplicate, file byte-identical" '[[ $(od -An -c "$W/lv/vms" | tr -d " \n") == "'"${QID2}"'\\r\\n" ]]'
printf ' '"${QID2}"' \n' > "$W/lv/vms"; L 'add_vm '"${QID2}"''; chk "11g2 [PR4/N3] add-vm on space-padded line: no duplicate" '[[ $(wc -l < "$W/lv/vms") -eq 1 ]]'
printf ''"${QID2}"'\r\n' > "$W/lv/vms"; L 'add_vm '"${QID1}"''; chk "11g3 [PR4/N3] add-vm ${QID1} onto CRLF list: appended after, ${QID2}\\r\\n kept byte-exact" '[[ $(od -An -c "$W/lv/vms" | tr -d " \n") == "'"${QID2}"'\\r\\n'"${QID1}"'\\n" ]]'
printf ''"${QID2}"'' > "$W/lv/vms"; L 'add_vm '"${QID1}"''; chk "11g4 [PR4] add-vm when last line lacks newline: ids not glued (${QID2}\\n${QID1}\\n)" '[[ $(od -An -c "$W/lv/vms" | tr -d " \n") == "'"${QID2}"'\\n'"${QID1}"'\\n" ]]'
printf '10 # note\n' > "$W/lv/vms"; L 'add_vm 10'; chk "11g5 [PR4] add-vm 10 where list has '10 # note' (comment => not a match): appends 10 (consistent with wrapper)" '[[ $(tail -1 "$W/lv/vms") == 10 && $(wc -l < "$W/lv/vms") -eq 2 ]]'
printf ''"${QID2}"'\r\n'"${QID1}"'\r\n'"${QID3}"'\r\n' > "$W/lv/vms"; chmod 640 "$W/lv/vms"; L 'del_vm '"${QID1}"''; chk "11h [PR4/N3] del-vm ${QID1} on CRLF list removes the CRLF line, others byte-exact, mode kept" '[[ $(od -An -c "$W/lv/vms" | tr -d " \n") == "'"${QID2}"'\\r\\n'"${QID3}"'\\r\\n" && $(stat -c %a "$W/lv/vms") == 640 ]]'
printf '  '"${QID1}"'\t\r\n5\n' > "$W/lv/vms"; L 'del_vm '"${QID1}"''; chk "11h2 [PR4/N3] del-vm removes space/tab padded + CR line" '[[ $(od -An -c "$W/lv/vms" | tr -d " \n") == "5\\n" ]]'
printf '10\r\n'"${QID1}0"'\r\n'"${QID1}"'\r\n' > "$W/lv/vms"; L 'del_vm 10'; chk "11h3 [PR4] del-vm 10 does not touch ${QID1}/${QID1}0 (whole-line only)" '[[ $(od -An -c "$W/lv/vms" | tr -d " \n") == "'"${QID1}0"'\\r\\n'"${QID1}"'\\r\\n" ]]'
printf ''"${QID1}"' # keep\n# '"${QID1}"'\n' > "$W/lv/vms"; L 'del_vm '"${QID1}"''; chk "11h4 [PR4] del-vm ${QID1} leaves '${QID1} # keep' and '# ${QID1}' alone (consistent with wrapper non-match)" '[[ $(wc -l < "$W/lv/vms") -eq 2 ]]'
printf ''"${QID1}"'\r\n' > "$W/lv/vms"; L 'del_vm '"${QID1}"''; chk "11h5 [PR4] del-vm of the only (CRLF) id leaves an empty file, rc 0, no temp left" '[[ ! -s $W/lv/vms && $(ls "$W/lv" | wc -l) -eq 1 ]]'
printf '5\n' > "$W/lv/vms"; # status prints CRLF lines (cosmetic) and showcmd uses the same matcher as the wrapper
printf ''"${QID1}"'\r\n' > "$W/lv/vms"; command rm -f "$W/rm.log"
sc3=$(PATH="$W:$PATH" QM_OUT="$W/qm.out" bash -c "source '$W/lib.sh'; set +eu; SIDE_BIN=SIDEBIN LIST_FILE='$W/lv/vms'; showcmd ${QID1}" 2>&1)
chk "11j [PR4/N3] showcmd ${QID1} with a CRLF list says IS listed (same matcher as wrapper)" '[[ $sc3 == *"IS listed"* ]]'
sc3=$(PATH="$W:$PATH" QM_OUT="$W/qm.out" bash -c "source '$W/lib.sh'; set +eu; SIDE_BIN=SIDEBIN LIST_FILE='$W/lv/vms'; showcmd ${QID3}" 2>&1)
chk "11k [PR4] showcmd ${QID3} with a CRLF list says NOT listed" '[[ $sc3 == *"NOT listed"* ]]'
# README documents exactly these semantics
RD="$(dirname "$SCRIPT")/README.md"
chk "11l [PR4/N3] README documents whitespace/CR ignored + comment not matching + add-vm/del-vm CRLF" 'grep -q "leading or trailing whitespace and a trailing carriage return" "$RD" && grep -q "does not append a duplicate" "$RD" && grep -q "comment after the number" "$RD"'

# ---- 12. [PR4/N2] docs: usage() lists every env override, README lists them, header corrected
echo "== 12. docs (N2)"
vars=$(grep -o '\${[A-Z_0-9]*:-' "$SCRIPT" | sed 's/^\${//; s/:-$//' | sort -u | grep -E '^[A-Z]' | grep -vxE 'PATH|HOME|EUID')
us=$(bash "$SCRIPT" help 2>&1); miss_u=""; miss_r=""
for v in $vars; do grep -qE "^ +$v( |=)" <<<"$us" || miss_u+=" $v"; grep -q "\`$v\`" "$RD" || miss_r+=" $v"; done
chk "12a [PR4/N2] usage() lists every \${VAR:-} override ($(echo $vars))" '[[ -z $miss_u ]]' "missing:$miss_u"
chk "12b [PR4/N2] README lists every override" '[[ -z $miss_r ]]' "missing:$miss_r"
chk "12c [PR4/N2] DPKG_LOCK documented in usage() and README" 'grep -q "DPKG_LOCK" <<<"$us" && grep -q "DPKG_LOCK" "$RD"'
chk "12d [PR4/N2] header: hidden=1 -> kvm=off, does NOT clear hypervisor bit; old claim gone" 'grep -q "turns it into kvm=off" "$SCRIPT" && ! grep -q "hypervisor bit clear" "$SCRIPT"'
chk "12e [PR4/N2] header: +pve stripped only inside -machine/-M; old 'each argument' claim gone" 'grep -q "only inside the value of" "$SCRIPT" && ! grep -q "from each argument" "$SCRIPT"'

# ---- 13. [PR5] BUG-A configure flags / deps, BUG-B skew warnings (FP/FN matrix), wrapper untouched, printf -v, purge text
echo "== 13. PR5"
QV=$(grep -m1 -o 'QEMU_VER="${QEMU_VER:-[0-9.]*' "$SCRIPT" | grep -o '[0-9.]*$')
chk "13a [PR5/A] install_deps lists libgcrypt20-dev and no libgnutls*-dev" 'sed -n "/^install_deps()/,/^}/p" "$SCRIPT" | grep -q "libgcrypt20-dev" && ! sed -n "/^install_deps()/,/^}/p" "$SCRIPT" | grep -qi gnutls'
fl=$(sed -n '/^QAD_CONFIGURE_FLAGS=(/,/^)/p' "$SCRIPT")
for f in --enable-gcrypt --disable-gnutls --enable-kvm --enable-linux-aio --enable-linux-io-uring --enable-libiscsi --target-list=x86_64-softmmu --disable-docs --disable-werror; do
  chk "13b [PR5/A] QAD_CONFIGURE_FLAGS has $f" 'grep -qx " *$f" <<<"$fl"'; done
chk "13c [PR5/A] build_qemu passes the array to ./configure and stamps it after the build" 'grep -q "./configure --prefix=\"\$PREFIX\" \"\${QAD_CONFIGURE_FLAGS\[@\]}\"" "$SCRIPT" && grep -q "QAD_CONFIGURE_FLAGS\[\*\]}\" > \"\$(build_stamp)\"" "$SCRIPT"'
chk "13d [PR5/A] no --enable-gnutls / nettle / spice anywhere in the script" '! grep -qE -- "--enable-(gnutls|nettle|spice|rbd)" "$SCRIPT"'
# BUG-B matrix: qad_skew_warnings with side 10.2.2 stub
printf '#!/bin/bash\necho "QEMU emulator version 10.2.2 (stub)"\n' > "$W/side102"; chmod +x "$W/side102"
skw() { bash -c "source '$W/lib.sh'; set +eu; SIDE_BIN='$W/side102'; QEMU_VER=10.2.2; qad_skew_warnings \"\$@\"" _ "$@" 2>&1 | grep -c '^WARNING'; }
fp() { local l=$1; shift; SK=("$@"); chk "13e [PR5/B] no false positive: $l" '[[ $(skw "${SK[@]}") -eq 0 ]]'; }
tp() { local l=$1; shift; SK=("$@"); chk "13f [PR5/B] warns: $l" '[[ $(skw "${SK[@]}") -ge 1 ]]'; }
fp "-name rbd-spice-qxl-loadstate" -name rbd-spice-qxl-loadstate
fp "-name pc-q35-11.0-test" -name pc-q35-11.0-test
fp "-drive file=/mnt/rbd:x.raw" -drive file=/mnt/rbd:x.raw
fp "-drive file=/var/lib/vz/images/rbd.qcow2" -drive file=/var/lib/vz/images/rbd.qcow2
fp "-drive file=/dev/zvol/spice/qxl-disk" -drive file=/dev/zvol/spice/qxl-disk,if=none
fp "-device virtio-net-pci,id=qxl0" -device virtio-net-pci,id=qxl0
fp "-smbios product=-x" -smbios type=1,product=pc-q35-11.0-x,serial=rbd:y
fp "-machine pc-q35-10.2+pve0" -machine type=pc-q35-10.2+pve0
fp "-machine pc-q35-9.10" -machine type=pc-q35-9.10
fp "-machine pc-q35-2.4" -machine type=pc-q35-2.4
fp "-machine q35 (unversioned)" -machine q35
fp "-cpu host" -cpu host
tp "-spice port=1" -spice port=1
tp "-device qxl-vga" -device qxl-vga,id=v
tp "-device qxl" -device qxl,id=v
tp "-machine type=pc-q35-11.0+pve0" -machine type=pc-q35-11.0+pve0
tp "-machine hpet=off,type=pc-q35-11.0+pve0" -machine hpet=off,type=pc-q35-11.0+pve0
tp "-M pc-i440fx-11.0" -M pc-i440fx-11.0
tp "-machine pc-q35-10.3" -machine pc-q35-10.3
tp "-drive file=rbd:pool/vm" -drive file=rbd:pool/vm-1-disk-0,if=none
tp "-drive if=none,file=rbd: (not first key)" -drive if=none,id=d,file=rbd:pool/vm
tp "-drive file=pbs:" -drive file=pbs:x
tp "-loadstate" -loadstate /dev/x
# KNOWN GAPS (documented INFO, not asserted as pass): see REPORT PR5
for c in "-vga qxl" "-blockdev driver=rbd" "-drive file.driver=rbd" "-loadstate=x" "-machine=pc-q35-11.0" "-cpu SapphireRapids-v5"; do :; done
note "13g [PR5/B] known FN (warning not emitted): '-vga qxl', '-blockdev driver=rbd', '-drive file.driver=rbd', '-cpu <newer model>', 'RBD:' upper case; known FP: '-name -spice' (option VALUE exactly equal to -spice/-loadstate)"
# warnings only in showcmd, only for listed, never on stderr, side line identical to base logic
printf ''"${QID1}"'\n' > "$W/etc/vms5"; cat > "$W/qm5.out" <<'EOF'
/usr/bin/kvm \
  -id @QID1@ \
  -spice port=1 \
  -machine type=pc-q35-11.0+pve0 \
  -loadstate /dev/x
EOF
sed -i "s/@QID1@/$QID1/g" "$W/qm5.out"
sc5=$(PATH="$W:$PATH" QM_OUT="$W/qm5.out" bash -c "source '$W/lib.sh'; set +eu; SIDE_BIN='$W/side102'; LIST_FILE='$W/etc/vms5'; showcmd ${QID1}" 2>"$W/sc5.err"); rc5=$?
chk "13h [PR5/B] showcmd listed: >=3 WARNING lines on STDOUT, stderr empty, rc 0" '[[ $(grep -c "^WARNING" <<<"$sc5") -ge 3 && ! -s $W/sc5.err && $rc5 -eq 0 ]]'
chk "13i [PR5/B] WARNING lines come after the exec-view line (the %q argv line is still the one before them)" 'l=$(grep -n "^WARNING" <<<"$sc5" | head -1 | cut -d: -f1); prev=$(sed -n "$((l-1))p" <<<"$sc5"); [[ $prev == *"-spice"* && $prev == *"-loadstate"* && $prev != *"-id "* ]]'
sc5u=$(PATH="$W:$PATH" QM_OUT="$W/qm5.out" bash -c "source '$W/lib.sh'; set +eu; SIDE_BIN='$W/side102'; LIST_FILE='$W/etc/vms5'; showcmd ${QID3}" 2>&1)
chk "13j [PR5/B] showcmd UNLISTED: no WARNING lines" '! grep -q "^WARNING" <<<"$sc5u"'
# wrapper: generated wrapper text contains no skew logic, and only the printf -v change vs the PR4 pattern
w5=$(bash -c "source '$W/lib.sh'; WRAPPER_PATH=/usr/bin/kvm VENDOR_PATH=/x/kvm.pve SIDE_BIN=/x/side LIST_FILE=/x/vms LOG_FILE=/x/log; write_wrapper '$W/kvm5'" >/dev/null 2>&1; cat "$W/kvm5")
chk "13k [PR5/B] generated wrapper has no WARNING / qad_skew_warnings / stderr redirect to user" '! grep -qE "WARNING|skew|>&2" <<<"$w5"'
chk "13l [PR5 LOW1] wrapper qad_list_has uses printf -v and has no command substitution" 'grep -q "printf -v p" <<<"$w5" && ! sed -n "/^qad_list_has/,/^}/p" <<<"$w5" | grep -q "[$](" '
# list matrix incl. new pattern
printf '#!/bin/bash\nexit 0\n' > /dev/null
lh() { printf "$1" > "$W/lhf"; bash -c "source '$W/lib.sh'; set +eu; qad_list_has '$2' '$W/lhf'" && echo Y || echo N; }
chk "13m [PR5 LOW1] routing matrix with printf -v" '[[ $(lh "'"${QID1}"'\n" '"${QID1}"') == Y && $(lh "'"${QID1}"'\r\n" '"${QID1}"') == Y && $(lh "  '"${QID1}"'\t\r\n" '"${QID1}"') == Y && $(lh "'"0${QID1}"'\n" '"${QID1}"') == N && $(lh "'"${QID1}"'\n" '"0${QID1}"') == N && $(lh "'"${QID1}0"'\r\n'"${QID1}"'\r\n" '"${QID1}"') == Y && $(lh "'"${QID1}0"'\n" '"${QID1}"') == N && $(lh "'"${QID1}"'\n" 10) == N && $(lh "'"${QID1}"' # n\n" '"${QID1}"') == N && $(lh ".*\n" '"${QID1}"') == N && $(lh "'"${QID2}"'\r\n'"${QID1}"'" '"${QID1}"') == Y ]]'
# purge text
for lf in /root/my-vms /etc/qemu-ad/../x /etc/qemu-ad/; do
  e=$(PATH="$W/stub:$PATH" bash -c "source '$W/lib.sh'; set -euo pipefail; rm(){ :; }; dpkg-divert(){ echo CALLED >&2; return 1; }; PREFIX=/opt/qemu-ad LIST_FILE='$lf' WRAPPER_PATH='$W/n1' VENDOR_PATH='$W/n2'; uninstall --purge" 2>&1 >/dev/null); rc=$?
  chk "13n [PR5 LOW2] --purge LIST_FILE=$lf refused with plain-uninstall/by-hand hint, nothing changed (no dpkg-divert call)" '[[ $rc -ne 0 && $e == *"Nothing was changed"* && $e == *"plain"* && $e == *"by hand"* && $e != *CALLED* ]]'
done

# ---- 14. [PR6] -blockdev warnings (TP/FP matrix), hermetic configure flags + stamp (no rebuild loop), ldd SIGPIPE, wrapper untouched, kvm untouched
echo "== 14. PR6"
# historical base for the PR #6 / PR #7 delta sections: BASE_PR6_SCRIPT / BASE_PR7_SCRIPT, else taken from git history of the checkout under test
base_from_git(){ local out=$1 rev=$2; git -C "$(dirname "$SCRIPT")" show "$rev:qemu-ad-pve.sh" > "$out" 2>/dev/null || { echo "need $rev in git history or BASE_PR*_SCRIPT" >&2; exit 2; }; }
if [[ -n ${BASE_PR6_SCRIPT:-} ]]; then BASE_SCRIPT=$BASE_PR6_SCRIPT; else BASE_SCRIPT=$W/base_main_5bc973c.sh; base_from_git "$BASE_SCRIPT" 5bc973c; fi
# valid 10.2.2 option names (verified: ./configure --help and meson_options.txt: spice rbd curl libusb usb_redir)
for f in --disable-spice --disable-rbd --disable-curl --enable-libusb --disable-usb-redir; do  # [PR7] was --disable-libusb
  chk "14a [PR6] QAD_CONFIGURE_FLAGS has $f" 'grep -qx " *$f" <<<"$(sed -n "/^QAD_CONFIGURE_FLAGS=(/,/^)/p" "$SCRIPT")"'; done
chk "14a2 [PR6/PR7] no --enable-spice/rbd/curl/usb-redir (libusb is --enable- since PR7), no misspelling --disable-usbredir/--enable-usbredir" '! grep -qE -- "--enable-(spice|rbd|curl|usb-redir)|--(disable|enable)-usbredir" "$SCRIPT"'
fp2() { local l=$1; shift; SK=("$@"); chk "14b [PR6] no false positive: $l" '[[ $(skw "${SK[@]}") -eq 0 ]]'; }
tp2() { local l=$1; shift; SK=("$@"); chk "14c [PR6] warns: $l" '[[ $(skw "${SK[@]}") -ge 1 ]]'; }
tp2 'json rbd' -blockdev '{"driver":"rbd","pool":"p","image":"i","node-name":"n"}'
tp2 'json rbd, space after colon' -blockdev '{"driver": "rbd","pool":"p"}'
tp2 'json rbd, spaces both sides' -blockdev '{"driver" : "rbd"}'
tp2 'json rbd, tab and newline around colon' -blockdev $'{"driver"\t:\n"rbd"}'
tp2 'json pbs' -blockdev '{"driver":"pbs","repository":"x"}'
tp2 'json alloc-track' -blockdev '{"node-name":"a","driver" : "alloc-track"}'
tp2 'json zeroinit' -blockdev '{"driver":"zeroinit","file":{"driver":"file","filename":"x"}}'
tp2 'json nested file.driver=rbd' -blockdev '{"driver":"raw","file":{"driver":"rbd","pool":"p"}}'
tp2 'kv driver=rbd' -blockdev driver=rbd,pool=p,image=i,node-name=n
tp2 'kv driver=pbs not first' -blockdev node-name=n,driver=pbs
tp2 'kv driver=alloc-track' -blockdev driver=alloc-track
tp2 'kv driver=zeroinit' -blockdev driver=zeroinit,file=f
tp2 'kv nested file.driver=rbd' -blockdev driver=raw,file.driver=rbd,file.pool=p
tp2 'kv deep a.b.driver=rbd' -blockdev driver=raw,a.b.driver=rbd
tp2 '-drive comma list file.driver=rbd' -drive if=none,id=d,file.driver=rbd,file.pool=p
tp2 '-drive driver=rbd' -drive driver=rbd,pool=p,if=none
tp2 'second -blockdev is rbd' -blockdev '{"driver":"raw"}' -blockdev '{"driver":"rbd"}'
fp2 'json raw+file' -blockdev '{"driver":"raw","file":{"driver":"file","filename":"/x"}}'
fp2 'json qcow2' -blockdev '{"driver":"qcow2","file":{"driver":"file","filename":"/x.qcow2"}}'
fp2 'json host_device' -blockdev '{"driver":"host_device","filename":"/dev/zvol/rpool/x"}'
fp2 'json: rbd only in filename' -blockdev '{"driver":"raw","file":{"driver":"file","filename":"/var/lib/vz/images/rbd.raw"}}'
fp2 'json: rbd in node-name' -blockdev '{"driver":"raw","node-name":"rbd","file":"f"}'
fp2 'json: node-name "driver=rbd"' -blockdev '{"driver":"raw","node-name":"driver=rbd","file":"f"}'
fp2 'json: driver rbdx' -blockdev '{"driver":"rbdx"}'
fp2 'json: zeroinit only in path' -blockdev '{"driver":"file","filename":"/tmp/zeroinit"}'
fp2 'kv driver=raw' -blockdev driver=raw,node-name=n,file=f
fp2 'kv filename containing driver=rbd' -blockdev driver=file,filename=/mnt/driver=rbd.raw
fp2 'kv node-name=driver=rbd' -blockdev driver=raw,node-name=driver=rbd
fp2 'kv mydriver=rbd' -blockdev mydriver=rbd,driver=raw
fp2 'kv driver=rbd2 / Rbd' -blockdev driver=rbd2 -blockdev driver=Rbd
fp2 'kv path with zeroinit' -drive file=/zeroinit/x.raw,if=none
fp2 '-name rbd-vm / pbs-server' -name rbd-vm,debug-threads=on -name pbs-server
fp2 '-name driver=rbd (not a drive option)' -name driver=rbd
fp2 '-object with "driver":"rbd"' -object '{"qom-type":"iothread","driver":"rbd"}'
note "14d [PR6] known FN (no WARNING): -drive file=json:{...rbd...}, -blockdev json:{...}, 'RBD:' upper-case, single-quoted pseudo-JSON (QEMU also rejects 'RBD:' as unknown protocol? protocol names are case-sensitive: not a real FN; json: prefix is real but PVE does not emit it)"
# warnings never alter argv/exit code; only showcmd prints them; wrapper identical to base
cat > "$W/qm6.out" <<'EOF'
/usr/bin/kvm \
  -id @QID1@ \
  -pidfile /var/run/qemu-server/@QID1@.pid \
  -machine type=pc-q35-10.2+pve0 \
  -blockdev '{"driver":"rbd","pool":"p","image":"i","node-name":"n"}' \
  -blockdev driver=zeroinit,node-name=z,file=n
EOF
sed -i "s/@QID1@/$QID1/g" "$W/qm6.out"
printf ''"${QID1}"'\n' > "$W/etc/vms6"
run_sc() { PATH="$W:$PATH" QM_OUT="$W/qm6.out" bash -c "source '$1'; set -euo pipefail; SIDE_BIN='$W/side102'; LIST_FILE='$W/etc/vms6'; showcmd ${QID1}" 2>"$W/sc6.err"; echo "rc=$?"; }
sed '$d' "$BASE_SCRIPT" > "$W/base_lib.sh"
b6=$(run_sc "$W/base_lib.sh"); h6=$(run_sc "$W/lib.sh")
chk "14e [PR6] showcmd rc 0, stderr empty, and output differs from base ONLY by added WARNING lines" '[[ $h6 == *"rc=0"* && ! -s $W/sc6.err ]] && [[ $(diff <(grep -v "^WARNING" <<<"$b6") <(grep -v "^WARNING" <<<"$h6") | wc -l) -eq 0 ]] && [[ $(grep -c "^WARNING" <<<"$h6") -ge 2 && $(grep -c "^WARNING" <<<"$b6") -eq 0 ]]'
sc6un=$(PATH="$W:$PATH" QM_OUT="$W/qm6.out" bash -c "source '$W/lib.sh'; set +eu; SIDE_BIN='$W/side102'; LIST_FILE='$W/etc/vms6'; showcmd ${QID3}" 2>&1)
chk "14f [PR6] showcmd UNLISTED guest with -blockdev rbd: no WARNING" '! grep -q "^WARNING" <<<"$sc6un"'
bash -c "source '$W/base_lib.sh'; WRAPPER_PATH=/usr/bin/kvm VENDOR_PATH=/x/kvm.pve SIDE_BIN=/x/side LIST_FILE=/x/vms LOG_FILE=/x/log; write_wrapper '$W/kvm6b'" >/dev/null 2>&1
bash -c "source '$W/lib.sh'; WRAPPER_PATH=/usr/bin/kvm VENDOR_PATH=/x/kvm.pve SIDE_BIN=/x/side LIST_FILE=/x/vms LOG_FILE=/x/log; write_wrapper '$W/kvm6h'" >/dev/null 2>&1
chk "14g [PR6] generated wrapper is byte-identical to base's (main 5bc973c)" 'cmp -s "$W/kvm6b" "$W/kvm6h"'
chk "14h [PR6] wrapper contains no qad_vendor_drivers / qad_skew_warnings / WARNING" '! grep -qE "qad_vendor_drivers|qad_skew_warnings|WARNING" "$W/kvm6h"'
# stubs: byte-identical argv/argv0/rc/stdout/stderr base vs head wrapper for argv containing the warned forms
cp "$W/kvm6b" "$W/kvm_b6"; cp "$W/kvm6h" "$W/kvm_h6"; chmod 755 "$W/kvm_b6" "$W/kvm_h6"
sed -i "s#^real=.*#real=$W/kvm.pve#; s#^side=.*#side=$W/qemu-system-x86_64#; s#^list=.*#list=$W/etc/vms6#; s#^log=.*#log=$W/var/w6.log#" "$W/kvm_b6" "$W/kvm_h6"
m6=1
for pid in "${QID1}" "${QID3}"; do for sd in 0 3; do
  for v in b6 h6; do command rm -f "$W/out"; "$W/kvm_$v" -name x -pidfile /var/run/qemu-server/$pid.pid -id $pid -machine type=pc-q35-11.0+pve0 -blockdev '{"driver":"rbd"}' -blockdev driver=zeroinit -drive file=rbd:p/i -spice a --exit$sd >"$W/o6.$v" 2>"$W/e6.$v" </dev/null; echo $? >"$W/r6.$v"; cp "$W/out" "$W/a6.$v" 2>/dev/null; done
  cmp -s "$W/a6.b6" "$W/a6.h6" && cmp -s "$W/o6.b6" "$W/o6.h6" && cmp -s "$W/e6.b6" "$W/e6.h6" && cmp -s "$W/r6.b6" "$W/r6.h6" || m6=0
done; done
chk "14i [PR6] stub wrapper run (listed ${QID1} / unlisted ${QID3}, argv with every warned form): argv+argv0, stdout, stderr, exit code identical to base" '[[ $m6 -eq 1 ]]'
# hermetic flags, stamp, rebuild loop, kvm untouched
mkdir -p "$W/bq/stub" "$W/bq/src" "$W/bq/prefix/bin"
cat > "$W/bq/stub/ldd" <<'S'
#!/bin/bash
echo "	libglib-2.0.so.0 => /lib/libglib (0x1)"
[[ ${LDD_MODE:-} == *gcrypt ]] && echo "	libgcrypt.so.20 => /lib/libgcrypt.so.20 (0x2)"
[[ ${LDD_MODE:-} == big* ]] && for ((i=0;i<30000;i++)); do echo "	libpad$i.so.0 => /lib/libpad$i.so.0 (0x3)"; done
exit 0
S
cat > "$W/bq/stub/make" <<'S'
#!/bin/bash
echo "make $*" >> "$BQ/make.log"
[[ $1 == install ]] && { mkdir -p "$BQ/prefix/bin"; printf '#!/bin/bash\necho "QEMU emulator version 10.2.2"\n' > "$BQ/prefix/bin/qemu-system-x86_64"; chmod +x "$BQ/prefix/bin/qemu-system-x86_64"; }
exit 0
S
printf '#!/bin/bash\necho "$*" >> "$BQ/cfg.log"\n' > "$W/bq/src/configure"
chmod +x "$W/bq/stub/"* "$W/bq/src/configure"
export BQ="$W/bq"
bqr() { env "$@" PATH="$W/bq/stub:$PATH" bash -c "source '$W/lib.sh'; set -euo pipefail; PREFIX='$W/bq/prefix' SIDE_BIN='$W/bq/prefix/bin/qemu-system-x86_64' SRC_DIR='$W/bq/src'; ${BQCMD:-build_qemu}" 2>&1; }
printf '#!/bin/bash\necho "QEMU emulator version 10.2.2"\n' > "$W/bq/prefix/bin/qemu-system-x86_64"; chmod +x "$W/bq/prefix/bin/qemu-system-x86_64"
printf '%s\n' "--target-list=x86_64-softmmu --enable-kvm --enable-linux-aio --enable-linux-io-uring --enable-libiscsi --enable-gcrypt --disable-gnutls --disable-docs --disable-werror" > "$W/bq/prefix/.qemu-ad-configure-flags"
chk "14j [PR6] PR #5 era stamp => rebuild reason mentions different configure flags" '[[ $(BQCMD=side_rebuild_reason bqr LDD_MODE=gcrypt) == *"different configure flags"* ]]'
: > "$W/bq/cfg.log"; : > "$W/bq/make.log"; bqr LDD_MODE=gcrypt >/dev/null
chk "14k [PR6/PR7] run 1: rebuilt (configure with all 5 hermetic flags, libusb now --enable-, make install, stamp rewritten)" '[[ $(wc -l < "$W/bq/cfg.log") -eq 1 ]] && for f in --disable-spice --disable-rbd --disable-curl --enable-libusb --disable-usb-redir; do grep -qxF -- "$f" <(tr " " "\n" < "$W/bq/cfg.log") || exit 1; done; grep -q "^make install" "$W/bq/make.log" && grep -q -- "--disable-usb-redir" "$W/bq/prefix/.qemu-ad-configure-flags"'
for i in 2 3; do : > "$W/bq/cfg.log"; : > "$W/bq/make.log"; bqr LDD_MODE=nocrypt >/dev/null
  chk "14l [PR6] run $i: stamp matches, NO rebuild (no loop)" '[[ ! -s $W/bq/cfg.log && ! -s $W/bq/make.log ]]'; done
chk "14m [PR6] side_rebuild_reason empty after stamping under LC_ALL=C, LANG=C.UTF-8, TZ, HOME=/nonexistent, FORCE_REBUILD=1" 'm=0; for e in LC_ALL=C LANG=C.UTF-8 TZ=Asia/Tokyo HOME=/nonexistent FORCE_REBUILD=1; do [[ -z $(BQCMD=side_rebuild_reason bqr $e) ]] || m=1; done; [[ $m -eq 0 ]]'
chk "14n [PR6] status prints no WARNING for a stamped build" '[[ $(BQCMD="status 2>&1 | grep -c WARNING || true" bqr LDD_MODE=nocrypt) == 0 ]]'
printf '%s\n' "--enable-gcrypt" > "$W/bq/prefix/.qemu-ad-configure-flags"; : > "$W/bq/cfg.log"
printf '#!/bin/bash\nexit 1\n' > "$W/bq/src/configure"
bqr LDD_MODE=gcrypt >/dev/null; rc=$?
chk "14o [PR6] configure failing during a rebuild: stamp stays old (retry next run), existing side binary untouched" '[[ $(cat "$W/bq/prefix/.qemu-ad-configure-flags") == "--enable-gcrypt" && -x $W/bq/prefix/bin/qemu-system-x86_64 ]]'
printf '#!/bin/bash\necho "$*" >> "$BQ/cfg.log"\n' > "$W/bq/src/configure"
printf 'VENDOR\n' > "$W/bq/kvm"; ino=$(stat -c %i "$W/bq/kvm"); h=$(sha256sum < "$W/bq/kvm"); : > "$W/bq/div.log"
printf '#!/bin/bash\necho "$*" >> "$BQ/div.log"\n' > "$W/bq/stub/dpkg-divert"; chmod +x "$W/bq/stub/dpkg-divert"
env LDD_MODE=gcrypt PATH="$W/bq/stub:$PATH" bash -c "source '$W/lib.sh'; set -euo pipefail; PREFIX='$W/bq/prefix' SIDE_BIN='$W/bq/prefix/bin/qemu-system-x86_64' SRC_DIR='$W/bq/src' WRAPPER_PATH='$W/bq/kvm' VENDOR_PATH='$W/bq/kvm.pve'; build_qemu" >/dev/null 2>&1
chk "14p [PR6] a rebuild never touches WRAPPER_PATH (same inode+content), never calls dpkg-divert, never creates VENDOR_PATH" '[[ $(stat -c %i "$W/bq/kvm") == "$ino" && $(sha256sum < "$W/bq/kvm") == "$h" && ! -s $W/bq/div.log && ! -e $W/bq/kvm.pve ]]'
chk "14q [PR6] build_qemu body does not mention WRAPPER_PATH/VENDOR_PATH/divert/rm/mv" '! sed -n "/^build_qemu()/,/^}/p" "$SCRIPT" | grep -qE "WRAPPER_PATH|VENDOR_PATH|divert|rm |mv "'
# SIGPIPE: ldd stub emits libgcrypt first, then a lot more; reader must not flip the verdict
printf '%s\n' "x" > /dev/null; command rm -f "$W/bq/prefix/.qemu-ad-configure-flags"
cat > "$W/bq/stub/ldd" <<'S'
#!/bin/bash
echo "	libglib-2.0.so.0 => /lib/libglib (0x1)"
echo "	libgcrypt.so.20 => /lib/libgcrypt.so.20 (0x2)"
for ((i=0;i<30000;i++)); do echo "	libpad$i.so.0 => /lib/libpad$i.so.0 (0x3)"; done
S
sp=0; for ((k=0;k<150;k++)); do [[ -n $(BQCMD=side_rebuild_reason bqr) ]] && sp=$((sp+1)); done
chk "14r [PR6] 150 x big ldd output with libgcrypt first (no stamp): zero spurious 'no libgcrypt'" '[[ $sp -eq 0 ]]' "spurious=$sp"

# 14v SIGPIPE, deterministic: ldd stub prints the =>/libgcrypt lines first, then a slow tail. A reader that exits at its first match
# (grep -q) kills the stub with SIGPIPE, pipefail then flips the verdict. Old code (main) gives the wrong answer here, PR6 must not.
mkdir -p "$W/sp/stub" "$W/sp/p/bin"; printf '#!/bin/bash\n' > "$W/sp/p/bin/qemu-system-x86_64"; chmod +x "$W/sp/p/bin/qemu-system-x86_64"
cat > "$W/sp/stub/ldd" <<'S'
#!/bin/bash
echo "	libglib-2.0.so.0 => /lib/libglib (0x1)"
[[ ${SPMODE:-} == gc ]] && echo "	libgcrypt.so.20 => /lib/libgcrypt.so.20 (0x2)"
sleep 0.3
for ((i=0;i<20000;i++)); do echo "	libpad$i.so.0 => /lib/libpad$i.so.0 (0x3)"; done
S
chmod +x "$W/sp/stub/ldd"
sprr() { PATH="$W/sp/stub:$PATH" SPMODE=$2 bash -c "source '$1'; set -euo pipefail; PREFIX='$W/sp/p' SIDE_BIN='$W/sp/p/bin/qemu-system-x86_64'; side_rebuild_reason" 2>&1; }
chk "14v [PR6] ldd SIGPIPE: libgcrypt linked + slow big tail, no stamp => NO reason; no libgcrypt + big output => reason (PR6)" '[[ -z $(sprr "$W/lib.sh" gc) && -n $(sprr "$W/lib.sh" nogc) ]]'
note "14v2 [PR6] same stub on main 5bc973c: libgcrypt-linked => [$(sprr "$W/base_lib.sh" gc | cut -c1-30)] (spurious 'no libgcrypt' if non-empty); no-libgcrypt+big => [$(sprr "$W/base_lib.sh" nogc | cut -c1-30)] (empty = rebuild missed)"
# README claims
RM=$(dirname "$SCRIPT")/README.md
chk "14s [PR6] README: CPU row says only SapphireRapids-v5 is missing and GraniteRapids/SierraForest/ClearwaterForest/EPYC-Turin/avx10 exist; no '-spice' etc. claimed intrinsic" 'r=$(grep "^| CPU model" "$RM"); [[ $r == *SapphireRapids-v5* && $r == *GraniteRapids* && $r == *SierraForest* && $r == *ClearwaterForest* && $r == *EPYC-Turin* && $r == *avx10* && $r == *"exist in 10.2.2"* ]]'
chk "14t [PR6] README documents the 5 --disable flags and that a changed flag list rebuilds" 'for f in --disable-spice --disable-rbd --disable-curl --disable-usb-redir; do grep -q -- "$f" "$RM" || exit 1; done; grep -qi "changes the stamp" "$RM"'
chk "14u [PR6] README rbd/pbs row: pbs/alloc-track/zeroinit as pve-qemu patches, rbd vanilla but disabled; http(s)/ftp(s) row says curl disabled" 'grep -q "pbs.*alloc-track.*zeroinit.*pve-qemu. patches" "$RM" && grep -q "disable-rbd" "$RM" && grep -q "disable-curl" "$RM"'

# ---- 15. [PR7] libusb enabled for usb-host passthrough
echo "== 15. PR7"
if [[ -n ${BASE_PR7_SCRIPT:-} ]]; then BASE7=$BASE_PR7_SCRIPT; else BASE7=$W/base_main_08ce424.sh; base_from_git "$BASE7" 08ce424; fi   # PR #6 merged = PR #7 base   # PR #6 merged = PR #7 base
sed '$d' "$BASE7" > "$W/base7_lib.sh"; bt=$(printf '\140')
fl7=$(sed -n '/^QAD_CONFIGURE_FLAGS=(/,/^)/p' "$SCRIPT")
chk "15a [PR7] QAD_CONFIGURE_FLAGS has exactly one libusb flag and it is --enable-libusb (valid 10.2.2 option: meson_options.txt 'libusb' feature)" '[[ $(grep -c -- "libusb" <<<"$fl7") -eq 1 ]] && grep -qx " *--enable-libusb" <<<"$fl7"'
chk "15b [PR7] --disable-usb-redir is still there, spelled right (usb_redir feature), no other usb-redir/usbredir flag" 'grep -qx " *--disable-usb-redir" <<<"$fl7" && [[ $(grep -ciE "usb-?redir" <<<"$fl7") -eq 1 ]]'
chk "15c [PR7] spice/rbd/curl still disabled; gcrypt/kvm/io_uring/libiscsi/aio still enabled; gnutls disabled (unchanged vs PR6)" 'for f in --disable-spice --disable-rbd --disable-curl --enable-gcrypt --disable-gnutls --enable-kvm --enable-linux-aio --enable-linux-io-uring --enable-libiscsi; do grep -qx " *$f" <<<"$fl7" || exit 1; done'
chk "15d [PR7] flag list identical to PR6 except libusb (exactly one line differs)" 'n=$(diff <(sed -n "/^QAD_CONFIGURE_FLAGS=(/,/^)/p" "$BASE7") <(echo "$fl7") | grep -c "^[<>]"); [[ $n -eq 2 ]]'
chk "15e [PR7] install_deps lists libusb-1.0-0-dev (exact package name, once, no typo)" 'b=$(sed -n "/^install_deps()/,/^}/p" "$SCRIPT"); [[ $(tr " \\\\" "\n\n" <<<"$b" | grep -cxF libusb-1.0-0-dev) -eq 1 ]] && ! grep -qE "libusb-dev|libusb-1.0-dev|libusb1" <<<"$b"'
chk "15f [PR7] install_deps still lists every PR6 package (nothing dropped)" 'b=$(tr " \\\\" "\n\n" < <(sed -n "/^install_deps()/,/^}/p" "$SCRIPT")); bb=$(tr " \\\\" "\n\n" < <(sed -n "/^install_deps()/,/^}/p" "$BASE7")); for p in $(grep -E "^[a-z0-9][a-z0-9.+-]+$" <<<"$bb"); do grep -qxF "$p" <<<"$b" || { echo "lost $p"; exit 1; }; done'
chk "15g [PR7] install runs install_deps before build_qemu (dep present before in-place rebuild)" 'b=$(sed -n "/^cmd_install()/,/^}/p" "$SCRIPT"); a=${b%%install_deps*}; c=${b%%build_qemu*}; [[ ${#a} -lt ${#c} ]]'
OLD6="--target-list=x86_64-softmmu --enable-kvm --enable-linux-aio --enable-linux-io-uring --enable-libiscsi --enable-gcrypt --disable-gnutls --disable-spice --disable-rbd --disable-curl --disable-libusb --disable-usb-redir --disable-docs --disable-werror"
printf '#!/bin/bash\necho "QEMU emulator version 10.2.2"\n' > "$W/bq/prefix/bin/qemu-system-x86_64"; chmod +x "$W/bq/prefix/bin/qemu-system-x86_64"
printf '#!/bin/bash\necho "$*" >> "$BQ/cfg.log"\n' > "$W/bq/src/configure"
printf '%s\n' "$OLD6" > "$W/bq/prefix/.qemu-ad-configure-flags"
chk "15h [PR7] PR6-era stamp (--disable-libusb) => rebuild reason 'different configure flags'" '[[ $(BQCMD=side_rebuild_reason bqr LDD_MODE=gcrypt) == *"different configure flags"* ]]'
: > "$W/bq/cfg.log"; : > "$W/bq/make.log"; bqr LDD_MODE=gcrypt >/dev/null
chk "15i [PR7] run 1: one configure with --enable-libusb (whole flag) and without --disable-libusb, make install ran, stamp has --enable-libusb" '[[ $(wc -l < "$W/bq/cfg.log") -eq 1 ]] && c=$(tr " " "\n" < "$W/bq/cfg.log") && grep -qxF -- --enable-libusb <<<"$c" && ! grep -qxF -- --disable-libusb <<<"$c" && grep -q "^make install" "$W/bq/make.log" && st=$(tr " " "\n" < "$W/bq/prefix/.qemu-ad-configure-flags") && grep -qxF -- --enable-libusb <<<"$st" && ! grep -qF -- --disable-libusb <<<"$st"'
for i in 2 3; do : > "$W/bq/cfg.log"; : > "$W/bq/make.log"; bqr LDD_MODE=nocrypt >/dev/null
  chk "15j [PR7] run $i: no rebuild (no configure, no make)" '[[ ! -s $W/bq/cfg.log && ! -s $W/bq/make.log ]]'; done
chk "15k [PR7] ...under LC_ALL=C, LANG=C.UTF-8, TZ=Asia/Tokyo, HOME=/nonexistent, FORCE_REBUILD=0, POSIXLY_CORRECT=1: still no reason" 'm=0; for e in LC_ALL=C LANG=C.UTF-8 TZ=Asia/Tokyo HOME=/nonexistent FORCE_REBUILD=0 POSIXLY_CORRECT=1; do [[ -z $(BQCMD=side_rebuild_reason bqr $e) ]] || m=1; done; [[ $m -eq 0 ]]'
chk "15l [PR7] trailing-slash PREFIX still matches the stamp" '[[ -z $(env PATH="$W/bq/stub:$PATH" bash -c "source \"$W/lib.sh\"; set -euo pipefail; PREFIX=\"$W/bq/prefix/\" SIDE_BIN=\"$W/bq/prefix/bin/qemu-system-x86_64\"; side_rebuild_reason") ]]'
printf '%s\n' "$OLD6" > "$W/bq/prefix/.qemu-ad-configure-flags"; printf '#!/bin/bash\nexit 1\n' > "$W/bq/src/configure"
bqr LDD_MODE=gcrypt >/dev/null; rc=$?
chk "15m [PR7] failing configure on the libusb rebuild (e.g. dev package missing): stamp stays the OLD one, old binary untouched" '[[ $(cat "$W/bq/prefix/.qemu-ad-configure-flags") == "$OLD6" && -x $W/bq/prefix/bin/qemu-system-x86_64 ]]'
printf '#!/bin/bash\necho "$*" >> "$BQ/cfg.log"\n' > "$W/bq/src/configure"
mv "$W/bq/stub/make" "$W/bq/stub/make.ok"; printf '#!/bin/bash\n[[ $1 == install ]] && exit 2\nexit 0\n' > "$W/bq/stub/make"; chmod +x "$W/bq/stub/make"
bqr LDD_MODE=gcrypt >/dev/null
chk "15n [PR7] failing make install: stamp stays OLD" '[[ $(cat "$W/bq/prefix/.qemu-ad-configure-flags") == "$OLD6" ]]'
mv "$W/bq/stub/make.ok" "$W/bq/stub/make"
chk "15o [PR7] side_rebuild_reason has NO libusb linkage (ldd) check: rebuild detection is stamp-only (observation; locks current behaviour)" '! sed -n "/^side_rebuild_reason()/,/^}/p" "$SCRIPT" | grep -qi libusb'
chk "15p [PR7] build_qemu body still has no WRAPPER_PATH/VENDOR_PATH/divert/rm/mv (no missing-/usr/bin/kvm window)" '! sed -n "/^build_qemu()/,/^}/p" "$SCRIPT" | grep -qE "WRAPPER_PATH|VENDOR_PATH|divert|rm |mv "'
bash -c "source '$W/lib.sh'; WRAPPER_PATH=/usr/bin/kvm VENDOR_PATH=/x/kvm.pve SIDE_BIN=/x/side LIST_FILE=/x/vms LOG_FILE=/x/log; write_wrapper '$W/kvm7h'" >/dev/null 2>&1
bash -c "source '$W/base7_lib.sh'; WRAPPER_PATH=/usr/bin/kvm VENDOR_PATH=/x/kvm.pve SIDE_BIN=/x/side LIST_FILE=/x/vms LOG_FILE=/x/log; write_wrapper '$W/kvm7b'" >/dev/null 2>&1
chk "15q [PR7] generated wrapper byte-identical to base main (wrapper unchanged since PR5), no usb mention" '[[ -s $W/kvm7h ]] && cmp -s "$W/kvm7b" "$W/kvm7h" && ! grep -qi usb "$W/kvm7h"'
SK=(-device usb-host,vendorid=0x046d,productid=0xc52b,id=usb0)
chk "15r [PR7] qad_skew_warnings: -device usb-host,vendorid=,productid= => no WARNING" '[[ $(skw "${SK[@]}") -eq 0 ]]'
SK=(-device usb-host,hostbus=1,hostport=2.3,id=usb0 -device usb-host,hostbus=1,hostaddr=5)
chk "15s [PR7] usb-host hostbus/hostport/hostaddr => no WARNING" '[[ $(skw "${SK[@]}") -eq 0 ]]'
SK=(-usb -device qemu-xhci,p2=15,p3=15,id=xhci,bus=pci.1,addr=0x1b -device usb-host,bus=xhci.0,port=1,vendorid=0x1234,productid=0x5678,id=usb0 -device usb-tablet,id=tablet,bus=ehci.0,port=1 -device usb-kbd,id=keyboard,bus=ehci.0,port=2)
chk "15t [PR7] -usb + qemu-xhci + usb-host + usb-tablet/kbd (PVE shapes) => no WARNING" '[[ $(skw "${SK[@]}") -eq 0 ]]'
SK=(-name usb-vm -name usbhost -name usb-redir-test -name vm-usb-host,debug-threads=on -smbios type=1,product=usb-redir,serial=usb-host -device virtio-net-pci,id=usb0 -drive file=/mnt/usb-host/x.raw,if=none -blockdev driver=raw,node-name=usb,file=/dev/disk/by-id/usb-Foo_Bar)
chk "15u [PR7] no false positive from names/paths containing 'usb'" '[[ $(skw "${SK[@]}") -eq 0 ]]'
SK=(-device usb-redir,chardev=usbredirchardev0,id=usbredirdev0 -chardev spicevmc,id=usbredirchardev0,name=usbredir)
note "15v [PR7] INFO: usb-redir / -chardev spicevmc ALONE is NOT warned by showcmd ($(skw "${SK[@]}") WARNING lines); PVE only emits them with a SPICE display, which gets the -spice WARNING"
SK=(-spice tls-port=61000,addr=localhost -device usb-redir,chardev=usbredirchardev0,id=usbredirdev0 -chardev spicevmc,id=usbredirchardev0,name=usbredir)
chk "15w [PR7] a SPICE guest with usb-redir still gets the -spice WARNING" '[[ $(skw "${SK[@]}") -ge 1 ]]'
cat > "$W/qm7.out" <<'QM7EOF'
/usr/bin/kvm \
  -id @QID1@ \
  -pidfile /var/run/qemu-server/@QID1@.pid \
  -name usb-vm,debug-threads=on \
  -machine type=pc-q35-10.2+pve0 \
  -usb \
  -device qemu-xhci,p2=15,p3=15,id=xhci,bus=pci.1,addr=0x1b \
  -device usb-host,bus=xhci.0,port=1,vendorid=0x046d,productid=0xc52b,id=usb0 \
  -device usb-host,hostbus=1,hostport=2.3,id=usb1
QM7EOF
sed -i "s/@QID1@/$QID1/g" "$W/qm7.out"
printf ''"${QID1}"'\n' > "$W/etc/vms7"
run_sc7() { PATH="$W:$PATH" QM_OUT="$W/qm7.out" bash -c "source '$1'; set -euo pipefail; SIDE_BIN='$W/side102'; LIST_FILE='$W/etc/vms7'; showcmd ${QID1}" 2>"$W/sc7.err"; echo "rc=$?"; }
b7=$(run_sc7 "$W/base7_lib.sh"); h7=$(run_sc7 "$W/lib.sh")
chk "15x [PR7] showcmd (listed guest with usb-host + xhci + VM named usb-vm): rc 0, stderr empty, 0 WARNING lines, output identical to base" '[[ $h7 == *"rc=0"* && ! -s $W/sc7.err && $(grep -c "^WARNING" <<<"$h7") -eq 0 && $b7 == "$h7" ]] && grep -q "usb-host" <<<"$h7"'
chk "15y [PR7] showcmd side view keeps the usb-host options (wrapper drops no usb option)" '[[ $(grep -o "usb-host" <<<"$h7" | wc -l) -ge 4 ]]'
RM7=$(dirname "$SCRIPT")/README.md
chk "15z [PR7] README USB text consistent with code: --enable-libusb + libusb-1.0-0-dev + /dev/bus/usb + --disable-usb-redir; no stale unsupported-usb-host text" 'u=$(grep -i "usb" "$RM7"); grep -q -- "--enable-libusb" <<<"$u" && grep -q "libusb-1.0-0-dev" <<<"$u" && grep -q "/dev/bus/usb" <<<"$u" && grep -q -- "--disable-usb-redir" <<<"$u" && ! grep -qE -- "(passes|uses|with|configured with) .*--disable-libusb" <<<"$(grep -v "built with .--disable-libusb" <<<"$u")" && ! grep -qiE "usb-host.{0,40}(not supported|unsupported|absent)|USB passthrough needs a side build" <<<"$u" && ! grep -qF "| ${bt}usb-host${bt}" "$RM7"'
chk "15za [PR7] README showcmd WARNING sentence does not claim a usb warning" '! grep "showcmd. prints a .WARNING. line" "$RM7" | grep -qi usb'

echo
echo "HARNESS RESULT: pass=$pass fail=$fail  (script: $SCRIPT)"
[[ $fail -eq 0 ]]
