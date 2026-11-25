terraform {
  required_providers {
    dns = {
      source  = "hashicorp/dns"
      version = "~> 3.4"
    }
  }
}

variable "dns_server" {
  type        = string
  description = "Adresa BIND servera (upravljačka adresa VM-a: terraform -chdir=../vm output -raw ip)"
}

variable "tsig_secret" {
  type        = string
  sensitive   = true
  description = "TSIG tajna ključa tsig-proj (.secrets/tsig_secret)"
}

variable "zona" {
  type    = string
  default = "proj.lab."
}

# Adrese se čitaju iz app/compose.yaml (jedini izvor plana adresiranja), ne prepisuju se ovdje.
# Ime zapisa -> adresa kontejnera na segmentu preko kojeg mu klijenti pristupaju.
locals {
  svc = yamldecode(file("${path.module}/../../app/compose.yaml")).services
  servisi = {
    web = local.svc.frontend.networks.web.ipv4_address
    app = local.svc.backend.networks.app.ipv4_address
    db  = local.svc.db.networks.db.ipv4_address
  }
}

# RFC 2136 UPDATE, potpisan TSIG ključem koji smije mijenjati samo zonu proj.lab (tipovi A i CNAME)
provider "dns" {
  update {
    server        = var.dns_server
    key_name      = "tsig-proj."
    key_algorithm = "hmac-sha256"
    key_secret    = var.tsig_secret
  }
}

resource "dns_a_record_set" "servis" {
  for_each  = local.servisi
  zone      = var.zona
  name      = each.key
  addresses = [each.value]
  ttl       = 300
}

resource "dns_cname_record" "www" {
  zone  = var.zona
  name  = "www"
  cname = "web.${var.zona}"
  ttl   = 300
}
