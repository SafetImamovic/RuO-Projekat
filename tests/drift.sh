#!/usr/bin/env bash
# Demonstracija drifta (AO-8): izmjena zapisa mimo koda, plan ga vidi, apply ga vraća.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${VM_IP:?}" "${TSIG_SECRET:?}"
export TF_VAR_dns_server=$VM_IP TF_VAR_tsig_secret=$TSIG_SECRET
TF="terraform -chdir=terraform/dns"

echo "== izmjena db.proj.lab mimo koda (nsupdate)"
nsupdate -y "hmac-sha256:tsig-proj:$TSIG_SECRET" <<EOT
server $VM_IP
zone proj.lab
update delete db.proj.lab A
update add db.proj.lab 300 A 10.40.0.99
send
EOT
dig +short @"$VM_IP" db.proj.lab

echo "== plan pokazuje drift"
$TF plan -input=false -detailed-exitcode || [ $? -eq 2 ]

echo "== apply vraća stanje"
$TF apply -auto-approve -input=false
dig +short @"$VM_IP" db.proj.lab
