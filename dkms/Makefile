# Out-of-tree build of kvm.ko / kvm-amd.ko / kvm-intel.ko for ONE given kernel.
#
#   ./fetch-kvm-source.sh 6.12.111          # once, needs network
#   make KVER=6.12.111+deb13-amd64          # needs matching linux-headers
#
# KVER   kernel release the module is built for (default: running kernel)
# KDIR   its build tree (default: /lib/modules/$(KVER)/build)
# SRC_VER upstream source version in src/ (default: derived from KVER)
#
# STATUS: skeleton. Compiles and links kvm.ko/kvm-amd.ko/kvm-intel.ko for
# 6.12.111+deb13-amd64 (Debian headers, v6.12.111 source) on a build box; never
# loaded or booted. See README "Verification status". Needs: make, gcc matching
# the kernel's compiler, linux-headers-$(KVER), pahole (package "pahole", for BTF).

KVER    ?= $(shell uname -r)
KDIR    ?= /lib/modules/$(KVER)/build
SRC_VER ?= $(shell printf '%s' '$(KVER)' | sed -E 's/^([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/')
BUILD   := $(CURDIR)/build

# v6.12 uses CONFIG_KVM; newer trees renamed the core symbol to CONFIG_KVM_X86.
# Passing both is harmless. Everything else (CONFIG_KVM_VFIO, _HYPERV, ...) comes
# from the target kernel's own auto.conf and therefore needs a kernel that was
# configured with KVM=m.
KCONFIG := CONFIG_KVM=m CONFIG_KVM_X86=m CONFIG_KVM_AMD=m CONFIG_KVM_INTEL=m

.PHONY: all stage check-config clean

all: check-config stage
	$(MAKE) -C $(KDIR) M=$(BUILD)/arch/x86/kvm $(KCONFIG) modules

check-config:
	@grep -Eq '^CONFIG_KVM(_X86)?=m' $(KDIR)/.config || \
	  { echo "warning: $(KDIR)/.config does not build KVM as a module; expect missing CONFIG_KVM_* symbols" >&2; }

stage:
	scripts/stage.sh '$(SRC_VER)' '$(BUILD)'

clean:
	rm -rf $(BUILD)
