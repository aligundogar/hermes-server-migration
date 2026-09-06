---
name: hermes-server-migration
description: >
  Hermes Agent instance'ını sunucudan sunucuya, memory/cron/session kaybı olmadan
  taşı. state.db sqlite-backup restore, path rewrite sweep (dosya+DB içi), venv
  rebuild, systemd --user adaptasyonu, Telegram reconnect doğrulaması.
  Triggers: "hermes taşı", "hermes migration", "sunucu değişti hermes",
  "state.db malformed", "database disk image is malformed",
  "state database file was replaced underneath", "hermes memory kaybı",
  "cron joblar eski sunucuya bakıyor", "leftover old user paths" — even without exact wording
  hermes sunucu değişimi/göçü bağlamında kullan.
---

# Skill: Hermes Server Migration

Bu skill, Hermes Agent'ı (veya benzer state.db + systemd --user mimarisindeki
herhangi bir agent'ı) A sunucusundan B sunucusuna kayıpsız taşımak için 6 fazlı
protokol uygular. Otomatik versiyonu: `scripts/hermes-migrate.sh` (repo kökünde).

## Ön koşullar

- Her iki makinede SSH erişimi (anahtar bazlı)
- Hedefte python3 ≥3.10 + (node 22 hedefte kurulu olacak)
- Kaynakta servisleri durdurma yetkisi

## Faz 0 — Envanter (taşımaya başlamadan)

```bash
ssh src 'du -sh ~/.hermes; du -sh ~/.hermes/* | sort -rh | head'
ssh src 'systemctl --user list-units "hermes-*" --no-pager'
ssh src 'crontab -l'
```

Eşlik eden dizinleri not et (notes, crawler'lar, memory store'ları, script'ler).
Bunlar hermes'in "çalışma alanı"dır — unutulursa agent yarı-köçük taşınır.

## Faz 1 — Kaynağı durdur (SIRASI ÖNEMLİ)

```bash
ssh src 'systemctl --user stop hermes-dashboard hermes-gateway hermes-gateway-* hermes-acp'
# crontab'i yedekle + devre disi birak (cift calisma engeli)
ssh src 'crontab -l > ~/crontab-backup.txt && printf "# migrated\n" | crontab -'
```

**Neden önce bu?** Canlı sqlite'a rsync = WAL checkpoint'siz bozuk kopya
("database disk image is malformed"). Aynı anda iki gateway = session çekişmesi.

## Faz 2 — state.db TEMİZ kopya (raw copy YASAK)

```bash
ssh src 'python3 - <<PY
import sqlite3
src = sqlite3.connect("/home/USER/.hermes/state.db")
out = sqlite3.connect("/tmp/state-clean.db")
src.backup(out)          # <- raw cp DEGIL
out.close(); src.close()
print(sqlite3.connect("/tmp/state-clean.db").execute("PRAGMA integrity_check").fetchone())
PY'
```

Aynısı `profiles/*/state.db` için de tekrarla. `integrity: ok` görene kadar devam etme.

## Faz 3 — Aktarım

- rsync `~/.hermes/` — **`--exclude hermes-agent/venv`** (absolute path'li, taşınmaz)
- rsync eşlik eden dizinler
- Doğrudan SSH yoksa: hedefin authorized_keys'ine kaynak için geçici key ekle,
  sync bitince kalabilir (fleet içi kullanışlı)

## Faz 4 — Path rewrite sweep (EN ÇOK ATLANAN FAZ)

Eski home `/home/ESKI` → yeni `/home/YENI`:

1. **Text dosyalar:** configs, skills, scripts, notes, cron/jobs.json
   (atla: sessions/, logs/, backups/, cache/, *.pyc, venv — tarihsel/zararsız)
2. **state.db İÇERİĞİ:** her tablonun her text kolonunda SQL replace
   (cron prompt'ları, memory, system_prompts, gateway_routing, async_delegations)
3. **Yardımcı dizinler:** scripts/, crawler'lar, FreshRSS config'leri

```python
# DB icin tarama sablonu (her tablo+kolon icin):
cur = con.execute(f'UPDATE {t} SET "{c}" = replace("{c}", "/home/ESKI", "/home/YENI") WHERE "{c}" LIKE "%/home/ESKI%"')
```

## Faz 5 — Aktivasyon

```bash
cd ~/.hermes/hermes-agent && python3 -m venv venv && venv/bin/pip install -e .
# systemd unitleri: sed eski→yeni (path + --host bayrağı)
systemctl --user daemon-reload
sudo loginctl enable-linger $USER     # logout'ta servisler ölmesin
systemctl --user enable --now hermes-dashboard hermes-gateway hermes-gateway-*
```

## Faz 6 — Doğrulama

- `systemctl --user is-active` → tüm hermes-*: active
- `curl 127.0.0.1:9119` → 200/302
- `PRAGMA integrity_check` → ok
- `journalctl --user -u hermes-gateway | grep "Connected to Telegram"` → bot başına 1
- `grep -rc ESKI_HOME` aktif dosyalarda → 0

## Bilinen özel durumlar

- **"state database file was replaced underneath this process"**: DB'yi çalışan
  gateway altında değiştirdin. Yazılamayan mesajlar `sessions/*.jsonl` +
  `pending_messages/pending-*.json`'a düşmüştür — kaybolmaz ama restart şart.
- **"Invalid Host header"** (dashboard): `dashboard.public_url` config'ine public
  hostname yaz (örn. `https://hermes.internal.example.net`) VEYA 0.0.0.0 bind.
- **OpenStack Security Group**: Port dinliyor + local curl çalışıyor + dışarıdan
  timeout = guest firewall DEĞİL, Neutron SG. API'den ingress rule ekle.
- **Prompt-injection guard false positive**: Agent'ın kendi kişilik/persona
  dosyalarındaki güvenlik terimleri (C2, pentest...) threat_patterns imzalarına
  çarpabilir — kod değiştirme, kullanıcı onayıyla geç.
- **Kaynak sunucu eski config'e geri dönerse**: source servisleri disabled
  yapmadıysan boot'ta yeniden başlar ve session çakıştırır:
  `systemctl --user disable hermes-*`

## Yaygın hatalar (sıralı kurtarma)

1. DB bozuk tespit edildi → source hâlâ kapalıysa Faz 2'yi tekrarla, hedef
   servisleri durdur, DB'yi yeniden koy, restart.
2. Cron job "script not found" → jobs.json prompt'ları DB/dosya sweep'ten
   geçirildi mi? Script gerçekten hiç var olmadıysa prompt'u çalışan eşdeğer
   komutla değiştir.
3. Model/provider hataları → provider key'leri de taşıdın mı? (auth.json, .env)
