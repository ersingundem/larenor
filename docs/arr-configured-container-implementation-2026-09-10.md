# Sonarr/Radarr yapılandırılmış container zinciri

Exact uygulama commit'leri:

- started-container bootstrap: `2d823ba49daf255ff3ca8f7ac0f8eafacf1af790`
- config/create/start/readback runtime: `c1311a65388c9cc5a2ec7acd41ac01e303a2e627`
- private Unix IPC: `8e1032c64c958b2eca7b9ce4da3489c4b6cc07b2`
- kalıcı Core sonucu: `0f5006f695bddfed450019443c57c21d0c750730`
- okunabilirlik ve deadline öncesi stream sahipliği:
  `3331f8dc474ee0f02eee181818292fbc91e7c841`
- Sonarr/Radarr/qBittorrent reconcile servis yönlendirmesi:
  `e5eed11f3e6494bcaf4a44468ebcf0ef031a42b6`
- retained-daemon supervisor, IPC ve kapalı runtime hata projeksiyonu:
  `7d9fb2226eb9fb89451472cb5b0bbac252fe27f1`

Larenor, her servis için sahipli config'i doğruladıktan sonra exact packaged plan ile container create/start adımlarını yürütür. Fresh journal-bound container ve private kontrol ağı tekrar kanıtlanır; yalnız numeric Sonarr 8989 veya Radarr 7878 endpoint'i açılır. `X-Api-Key` authenticated system/status yanıtında pinned servis adı ve sürümü doğrulanır. Sonuç Core'a config, container ve servis durumlarını birlikte taşıyan typed makbuz olarak döner.

Yetki her dış etki ve sonuç kaydından önce yeniden sınanır. Çapraz servis makbuzu, endpoint drift'i, belirsiz worker sonucu veya kesinti otomatik tekrar edilmez ve secret-free hata durumuna kapanır.

Son sertleştirme sonrasında ilgili 13 pakette **313 PASS / 1 mevcut macOS
skip**; Ruff import/temel hata denetimi, compileall, security policy, queue
validation, diff ve Gitleaks PASS. Deadline readback başlamadan tükenirse açılmış
özel stream artık kapatılıyor ve bu sahiplik gerilemesi ayrı testle korunuyor.
Arr reconcile yolu seçili Sonarr/Radarr servisini koruyor; qBittorrent reconcile
da kendi backend'ine geri taşındı ve üç servis için çapraz yönlendirme testleri
eklendi. Installation supervisor artık config/create/start/readback zincirini
aynı retained daemon kanıtı ve native thread üzerinde yürütüyor. Yetki kaybı,
timeout, kaynak sorunu ve geçersiz container/bootstrap sonuçları otomatik retry
edilmeden kapalı, secret-free ve belirsiz etki taşıyan sonuçlara çevriliyor.
Gerçek iki mimarili container kabulü tamamlanana kadar
`installAvailable=false` ve sayaç değişmez.
