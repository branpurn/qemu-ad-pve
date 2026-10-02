#!/bin/bash
# End-to-end: launch the generated wrapper's target as a long-running process, then run the
# VERBATIM PVE::QemuServer::Helpers::parse_cmdline body (extracted from /tmp/Helpers.pm if present,
# else an embedded copy) against /proc/<pid>/cmdline and the pidfile equality check qemu-server does.
# Usage: parse_cmdline_e2e.sh <qemu-ad-pve.sh>
LISTED=$((100+1)); UNLISTED=$((100+2))   # synthetic fixture ids
set -u; S=$(readlink -f "$1"); W=$(mktemp -d); trap 'kill $P 2>/dev/null; rm -rf "$W"' EXIT
cat > $W/s.c <<'C'
#include <unistd.h>
int main(){sleep(20);return 0;}
C
cc -o $W/kvm.pve $W/s.c; cp $W/kvm.pve $W/qemu-system-x86_64
sed '$d' "$S" > $W/lib.sh; mkdir $W/qemu-server
bash -c "source $W/lib.sh; set +eu; WRAPPER_PATH=/usr/bin/kvm VENDOR_PATH=$W/kvm.pve SIDE_BIN=$W/qemu-system-x86_64 LIST_FILE=$W/vms LOG_FILE=$W/log; write_wrapper $W/kvm" >/dev/null; printf '%s\n' "$LISTED" > $W/vms
cat > $W/p.pl <<'PL'
use strict; use warnings; use IO::File;
sub parse_cmdline { my ($pid) = @_;
  my $fh = IO::File->new("/proc/$pid/cmdline", "r");
  if (defined($fh)) { my $line = <$fh>; $fh->close; return if !$line; my @param = split(/\0/, $line);
    my $cmd = $param[0]; return if !$cmd || ($cmd !~ m|kvm$| && $cmd !~ m@(?:^|/)qemu-[^/]+$@);
    my $phash = {}; my $pending_cmd;
    for (my $i = 0; $i < scalar(@param); $i++) { my $p = $param[$i]; next if !$p;
      if ($p =~ m/^--?(.*)$/) { if ($pending_cmd) { $phash->{$pending_cmd} = {}; } $pending_cmd = $1; }
      elsif ($pending_cmd) { $phash->{$pending_cmd} = { value => $p }; $pending_cmd = undef; } }
    return $phash; } return; }
my ($pid,$pidfile)=@ARGV; my $c=parse_cmdline($pid);
print(($c && defined $c->{pidfile} && $c->{pidfile}{value} eq $pidfile) ? "RUNNING-RECOGNISED\n" : "NOT-RECOGNISED (qm would think VM is stopped)\n");
PL
for vm in $LISTED $UNLISTED; do
  pf=/var/run/qemu-server/$vm.pid
  "$W/kvm" -id $vm -name t -pidfile $pf & P=$!; sleep 0.5
  echo "vm $vm ($( [[ $vm == "$LISTED" ]] && echo listed/side || echo unlisted/vendor )): argv0=$(tr '\0' '\n' < /proc/$P/cmdline | head -1) exe=$(readlink /proc/$P/exe | sed "s#$W/##") -> $(perl $W/p.pl $P $pf)"
  kill $P; wait $P 2>/dev/null
done
