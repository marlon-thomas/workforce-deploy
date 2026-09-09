# Vagrantfile — Care Angels Workforce Suite, DEV environment
# (environments-design.md §5: local triage VM on libvirt/KVM)
#
# The VM is intentionally BARE: it runs `bootstrap.py` from the host (which
# clones the deployment bundle and hands over to install.sh interactively).
# Vagrant only creates and reaches the box.
#
# Usage:
#   cd deploy/environments
#   vagrant up                    # libvirt/KVM (4 GB / 2 vCPU)
#   vagrant ssh-config            # feeds bootstrap.py --vagrant
#
# Networking: NAT (default libvirt) + port forwards 80/443 on localhost.
# TLS uses DNS-01 via DuckDNS (no inbound internet needed) — see
# environments/dev.env TLS_MODE and the Caddyfile DNS-01 block.
#
# Snapshots make resets instant:
#   vagrant snapshot save clean   # after first successful boot
#   vagrant snapshot restore clean; vagrant up   # ~40s back to bare OS

VAGRANTFILE_API_VERSION = "2"

MEM  = ENV.fetch("VAGRANT_MEM",  "4096").to_i
CPUS = ENV.fetch("VAGRANT_CPUS", 2).to_i

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
  config.vm.box = "bento/ubuntu-24.04"
  config.vm.hostname = "workforce-dev"

  # Forward the gateway ports to the HOST loopback: the tailnet device (your
  # laptop) reaches the VM through the host — no bridge, no router changes.
  config.vm.network "forwarded_port", guest: 80,  host: 8080
  config.vm.network "forwarded_port", guest: 443, host: 8443

  config.vm.provider :libvirt do |lv|
    lv.memory = MEM
    lv.cpus   = CPUS
    lv.machine_type = "q35"
  end
  config.vm.provider :virtualbox do |vb|
    vb.memory = MEM
    vb.cpus   = CPUS
  end

  # Bare box provisioning ONLY: OS-level basics the installer assumes.
  config.vm.provision "shell", inline: <<-'SHELL'
    set -e
    apt-get update -qq
    apt-get install -y -qq git curl ca-certificates python3 >/dev/null
    # Tailscale (dev TLS_MODE=tailscale: the VM joins the tailnet so the
    # laptop browser and bootstrap.py reach it directly).
    curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1 || true
    echo "Bare box ready. Run from the host:"
    echo "  python3 ../bin/bootstrap.py --vagrant --env dev"
  SHELL
end
