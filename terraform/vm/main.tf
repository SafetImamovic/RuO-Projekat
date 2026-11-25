terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.8.3"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

variable "vm_name" {
  type    = string
  default = "proj"
}

variable "memory" {
  type        = number
  default     = 2048 # MiB; Rust se kompajlira na VM-u
  description = "RAM u MiB"
}

variable "vcpu" {
  type    = number
  default = 2
}

variable "disk_size_gb" {
  type    = number
  default = 20
}

variable "admin_user" {
  type    = string
  default = "admin"
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

# Sva imena u libvirtu (zajednička za cijeli host) izvode se iz vm_name,
# pa se dvije instance s različitim vm_name ne sudaraju.
resource "libvirt_volume" "base" {
  name   = "${var.vm_name}-base.qcow2"
  pool   = "default"
  format = "qcow2"
  source = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
}

resource "libvirt_volume" "disk" {
  name           = "${var.vm_name}.qcow2"
  pool           = "default"
  base_volume_id = libvirt_volume.base.id
  size           = var.disk_size_gb * 1024 * 1024 * 1024
}

resource "libvirt_cloudinit_disk" "init" {
  name = "${var.vm_name}-init.iso"
  pool = "default"
  user_data = templatefile("${path.module}/../../cloud-init/user-data.tftpl", {
    hostname   = var.vm_name
    admin_user = var.admin_user
    ssh_key    = trimspace(file(pathexpand(var.ssh_public_key_path)))
  })
}

resource "libvirt_domain" "vm" {
  name      = var.vm_name
  memory    = var.memory
  vcpu      = var.vcpu
  cloudinit = libvirt_cloudinit_disk.init.id

  disk {
    volume_id = libvirt_volume.disk.id
  }

  network_interface {
    network_name   = "default"
    wait_for_lease = true
  }

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }
}

# Inventory generisan iz Terraformovog stanja (DO-6)
resource "local_file" "inventory" {
  filename = "${path.module}/inventory.ini"
  content  = <<-EOT
    [servers]
    ${var.vm_name} ansible_host=${try(libvirt_domain.vm.network_interface[0].addresses[0], "")} ansible_user=${var.admin_user}
  EOT
}

output "ip" {
  value = try(libvirt_domain.vm.network_interface[0].addresses[0], "")
}
