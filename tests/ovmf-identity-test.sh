#!/bin/bash
# Offline checks for scripts/ovmf-identity/build-ovmf-identity.sh (--print-pcd and input validation only;
# the real build needs a Debian build host and is documented in docs/ovmf-identity.md).
# Usage: bash tests/ovmf-identity-test.sh
set -u
S="$(cd "$(dirname "$0")/.." && pwd)/scripts/ovmf-identity/build-ovmf-identity.sh"
pass=0; fail=0
chk() { if eval "$2"; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1"; fail=$((fail+1)); fi; }

out=$(bash "$S" --print-pcd); rc=$?
chk "default flags print and exit 0" '[[ $rc -eq 0 ]]'
chk "vendor PCD is unicode with explicit NUL" '[[ $out == *"PcdFirmwareVendor=L\"American Megatrends International, LLC.\\\\0\""* ]]'
chk "revision PCD" '[[ $out == *"PcdFirmwareRevision=0x5001B"* ]]'
chk "OEM table id is the little-endian space padded 8 byte value of \"A M I\"" '[[ $out == *"PcdAcpiDefaultOemTableId=0x20202049204d2041"* ]]'
chk "OEM id and revision" '[[ $out == *"PcdAcpiDefaultOemId=\"ALASKA\""* && $out == *"PcdAcpiDefaultOemRevision=0x1072009"* ]]'
out=$(OVMF_VENDOR="Foo Corp" ACPI_OEM_TABLE_ID=EDK2 bash "$S" --print-pcd)
chk "overrides are honoured (EDK2 -> 0x20202020324b4445)" '[[ $out == *"L\"Foo Corp\\\\0\""* && $out == *"OemTableId=0x20202020324b4445"* ]]'
for bad in 'OVMF_VENDOR=a;b' 'OVMF_VENDOR=$(id)' 'OVMF_REVISION=5001B' 'ACPI_OEM_ID=TOOLONG1' 'ACPI_OEM_TABLE_ID=NINECHARS' 'OVMF_RELEASE_DATE=2024-01-12' 'OVMF_VERSION_STRING=a b'; do
  env "$bad" bash "$S" --print-pcd >/dev/null 2>&1; rc=$?
  chk "rejects $bad" '[[ $rc -ne 0 ]]'
done
bash "$S" --bogus >/dev/null 2>&1; rc=$?
chk "unknown argument rejected" '[[ $rc -ne 0 ]]'
echo "RESULT pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
