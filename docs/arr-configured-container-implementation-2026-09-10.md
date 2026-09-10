# Sonarr/Radarr yapılandırılmış container zinciri

Exact uygulama commit'leri:

- started-container bootstrap: `e80a0a6864af909fb10226c2d767b76ed072a1f1`
- config/create/start/readback runtime: `338c3705b895e2550f1e9c5497b0b1afcc8ae383`
- private Unix IPC: `298ab6de4ce46168a011e20d6fdfda29afc52129`
- kalıcı Core sonucu: `3ce2b72be17716b51b482670c40bc1ea504c4ea3`
- okunabilirlik ve deadline öncesi stream sahipliği:
  `8c4eb4cc236c1c873f3f8b9ea79d0eed7722efd5`
- Sonarr/Radarr/qBittorrent reconcile servis yönlendirmesi:
  `c5cbf61335dd4fa13adf4e25536369ddc2a4b95e`
- retained-daemon supervisor, IPC ve kapalı runtime hata projeksiyonu:
  `0e473afe4d451cfdf25a2ae2fd2b9b76a7a3c631`

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
