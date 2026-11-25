#!/usr/bin/env bash
# Instalira alate potrebne za projekat (Ubuntu/Debian, uključujući WSL2). Pokrenuti jednom, kao običan korisnik.
# Idempotentna je: sigurno se može pokrenuti više puta.
set -euo pipefail

[ "$(id -u)" -ne 0 ] || { echo "Ne pokretati kao root; skripta sama koristi sudo."; exit 1; }
command -v apt-get >/dev/null || { echo "Potreban je apt (Ubuntu/Debian)."; exit 1; }
sudo -v

echo "== paketi: make, ansible, dig, rsync/curl/nc (Ansible i testovi), KVM/libvirt, Docker"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  make ansible bind9-dnsutils wget gpg lsb-release rsync curl netcat-openbsd \
  qemu-system-x86 libvirt-daemon-system libvirt-clients genisoimage \
  docker.io docker-compose-v2

echo "== Terraform (HashiCorp apt repozitorij)"
KEYRING=/usr/share/keyrings/hashicorp-archive-keyring.gpg
[ -f "$KEYRING" ] || wget -qO- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o "$KEYRING"
echo "deb [signed-by=$KEYRING] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y terraform

echo "== libvirt: servis, pool i mreža 'default'"
sudo systemctl enable --now libvirtd
V="sudo virsh -c qemu:///system"
$V pool-info default >/dev/null 2>&1 || { $V pool-define-as default dir --target /var/lib/libvirt/images; $V pool-autostart default; }
$V pool-start default >/dev/null 2>&1 || true
$V net-autostart default >/dev/null 2>&1 || true
$V net-start default >/dev/null 2>&1 || true

echo "== SSH ključ za VM (cloud-init ga stavlja korisniku admin)"
[ -f ~/.ssh/id_ed25519.pub ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519

echo "== korisnik u grupama libvirt, docker"
sudo usermod -aG libvirt,docker "$USER"

[ -e /dev/kvm ] || echo "UPOZORENJE: nema /dev/kvm; VM se ne može pokrenuti (u WSL2 uključiti nestedVirtualization)."
echo
echo "Gotovo. Odjavite se i prijavite ponovo (WSL: 'wsl --shutdown' u PowerShellu) da grupe počnu važiti."
