#!/usr/bin/env bash
# Provjere AO-1, AO-6, AO-7, AO-10. Zahtijeva VM_IP (make test ga postavlja).
set -u
cd "$(dirname "$0")/.."
: "${VM_IP:?postavi VM_IP}"
# Argumenti se citiraju (%q) jer ih udaljeni shell ponovo parsira.
# VM se kreira od nule s novim host ključem, pa se ključ ne pamti u known_hosts (isto kao SSH u Makefileu).
vm() { ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "admin@$VM_IP" sudo "$(printf '%q ' "$@")"; }
fail=0
if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; N=$'\e[0m'; fi
ok()  { printf "  [%s OK %s] %s\n" "${G:-}" "${N:-}" "$1"; }
bad() { printf "  [%sFAIL%s] %s\n" "${R:-}" "${N:-}" "$1"; fail=1; }
chk() { local naziv=$1; shift; if "$@" >/dev/null 2>&1; then ok "$naziv"; else bad "$naziv"; fi; }
nechk() { local naziv=$1; shift; if "$@" >/dev/null 2>&1; then bad "$naziv"; else ok "$naziv"; fi; }

echo "== aplikacija (frontend -> backend -> baza)"
chk  "GET /api/notes kroz nginx" curl -fs "http://$VM_IP/api/notes"
BILJESKA="test-$(date +%s)"
chk  "POST /api/notes" curl -fs -X POST -H 'Content-Type: application/json' -d "{\"text\": \"$BILJESKA\"}" "http://$VM_IP/api/notes"
curl -fs "http://$VM_IP/api/notes" | grep -q "$BILJESKA" && ok "bilješka se čita nazad" || bad "bilješka se čita nazad"

echo "== izolacija (AO-6)"
# Negativni test prolazi na bilo kakvu grešku (nema nc, nema DNS zapisa, kontejner ne radi).
# Zato prije svakog ide kontrola istim alatom s istog mjesta: ako ona prođe, pad znači mrežnu izolaciju.
chk   "kontrola: frontend -> app:8080 radi" vm docker exec frontend nc -zw2 app.proj.lab 8080
nechk "frontend -> db:5432 mora pasti"      vm docker exec frontend nc -zw2 db.proj.lab 5432
nechk "frontend -> db:5432 po IP-u pada"    vm docker exec frontend nc -zw2 "$(dig +short @"$VM_IP" db.proj.lab)" 5432
chk   "backend -> db:5432 radi"             vm docker exec backend bash -c 'exec 3<>/dev/tcp/db.proj.lab/5432'
chk   "kontrola: host -> VM:80 radi"        nc -zw2 "$VM_IP" 80
nechk "5432 nije dostupan izvana"           nc -zw2 "$VM_IP" 5432

echo "== DNS (AO-7): dig odgovara docker inspect"
for ime in web app db; do
  dig=$(dig +short @"$VM_IP" "$ime.proj.lab")
  real=$(vm docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$(case $ime in web) echo frontend;; app) echo backend;; db) echo db;; esac)")
  [[ " $real " == *" $dig "* && -n $dig ]] && ok "$ime.proj.lab = $dig" || bad "$ime.proj.lab ($dig) nije među [$real]"
done
[[ "$(dig +short @"$VM_IP" www.proj.lab CNAME)" == "web.proj.lab." ]] && ok "www CNAME -> web" || bad "www CNAME"

echo "== nema IP adresa u kodu aplikacije (AO-7; 0.0.0.0 je bind na sve interfejse, ne adresa)"
if grep -rEn '\b[0-9]{1,3}(\.[0-9]{1,3}){3}\b' app/frontend/nginx.conf app/frontend/index.html app/backend/src | grep -v '0\.0\.0\.0'; then bad "pronađene IP adrese"; else ok "bez IP adresa"; fi

echo "== tajne nisu u Gitu (AO-9)"
nechk ".secrets u historiji" bash -c 'git log --all --name-only --format= | grep -q "^.secrets/"'

echo "== trajnost podataka (AO-10)"
vm docker compose -f /opt/proj/compose.yaml --env-file /opt/proj/.env rm -sf db >/dev/null 2>&1
vm docker compose -f /opt/proj/compose.yaml --env-file /opt/proj/.env up -d --wait db >/dev/null 2>&1
sleep 3
curl -fs "http://$VM_IP/api/notes" | grep -q "$BILJESKA" && ok "bilješka preživjela ponovno kreiranje baze" || bad "bilješka izgubljena"

exit $fail
