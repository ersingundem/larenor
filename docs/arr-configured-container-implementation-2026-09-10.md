# Sonarr/Radarr yapılandırılmış container zinciri

Exact uygulama commit'leri:

- started-container bootstrap: `cdeb54cb4a3b0e5b68ab2eac98e5f335cd23157d`
- config/create/start/readback runtime: `40d92c0a3fbe63e56bbf88fe511cd52171049c4a`
- private Unix IPC: `d9772749bee7cd92859f5250cbbc9c871bbccca8`
- kalıcı Core sonucu: `06242ba01c9c6946b4861b79095cb9f1d25a8319`
- okunabilirlik ve deadline öncesi stream sahipliği:
  `6a1270a84c158d57726eb47c6f43163a7a784adb`
- Sonarr/Radarr/qBittorrent reconcile servis yönlendirmesi:
  `8f3bfc99205928354beb6f0bf4eda5430f6de547`
- retained-daemon supervisor, IPC ve kapalı runtime hata projeksiyonu:
  `382c8a92a90d23e599b3bbfc369264e8ac59c75d`

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
