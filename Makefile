# Troslojna aplikacija kao kod. Redoslijed: infra -> config -> dns -> deploy -> test
SHELL := /bin/bash
# Boje samo kad je izlaz terminal
ifneq ($(shell test -t 1 && echo y),)
  G := \033[32m
  R := \033[31m
  B := \033[1;36m
  D := \033[2m
  N := \033[0m
endif
STEP = @printf '\n$(B)==> %s$(N)\n' "$(1)"

.PHONY: help check infra config dns deploy ps endpoints tunnel ssh test drift backup all destroy clean

TF_VM  := terraform -chdir=terraform/vm
TF_DNS := terraform -chdir=terraform/dns
IP      = $$($(TF_VM) output -raw ip)
TSIG    = $$(cat .secrets/tsig_secret)
# VM se pri svakom podizanju kreira od nule s novim host ključem, često na istoj adresi.
# Ključ se zato ne pamti u ~/.ssh/known_hosts (inače "REMOTE HOST IDENTIFICATION HAS CHANGED").
SSH    := ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
# lokalni port za make tunnel: prvi slobodan od 8080 (npr. kad drugi klon već drži 8080),
# ili tačno zadani (make tunnel PORT=9000)
PORT   ?= 8080

help: ## lista ciljeva
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  $(B)%-8s$(N) %s\n", $$1, $$2}'

check: ## provjera alata i /dev/kvm
	$(call STEP,provjera okruženja)
	@for t in terraform ansible-playbook docker dig virsh nsupdate; do \
	  if command -v $$t >/dev/null; then printf "  [$(G) OK $(N)] %-18s $(D)%s$(N)\n" $$t "$$(command -v $$t)"; \
	  else printf "  [$(R)FAIL$(N)] %-18s nije instaliran (./setup.sh)\n" $$t; fi; done
	@if test -e /dev/kvm; then printf "  [$(G) OK $(N)] %-18s\n" /dev/kvm; else printf "  [$(R)FAIL$(N)] %-18s\n" /dev/kvm; fi

infra: ## Terraform: VM + cloud-init + inventory.ini
	@scripts/step.sh "terraform init (VM)" $(TF_VM) init -input=false
	@scripts/step.sh "VM + cloud-init (libvirt)" $(TF_VM) apply -auto-approve -input=false

config: ## Ansible: Docker, BIND (tagovi docker, dns)
	@scripts/step.sh "Ansible: Docker + BIND" bash -c 'cd ansible && ansible-playbook site.yml --tags config'

dns: ## Terraform: DNS zapisi kroz RFC 2136 + TSIG
	@scripts/step.sh "terraform init (DNS)" $(TF_DNS) init -input=false
	@scripts/step.sh "DNS zapisi (RFC 2136)" env TF_VAR_dns_server=$(IP) TF_VAR_tsig_secret=$(TSIG) $(TF_DNS) apply -auto-approve -input=false

deploy: ## Ansible: izgradnja i pokretanje aplikacije
	@scripts/step.sh "Ansible: build Rust + pokretanje aplikacije" bash -c 'cd ansible && ansible-playbook site.yml --tags deploy'

ps: ## kontejneri u VM-u (docker na hostu ih ne vidi)
	@$(SSH) admin@$(IP) "sudo docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Networks}}'"

endpoints: ## nginx lokacije i kamo ih prosljeđuje (iz pokrenutog kontejnera)
	@ip=$(IP); $(SSH) admin@$$ip "sudo docker exec frontend nginx -T 2>/dev/null" \
	  | awk -v base="http://$$ip" '$$1=="location"{loc=$$2} loc && ($$1=="proxy_pass" || $$1=="root"){ \
	      t=$$2; sub(/;$$/,"",t); if ($$1=="root") t=t loc; \
	      printf "  %-32s -> %-36s %s\n", base loc "*", t "*", ($$1=="root" ? "statički fajlovi" : "proxy"); loc="" }'

tunnel: ## SSH tunel: aplikacija na http://localhost:8080 ili prvom slobodnom (i iz Windows preglednika; PORT=...)
	@ip=$(IP); p=$(PORT); \
	  if [ "$(origin PORT)" = file ]; then while ss -Hltn "sport = :$$p" | grep -q .; do p=$$((p + 1)); done; fi; \
	  printf "  http://localhost:$$p -> $$ip:80  (Ctrl+C za kraj)\n"; \
	  $(SSH) -N -o ExitOnForwardFailure=yes -L $$p:localhost:80 admin@$$ip

ssh: ## prijava na VM (korisnik admin, samo ključem)
	@$(SSH) admin@$(IP)

test: ## izolacija, DNS, aplikacija, tajne
	$(call STEP,testovi)
	VM_IP=$(IP) bash tests/test.sh

drift: ## demonstracija drifta: nsupdate mimo koda, plan, apply
	$(call STEP,demonstracija drifta)
	VM_IP=$(IP) TSIG_SECRET=$(TSIG) bash tests/drift.sh

backup: ## pg_dump u backups/ (nije dio AO)
	$(call STEP,backup baze)
	mkdir -p backups
	$(SSH) admin@$(IP) "sudo docker exec db pg_dump -U app app" | gzip > backups/$$(date +%F-%H%M).sql.gz

all: infra config dns deploy test ## cijelo okruženje od nule

destroy: ## uklanja VM i lokalno stanje DNS-a
	@scripts/step.sh "uklanjanje VM-a" $(TF_VM) destroy -auto-approve -input=false
	rm -f terraform/dns/terraform.tfstate*

# Briše sve što .gitignore ignoriše (git clean -X), osim .notes/ i backups/ (lični podaci).
# Odbija ako Terraform još vodi VM: brisanje state-a bi ostavilo VM bez upravljanja,
# a brisanje .secrets/ bazu sa lozinkom koju više niko nema. Zato: make destroy clean.
clean: ## repo kao svjež klon (prvo make destroy)
	$(call STEP,čišćenje repozitorija)
	@if [ -f terraform/vm/terraform.tfstate ]; then \
	  res=$$($(TF_VM) state list) || exit 1; \
	  if [ -n "$$res" ]; then printf "  [$(R)FAIL$(N)] VM još postoji, prvo: make destroy\n"; exit 1; fi; \
	fi
	git clean -fdX -e '!.notes/' -e '!backups/'
