---
title: "Troslojna aplikacija kao kod"
subtitle: "Dizajnerske odluke (DO) i ADR-ovi"
author: "IME PREZIME"
date: "25.11.2026."
lang: bs
---

| | |
|---|---|
| **Predmet** | Računarstvo u oblaku, II ciklus, III semestar, 2026/27 |
| **Student** | IME PREZIME |
| **Repozitorij** | URL REPOZITORIJA |

# Opis aplikacije i arhitekture

**Aplikacija.** „Bilješke“ je vlastita mala web aplikacija: korisnik upisuje kratku bilješku i vidi listu svih bilješki. Ima tri sloja:

- **frontend:** nginx služi statični `index.html` i prosljeđuje `/api/*` backendu;
- **backend:** HTTP server u Rustu (`GET /health`, `GET /notes`, `POST /notes`);
- **baza:** PostgreSQL 16, a podaci su na imenovanom volumenu `pgdata`.

Uz njih radi **BIND**, autoritativni DNS server za zonu projekta `proj.lab`.

**Arhitektura.** Terraform kreira jednu VM (Debian 13, KVM/libvirt), a cloud-init radi njenu početnu konfiguraciju. Ansible zatim instalira Docker, podiže BIND i aplikaciju. Slojevi su u tri Docker mreže s fiksnim podmrežama (web, app, db), a svaki kontejner je samo na mrežama koje mu trebaju. DNS zapise servisa vodi drugi Terraform projekat kroz RFC 2136 i TSIG. Tok zahtjeva je isključivo frontend → backend → baza.

```
 Host (Ubuntu/WSL2): make → terraform/vm, ansible, terraform/dns
        │ libvirt          │ SSH               │ RFC 2136 + TSIG (:53)
        ▼                  ▼                   ▼
 ┌─ VM "proj" (Debian 13), VM_MGMT_IP na 192.168.122.0/24 ──────────┐
 │                                                                  │
 │  web 10.40.0.0/29     app 10.40.0.8/29       db 10.40.0.16/29    │
 │  ┌───────────────┐    ┌──────────────────┐   ┌────────────────┐  │
 │  │ frontend .2   │    │ backend .11      │   │ PostgreSQL .19 │  │
 │  │ (nginx) :80 ◄─┼─ korisnik            │   │ bez porta      │  │
 │  │       .10 ────┼───►  :8080 ── .18 ───┼──►│ volume pgdata  │  │
 │  └───────────────┘    │ BIND .12 :53     │   └────────────────┘  │
 │                       └──────────────────┘    internal: true     │
 │  frontend → baza: nema mrežnog puta (frontend nije na mreži db)  │
 └──────────────────────────────────────────────────────────────────┘
```

# Pregled dizajnerskih odluka

| DO | Pitanje | Izabrana opcija |
|---|---|---|
| DO-1 | Aplikacija i tehnologije | Vlastita aplikacija: nginx + HTML, Rust (`tiny_http`, `postgres`), PostgreSQL 16 |
| DO-2 | Broj VM-ova i raspored | Opcija A: jedna VM; segmenti su Docker mreže; BIND na istoj VM-i |
| DO-3 | Plan adresiranja | Tri /29 podmreže iz 10.40.0.0/27, statične adrese kontejnera s jednim izvorom (`compose.yaml`); VM preko DHCP-a |
| DO-4 | Bazna slika VM-a | Javna Debian 13 genericcloud slika + cloud-init |
| DO-5 | Slike kontejnera | Build na ciljnoj VM-i, multi-stage Dockerfile, ponovni build samo kad se promijeni kod |
| DO-6 | Adrese za Ansible | `inventory.ini` generisan iz Terraformovog stanja (`local_file`) |
| DO-7 | Role i varijable | Role po funkciji (`docker`, `dns`, `app`); konstante u `defaults`, okruženje u `group_vars` |
| DO-8 | DNS zona | `proj.lab`, TTL 300, jedan primarni server, dinamička zona, TSIG ograničen na zonu i tipove A/CNAME |
| DO-9 | Tajne | Generišu se pri prvom pokretanju u `.secrets/` van Gita; bez ansible-vaulta |

# DO-1: Aplikacija i tehnologije slojeva

Status: prihvaćeno

## Kontekst
Treba izabrati aplikaciju s tri zasebna sloja (frontend, backend, baza), svaki u svom kontejneru, i tokom zahtjeva frontend → backend → baza (AO-1). Aplikacija se ne ocjenjuje, ali od nje zavisi koliko je teško graditi slike, podizati servise i testirati ih. Baza mora čuvati podatke i kad se njen kontejner ponovo kreira (AO-10).

## Razmotrene opcije
1. Gotov open-source projekat (npr. aplikacija s Node.js ili Django backendom).
2. Vlastita minimalna aplikacija: statični HTML iza nginxa, backend u Rustu, PostgreSQL.
3. Vlastita aplikacija s MongoDB-om umjesto relacione baze.

## Odluka
Opcija 2: vlastita aplikacija „bilješke“. Frontend je nginx (`nginx:alpine`) sa statičnim HTML-om i reverse proxyjem `/api/` → `http://app.proj.lab:8080/`. Backend je Rust (`tiny_http` + `postgres`). Baza je PostgreSQL 16 (`postgres:16-alpine`).

## Obrazloženje i posljedice
- Vlastitu aplikaciju razumijem do kraja, pa na odbrani mogu objasniti svaki red koda. Gotov projekat donosi konfiguraciju koju nisam pisao.
- nginx ima dvije uloge: služi statični sadržaj i jedina je ulazna tačka (AO-6). Preglednik razgovara samo s frontendom, pa nema CORS-a i backend ne treba nikakav objavljen port.
- Backend se adresira imenom `app.proj.lab`, a baza imenom `db.proj.lab` (AO-7).
- PostgreSQL ima službenu sliku s `pg_isready` za healthcheck, a podatke drži u jednom direktoriju koji se lako montira na volumen (AO-10).
- Gubi se: Rust se dugo kompajlira (prvi build na VM-i traje nekoliko minuta i traži oko 2 GiB RAM-a, vidi DO-5). Aplikacija je minimalna: nema autentikacije ni migracija šeme, a tabelu kreira backend sa `CREATE TABLE IF NOT EXISTS`.

# DO-2: Broj VM-ova i raspored komponenti

Status: prihvaćeno

## Kontekst
Slojevi moraju biti mrežno izolovani: svaki u svom segmentu s vlastitom podmrežom, izvana je dostupan samo frontend, frontend nema put do baze, a baza nema objavljen port (AO-6). Treba i autoritativni DNS (AO-7). VM-ove kreira Terraform (AO-3), a host je WSL2 s ugniježđenom virtualizacijom i ograničenim RAM-om.

## Razmotrene opcije
1. **A:** jedna VM; segmenti su Docker bridge mreže s fiksnim podmrežama; kontejner je priključen samo na mreže koje mu trebaju.
2. **B:** po jedna VM za svaki segment na libvirt mrežama u `route` modu; host usmjerava promet između njih; DNS na zasebnoj ili zajedničkoj VM-i.

## Odluka
Opcija A, a BIND je kontejner na istoj VM-i, na segmentu `app`.

## Obrazloženje i posljedice
- Izolacija se postiže na nivou priključenja: frontend je na mrežama `web` i `app`, backend na `app` i `db`, a baza samo na `db`. Frontend nema interfejs na mreži `db`. Promet između različitih bridge mreža Docker blokira iptables pravilima, pa ne prolazi ni direktan pokušaj po IP adresi. Mreža `db` je `internal: true`, bez izlaza prema vani.
- Jedna VM znači jedan cloud-init, jednu Ansible grupu i kraće podizanje od nule (AO-2). To je bitno na odbrani i na računaru s ograničenim RAM-om pod WSL2.
- Izolacija se provjerava testom s pozitivnom kontrolom: frontend → `app.proj.lab:8080` mora proći, a frontend → `db.proj.lab:5432` (i po imenu i po IP-u) mora pasti.
- BIND je na `app` segmentu jer ga koriste frontend i backend. Njegov port 53 je objavljen samo na upravljačkoj adresi VM-a, jer Terraform s hosta šalje RFC 2136 update (AO-8). To je upravljački kanal, a ne sloj aplikacije. Zaštićen je TSIG-om, a server nije rekurzivan.
- Gubi se: sve granice su u jednom kernelu i zavise od Docker iptables pravila. Ko dobije root na VM-i, zaobilazi sve segmente. Opcija B bi davala izolaciju na nivou hipervizora i rutiranja, ali uz tri puta više VM-ova, ručno održavane rute na hostu i znatno duže podizanje.

# DO-3: Plan adresiranja

Status: prihvaćeno

## Kontekst
Svaki segment treba vlastitu podmrežu (AO-6). Komponente se obraćaju jedna drugoj samo DNS imenima (AO-7), a DNS zapisi su Terraform resursi (AO-8). Zapisi zato moraju pokazivati na adrese koje se ne mijenjaju pri ponovnom kreiranju kontejnera. Adresu VM-a dodjeljuje libvirt.

## Razmotrene opcije
1. Dinamičke adrese kontejnera (Docker IPAM) i Dockerov ugrađeni DNS.
2. Statične adrese kontejnera u fiksnim podmrežama, upisane ručno i u `compose.yaml` i u Terraform.
3. Statične adrese kontejnera s jednim izvorom (`compose.yaml`), iz kojeg ih čitaju Terraform i Ansible.

## Odluka
Opcija 3. Plan je sljedeći.

| Segment | Podmreža | Gateway | Adrese |
|---|---|---|---|
| web | 10.40.0.0/29 | .1 | frontend .2 |
| app | 10.40.0.8/29 | .9 | frontend .10, backend .11, BIND .12 |
| db | 10.40.0.16/29 | .17 | backend .18, PostgreSQL .19 |
| upravljanje | 192.168.122.0/24 | libvirt | VM preko DHCP-a (Terraform output `ip`) |

`terraform/dns` čita adrese kroz `yamldecode(file(".../compose.yaml"))`, a Ansible rola `dns` adresu `ns1` kroz `from_yaml`. Adresa BIND-a je u compose-u jedan YAML anker (`x-dns-ip`).

## Obrazloženje i posljedice
- Statične adrese su preduvjet da DNS zapisi pod Terraformom budu stabilni. Opcija 1 bi zaobišla vlastiti BIND (AO-7), a adrese bi se mijenjale pri svakom ponovnom kreiranju kontejnera.
- Jedan izvor istine: adresa se mijenja na jednom mjestu, a `make all` je prenese i u kontejnere i u DNS. Opcija 2 bi dopuštala da se kopije razidu bez ikakvog upozorenja. Test uz to poredi odgovor `dig` sa `docker inspect`.
- Podmreže /29 su dovoljne (6 adresa po segmentu) i jasno pokazuju granice segmenata. Blok 10.40.0.0/27 se ne preklapa s libvirt mrežom 192.168.122.0/24 ni s Dockerovom podrazumijevanom 172.17.0.0/16.
- Adresa VM-a je dinamička jer je dodjeljuje libvirt `default` mreža. Iz koda se ne čita, nego ide kroz Terraform output (DO-6).
- Gubi se: Terraform DNS zavisi od strukture `compose.yaml`. Preimenovanje servisa ili mreže ruši `terraform plan`, ali s jasnom greškom, a ne tiho. Podmreže /29 nemaju mjesta za više od nekoliko instanci po segmentu.

# DO-4: Bazna slika VM-a

Status: prihvaćeno

## Kontekst
VM kreira Terraform (AO-3). Početnu konfiguraciju radi cloud-init: korisnik za upravljanje sa SSH ključem, prijava lozinkom onemogućena (AO-4). Okruženje se mora moći podići od nule bez ručnih koraka (AO-2).

## Razmotrene opcije
1. Javna cloud slika (Debian 13 genericcloud) + cloud-init.
2. Vlastita slika izgrađena Packerom, sa unaprijed instaliranim Dockerom.

## Odluka
Opcija 1. Terraform skida `debian-13-genericcloud-amd64.qcow2` u libvirt pool `default`, pravi disk od 20 GiB kao copy-on-write nadogradnju te slike i cloud-init ISO iz šablona `cloud-init/user-data.tftpl`. Šablon postavlja `ssh_pwauth: false`, korisnika `admin` sa `lock_passwd: true`, javni SSH ključ i `sudo` bez lozinke.

## Obrazloženje i posljedice
- Nema dodatnog alata ni koraka izgradnje slike. Cijeli tok je Terraform → cloud-init → Ansible, a sva konfiguracija je na jednom mjestu (Ansible), umjesto da bude podijeljena između Packera i Ansiblea.
- `genericcloud` slika je mala i već sadrži cloud-init. Ansible čeka da on završi (`cloud-init status --wait`) prije bilo kakve konfiguracije.
- Gubi se: Docker i ostali paketi se instaliraju pri svakom podizanju, pa je prvo podizanje sporije nego s Packer slikom. URL `latest` nije zaključan na verziju i nema provjere checksuma, pa dva podizanja u različito vrijeme mogu dobiti različitu baznu sliku. Za produkciju bi trebalo zaključati verziju i dodati checksum.

# DO-5: Izgradnja i distribucija slika kontejnera

Status: prihvaćeno

## Kontekst
Frontend i backend su vlastiti kod koji treba upakovati u slike (AO-1). Drugo izvršavanje playbooka mora dati `changed=0` (AO-5). Nema registryja koji bi bio dio projekta.

## Razmotrene opcije
1. Build na ciljnoj VM-i: Ansible prenese izvorni kod, a `docker compose` gradi slike.
2. Build lokalno na hostu i push u registry (javni ili vlastiti), pa pull na VM-i.
3. Build lokalno, pa `docker save` / `docker load` preko SSH-a.

## Odluka
Opcija 1, s multi-stage Dockerfileom za backend. Prva faza (`rust:slim`) kompajlira; ovisnosti se grade u zasebnom sloju koji ostaje keširan dok se `Cargo.toml` i `Cargo.lock` ne promijene. Druga faza (`debian:stable-slim`) sadrži samo binarni fajl i radi kao neprivilegovani korisnik `notes`. Kod se prenosi modulom `synchronize` (rsync, bez `target/`), a slike se ponovo grade (`build: always`) samo kad `synchronize` stvarno prenese promjenu. Inače se koristi `build: policy`.

## Obrazloženje i posljedice
- Nema registryja ni pristupnih podataka za njega. To je jedna tajna i jedna komponenta manje (AO-9), a podizanje od nule zavisi samo od VM-a.
- Multi-stage build daje malu završnu sliku bez kompajlera.
- Uslovni build daje idempotentnost: drugo izvršavanje playbooka daje `changed=0`, a izmjena koda i dalje pokreće novi build.
- Gubi se: kompajliranje troši CPU i RAM VM-a (zato 2 GiB). Slike nisu verzionisane ni potpisane. Bazne slike `rust:slim` i `debian:stable-slim` nisu zaključane na digest, pa build nije potpuno ponovljiv kroz vrijeme.

# DO-6: Kako Ansible dobija adrese VM-ova

Status: prihvaćeno

## Kontekst
Adresu VM-a dodjeljuje libvirt preko DHCP-a i ona se mijenja pri svakom ponovnom kreiranju. Ansible je mora znati bez ručnog koraka (AO-2), a adrese su Terraform outputi (AO-3).

## Razmotrene opcije
1. Ručni inventory.
2. Inventory generisan iz Terraformovog stanja (`local_file`).
3. Dinamički inventory (plugin `community.libvirt.libvirt` ili čitanje `terraform output -json`).

## Odluka
Opcija 2. Resurs `local_file.inventory` u `terraform/vm` piše `inventory.ini` sa `ansible_host` i `ansible_user`, a `ansible.cfg` pokazuje na taj fajl. Ista adresa je i output `ip`, koji Makefile prosljeđuje `terraform/dns` i testovima.

## Obrazloženje i posljedice
- `terraform apply` u jednom koraku proizvede i VM i inventory, pa nema ručnog prepisivanja adrese.
- Fajl se može otvoriti i provjeriti, što je jednostavnije za debugiranje od dinamičkog inventoryja.
- `inventory.ini` je generisan, pa je u `.gitignore`.
- Gubi se: inventory je statičan snimak. Ako se adresa promijeni mimo Terraforma (npr. istekne DHCP lease), treba ponovo pokrenuti `terraform apply`. Dinamički inventory bi to riješio, ali uz dodatni plugin i zavisnost.

# DO-7: Organizacija Ansible rola i varijabli

Status: prihvaćeno

## Kontekst
Konfiguraciju radi Ansible organizovan u role, a playbook mora biti idempotentan (AO-5). Makefile odvojeno pokreće osnovnu konfiguraciju (`make config`) i isporuku aplikacije (`make deploy`), a između njih Terraform upisuje DNS zapise.

## Razmotrene opcije
1. Role po komponenti (frontend, backend, db, dns).
2. Role po funkciji (`docker`, `dns`, `app`).
3. Jedan playbook bez rola.

## Odluka
Opcija 2, uz tagove: `docker` je u `config` i `deploy`, `dns` u `config`, a `app` u `deploy`. Konstante uloga su u `roles/*/defaults` (npr. `dns_uid`, `dns_ttl`, `tsig_key_name`). Vrijednosti okruženja i tajne su u `group_vars/all.yml` (`project_dir`, `zone`, `db_password`, `tsig_secret`). Adresa `dns_ns_address` se čita iz `compose.yaml` (DO-3).

## Obrazloženje i posljedice
- Frontend, backend i baza se svi podižu istim mehanizmom (`docker compose`), pa bi role po komponenti bile gotovo prazne i međusobno bi se ponavljale. Role po funkciji odgovaraju stvarnim koracima: Docker okruženje, DNS server, isporuka aplikacije.
- Tagovi omogućuju redoslijed config → dns → deploy, gdje Terraform upisuje zapise između dva Ansible koraka.
- `defaults` imaju najniži prioritet, pa ih je lako pregaziti. Vrijednosti koje zavise od okruženja su na jednom mjestu u `group_vars`.
- Idempotentnost: `template` i `copy` mijenjaju fajl samo kad se sadržaj razlikuje. Zona se piše s `force: false`, jer je BIND poslije prve izmjene vodi kroz žurnal (`.jnl`). Build je uslovan (DO-5).
- Gubi se: role `dns` i `app` dijele `compose.yaml` iz role `docker`, pa nisu potpuno nezavisne i moraju se izvršavati u definisanom redoslijedu.

# DO-8: Dizajn DNS zone

Status: prihvaćeno

## Kontekst
Projekat ima vlastitu autoritativnu zonu na BIND-u (AO-7). Zapisi servisa su Terraform resursi (provider `hashicorp/dns`, RFC 2136), a TSIG ključ smije mijenjati samo zonu projekta (AO-8). Mora se moći pokazati drift.

## Razmotrene opcije
1. Statična zona koju u potpunosti piše Ansible (zapisi nisu Terraform resursi, pa AO-8 nije ispunjen).
2. Dinamička zona: Ansible postavlja samo početni SOA/NS/`ns1`, a zapise servisa upisuje Terraform kroz RFC 2136.
3. Kao 2, plus PTR zapisi, sekundarni server i round-robin.

Za ime zone razmatrani su `proj.lab`, `home.arpa` (RFC 8375) i `.internal`.

## Odluka
Opcija 2, zona `proj.lab`, TTL 300.

- Ansible: `named.conf` (`recursion no`, `allow-transfer { none; }`), `keys.conf` s TSIG ključem i početna zona sa SOA, NS i `ns1 A 10.40.0.12`.
- Terraform: `dns_a_record_set` za `web`, `app` i `db`, te `dns_cname_record` `www` → `web.proj.lab.`.
- Politika: `update-policy { grant tsig-proj zonesub A CNAME; }`.

## Obrazloženje i posljedice
- Terraform vodi zapise, pa `terraform plan` otkriva izmjenu mimo koda (drift), a `apply` je vraća. To je pokazano sa `nsupdate` na `db.proj.lab`.
- `zonesub` ograničava ključ na imena unutar zone `proj.lab`, a lista tipova na A i CNAME. Ključ ne može mijenjati SOA ni NS, niti bilo koju drugu zonu.
- TTL 300 je kompromis: izmjena se brzo vidi, a resolveri ipak keširaju.
- Bez PTR zapisa i sekundarnog servera: komponente ne traže obrnutu rezoluciju, a sekundarni server bi na istoj VM-i bio samo prividna redundantnost.
- `proj.lab` je kratko i čitljivo, a server je autoritativan i ne delegira se iz javnog DNS-a, pa se ime razrješava samo kad se upit šalje direktno ovom serveru. `home.arpa` ili `.internal` bi bili formalno rezervisani za privatnu upotrebu.
- Gubi se: jedan BIND je jedna tačka otkaza. nginx razrješava `app.proj.lab` samo pri pokretanju, pa nakon promjene adrese backenda treba restartovati frontend (`docker restart frontend`), inače nginx i dalje šalje zahtjeve na staru adresu.

# DO-9: Upravljanje tajnama

Status: prihvaćeno

## Kontekst
Lozinka baze, TSIG ključ i privatni ključevi nikad ne smiju biti u Gitu u čistom obliku. Šifruju se ansible-vaultom ili se generišu pri pokretanju (AO-9). Podizanje od nule ne smije tražiti ručni korak (AO-2).

## Razmotrene opcije
1. `ansible-vault`: šifrovani `vault.yml` u Gitu, a lozinka vaulta van Gita.
2. Generisanje pri prvom pokretanju: Ansible `lookup('password', …)` u `.secrets/` na hostu, van Gita.
3. Ručno napravljen `.env` van Gita.

## Odluka
Opcija 2. `group_vars/all.yml` definiše `db_password` (24 znaka) i `tsig_secret` (32 znaka) preko `lookup('password', '.secrets/…')`. Ako fajl ne postoji, Ansible ga kreira s nasumičnom vrijednošću, a inače čita postojeću. Lozinka ide u `/opt/proj/.env` (mode 0600, `no_log`), a TSIG ključ u `keys.conf` (0640, vlasnik bind) i u Terraform kroz `TF_VAR_tsig_secret`. SSH ključ je u `~/.ssh` i nikad nije u repozitoriju.

## Obrazloženje i posljedice
- Nema lozinke vaulta koju treba negdje čuvati ili ručno unijeti, pa podizanje od nule nema nijedan ručni korak.
- U Gitu nema čak ni šifrovanih tajni. Nema šta procuriti, a nema ni historije koju bi trebalo čistiti. `.secrets/`, `.env`, `*.tfstate` i `inventory.ini` su u `.gitignore`, a `make test` provjerava da `.secrets/` nikad nije ušao u historiju.
- Svaka instalacija dobija vlastite tajne.
- Gubi se: `.secrets/` je stanje kao tfstate i postoji samo na jednom hostu. Ako se izgubi dok VM postoji, generiše se nova lozinka, ali PostgreSQL zadržava staru (`POSTGRES_PASSWORD` se primjenjuje samo pri inicijalizaciji praznog volumena), pa se backend ne može spojiti. Rješenje je `make destroy && make all` ili `ALTER USER` u bazi. Tajne se ne mogu dijeliti u timu kroz Git, što ansible-vault omogućava.
- TSIG ključ je niz znakova iz `[A-Za-z0-9]`, dužine djeljive sa 4, pa je ispravan base64 kakav očekuju BIND i Terraform. Bolje bi bilo generisati ga alatom `tsig-keygen`.
