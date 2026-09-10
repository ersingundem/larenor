# Sonarr/Radarr private endpoint proof

Exact uygulama commit'i: `8737a1d5a498590267d113cc0ba5efde97d71e56`.

Ortak managed-container builder Sonarr ve Radarr için `/config` ile paylaşılan yazılabilir `/data` hacmini üretir. Endpoint proof yalnız exact journal-bound container, Larenor kontrol ağı, çalışan durum, tek private IPv4 adresi, servis profili ve sabit dahili port eşleştiğinde oluşur: Sonarr 8989, Radarr 7878. Açılış numeric IPv4'e tek bağlantı yapar; DNS, proxy, alternatif hedef ve retry yoktur.

Endpoint/readback ve mevcut Jellyfin/qBittorrent regresyon paketlerinde 97 PASS; security policy, queue, diff ve Gitleaks PASS. Container create/start orkestrasyonu ve iki mimarili native kabul açık olduğundan sayaç değişmedi.
