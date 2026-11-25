#!/usr/bin/env bash
# Pokreće naredbu uz spinner, proteklo vrijeme i "živi" prozor zadnjih linija izlaza.
# Cijeli izlaz ide u .logs/; pri grešci se ispisuje kraj loga.
# Upotreba: scripts/step.sh "opis" naredba [argumenti...]     (V=1: bez prozora, cijeli izlaz)
label=$1; shift
if [ ! -t 1 ] || [ -n "${V:-}" ]; then printf '==> %s\n' "$label"; exec "$@"; fi

G=$'\e[32m' R=$'\e[31m' C=$'\e[36m' Y=$'\e[33m' D=$'\e[2m' N=$'\e[0m'
H=${WINDOW_LINES:-6}                 # broj linija živog prozora
mkdir -p .logs
log=".logs/$(echo "$label" | tr -c 'A-Za-z0-9' '_').log"
start=$SECONDS
"$@" >"$log" 2>&1 &
pid=$!
cleanup() { printf '\e[%dA\r\e[J' $((H + 1)); }
trap 'kill $pid 2>/dev/null; cleanup; printf "  [%sPREKINUTO%s] %s\n" "$Y" "$N" "$label"; exit 130' INT TERM

fmt_t() { printf '%02d:%02d' $(($1 / 60)) $(($1 % 60)); }
# izlaz bez ANSI boja i kontrolnih znakova
clean() { sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g' | tr -d '\r' | tr '\t' ' '; }

frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏); i=0
printf '\n%.0s' $(seq 0 "$H")        # rezerviši prostor za prozor
while kill -0 $pid 2>/dev/null; do
  w=$(tput cols); t=$((SECONDS - start))
  # trenutni korak: zadnji Ansible TASK ili Terraform resurs
  step=$(clean <"$log" | grep -E '^TASK \[|^[a-z_]+\.[^ ]+: (Creating|Modifying|Destroying|Still)' | tail -n1 | cut -c1-$((w - ${#label} - 24)))
  mapfile -t lines < <(clean <"$log" | grep -v '^\s*$' | tail -n "$H" | cut -c1-$((w - 6)))
  printf '\e[%dA' $((H + 1))
  printf '\r\e[K  [%s%s%s] %s%s%s %s%s%s  %s%s%s\n' "$C" "${frames[i++ % 10]}" "$N" "$C" "$label" "$N" "$D" "$(fmt_t $t)" "$N" "$Y" "$step" "$N"
  for ((n = 0; n < H; n++)); do
    printf '\r\e[K    %s│ %s%s\n' "$D" "${lines[n]:-}" "$N"
  done
  sleep 0.1
done
wait $pid; rc=$?
t=$((SECONDS - start))
cleanup
if [ $rc -eq 0 ]; then
  printf '  [%s OK %s] %s %s(%s)%s\n' "$G" "$N" "$label" "$D" "$(fmt_t $t)" "$N"
else
  printf '  [%sFAIL%s] %s %s(%s)%s\n' "$R" "$N" "$label" "$D" "$(fmt_t $t)" "$N"
  clean <"$log" | tail -n 30 | sed "s/^/    ${R}│${N} /"
  printf '    %spuni log: %s%s\n' "$D" "$log" "$N"
fi
exit $rc
