# Vagrantfile — Care Angels Workforce Suite, TEST environment
# (environments-design.md §5: Ubuntu 24.04 appliance on any host OS)
#
# Works on Linux (libvirt/KVM or VirtualBox), Windows (VirtualBox or Hyper-V)
# and macOS (VirtualBox / QEMU / libvirt). Provider selection is automatic by
# host OS, overridable:  VAGRANT_PROVIDER=libvirt|virtualbox|hyperv|vmware
#
# The VM is intentionally BARE: it runs bootstrap.py from the host (which
# clones the deployment bundle and hands over to install.sh interactively).
# Vagrant only creates and reaches the box.
#
# Usage (from any OS, in this directory):
#   vagrant up                    # boots the appliance
#   vagrant ssh-config            # feeds bootstrap.py --vagrant --env test
#
# Networking: NAT + forwarded ports (80/443 -> host 8080/8443) on every
# provider. TLS for the test environment is DNS-01 via DuckDNS — the ACME
# challenge needs no inbound internet, so no router or bridged networking is
# ever required. The developer's browser reaches the app on
# https://localhost:8443 (or the DuckDNS hostname if the host forwards).
#
# Snapshots make resets instant (provider support varies; libvirt/virtualbox/hyperv):
#   vagrant snapshot save clean   # after first successful boot
#   vagrant snapshot restore clean; vagrant up   # ~40s back to bare OS

VAGRANTFILE_API_VERSION = "2"

MEM  = ENV.fetch("VAGRANT_MEM",  "4096").to_i
CPUS = ENV.fetch("VAGRANT_CPUS", 2).to_i

# --- provider selection -----------------------------------------------------
# Order of preference per host OS; VAGRANT_PROVIDER overrides everything.
def detect_provider
  override = ENV["VAGRANT_PROVIDER"]
  return override if override && !override.empty?

  case RUBY_PLATFORM
  when /mswin|mingw/
    # Windows: Hyper-V if it is enabled, else VirtualBox.
    # (Detect by probing for the hyperv management service via WMI.)
    hv = system("powershell -Command \"exit (Get-Service vmms -ErrorAction SilentlyContinue) -ne $null\"") rescue false
    hv ? "hyperv" : "virtualbox"
  when /darwin/
    "virtualbox"   # QEMU plugin is an alternative (VAGRANT_PROVIDER=qemu)
  else
    # Linux: libvirt when the daemon is around, else VirtualBox.
    system("systemctl is-active libvirtd >/dev/null 2>&1") ? "libvirt" : "virtualbox"
  end
end

PROVIDER = detect_provider

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
  config.vm.box = "bento/ubuntu-24.04"   # multi-provider box: libvirt, virtualbox, hyperv
  config.vm.hostname = "workforce-test"

  # Forwarded ports on ALL providers: the developer's browser reaches the app
  # at https://localhost:8443 regardless of host OS.
  config.vm.network "forwarded_port", guest: 80,  host: 8080
  config.vm.network "forwarded_port", guest: 443, host: 8443

  # Shared folder: none — the bundle is cloned ON the VM by bootstrap.py
  # (avoids host-guest sync quirks across Windows/macOS/Linux filesystems).
  # The default /vagrant share MUST be explicitly disabled, otherwise
  # vagrant-libvirt falls back to NFS and tries to apt-install nfs-common
  # in the guest before the guest has working internet.
  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.provider PROVIDER do |pv|
    pv.memory = MEM
    pv.cpus   = CPUS
  end

  if PROVIDER == "libvirt"
    config.vm.provider :libvirt do |lv|
      lv.machine_type = "q35"
      lv.cpu_mode = "host-passthrough"
    end
  elsif PROVIDER == "hyperv"
    config.vm.provider :hyperv do |hv|
      hv.enable_virtualization_extensions = true
    end
  end

  # Bare-box provisioning: NONE. `vagrant up` is boot-only and offline-safe;
  # everything guest-side (git/curl/tailscale, bundle, installer) is done by
  # bootstrap.py over SSH, which can retry and diagnose. A vagrant provisioner
  # that apt-installs would fail confusingly when guest internet is flaky.
end
