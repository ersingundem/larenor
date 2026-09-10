# Sonarr/Radarr yapılandırılmış container zinciri

Exact uygulama commit'leri:

- started-container bootstrap: `4cef4047e8fd6477ae0f548332efcd43e383c4a6`
- config/create/start/readback runtime: `69c749edae08f0c825eb233ddfd2cefb97f4bf27`
- private Unix IPC: `68f9a63dec1d656d4762a9697880de2d720f72a4`
- kalıcı Core sonucu: `db6caca116959391bc407c169bc22cdcf55d7bb7`
- okunabilirlik ve deadline öncesi stream sahipliği:
  `1a3fcfc3f8872aa33df0ea7a4af38e4063468e90`
- Sonarr/Radarr/qBittorrent reconcile servis yönlendirmesi:
  `71faccbc54d60fa135abb0d6b388a7d9c7483fa0`

Larenor, her servis için sahipli config'i doğruladıktan sonra exact packaged plan ile container create/start adımlarını yürütür. Fresh journal-bound container ve private kontrol ağı tekrar kanıtlanır; yalnız numeric Sonarr 8989 veya Radarr 7878 endpoint'i açılır. `X-Api-Key` authenticated system/status yanıtında pinned servis adı ve sürümü doğrulanır. Sonuç Core'a config, container ve servis durumlarını birlikte taşıyan typed makbuz olarak döner.

Yetki her dış etki ve sonuç kaydından önce yeniden sınanır. Çapraz servis makbuzu, endpoint drift'i, belirsiz worker sonucu veya kesinti otomatik tekrar edilmez ve secret-free hata durumuna kapanır.

Son sertleştirme sonrasında ilgili 13 pakette **301 PASS / 1 mevcut macOS
skip**; Ruff import/temel hata denetimi, compileall, security policy, queue
validation, diff ve Gitleaks PASS. Deadline readback başlamadan tükenirse açılmış
özel stream artık kapatılıyor ve bu sahiplik gerilemesi ayrı testle korunuyor.
Arr reconcile yolu seçili Sonarr/Radarr servisini koruyor; qBittorrent reconcile
da kendi backend'ine geri taşındı ve üç servis için çapraz yönlendirme testleri
eklendi.
Gerçek iki mimarili container kabulü tamamlanana kadar
`installAvailable=false` ve sayaç değişmez.
