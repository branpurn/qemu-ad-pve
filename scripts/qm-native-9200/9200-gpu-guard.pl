#!/usr/bin/perl
# PVE hookscript for VM 9200 ONLY.  Install: <snippets storage>/snippets/9200-gpu-guard.pl (0755),
# then `qm set 9200 --hookscript iso_images:snippets/9200-gpu-guard.pl`.
#
# Why: 9200 gets the RTX 4080 (0000:02:00.0 + .1) through `args:` (both functions behind a
# pcie-pci-bridge so the Intel vIOMMU sees one address space), not through `hostpci`. qemu-server
# only reserves PCI devices listed in hostpci*, so without this hook nothing stops `qm start 9102`
# (hostpci0: 0000:02:00) while 9200 holds the GPU -- and 9102's start path would bind/reset the
# GPU under the running 9200. This hook writes the same reservation qemu-server writes for
# hostpci (/run/qemu-server/pci-id-reservations), using qemu-server's own functions:
#   pre-start : refuse unless both functions are on vfio-pci; reserve (dies if 9102 holds them)
#   post-start: re-reserve with the real QEMU pid (like qemu-server does for hostpci)
#   post-stop : drop 9200's reservation
# It does not change the QEMU command line. Remove: `qm set 9200 --delete hookscript` + rm file.
use strict;
use warnings;

use PVE::QemuServer::Helpers;
use PVE::QemuServer::PCI;

my ($vmid, $phase) = @ARGV;
my @ids = ('0000:02:00.0', '0000:02:00.1');

die "9200-gpu-guard: for VM 9200 only (called for '$vmid')\n" if ($vmid // '') ne '9200';
$phase //= '';

if ($phase eq 'pre-start') {
    for my $id (@ids) {
        my $drv = readlink("/sys/bus/pci/devices/$id/driver") // 'none';
        die "9200-gpu-guard: $id driver is '$drv', not vfio-pci; refusing start\n"
            if $drv !~ m{/vfio-pci$};
    }
    # time-based reservation for the start window; dies if another running VM holds the ids
    PVE::QemuServer::PCI::reserve_pci_usage(\@ids, $vmid, 90);
    print "9200-gpu-guard: reserved @ids for VM $vmid (start window)\n";
} elsif ($phase eq 'post-start') {
    my $pid = PVE::QemuServer::Helpers::vm_running_locally($vmid);
    if ($pid) {
        PVE::QemuServer::PCI::reserve_pci_usage(\@ids, $vmid, undef, $pid);
        print "9200-gpu-guard: reserved @ids for VM $vmid pid $pid\n";
    } else {
        warn "9200-gpu-guard: VM $vmid not running after start?\n";
    }
} elsif ($phase eq 'post-stop') {
    PVE::QemuServer::PCI::remove_pci_reservation($vmid, \@ids);
    print "9200-gpu-guard: released @ids\n";
}
exit 0;
