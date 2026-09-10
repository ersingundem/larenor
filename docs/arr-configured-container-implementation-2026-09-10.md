# Sonarr/Radarr yapılandırılmış container zinciri

Exact uygulama commit'leri:

- started-container bootstrap: `b7eaf5078ed102b875fe08af2f8ce17d44777fe4`
- config/create/start/readback runtime: `74bb06a61e0fe1424d6250d49ca61a96154b1f65`
- private Unix IPC: `2a09677060965d4f84911f1ab0384504763b35a1`
- kalıcı Core sonucu: `fc83138c3973233b965445d1a0f1a52587b1dc2d`

Larenor, her servis için sahipli config'i doğruladıktan sonra exact packaged plan ile container create/start adımlarını yürütür. Fresh journal-bound container ve private kontrol ağı tekrar kanıtlanır; yalnız numeric Sonarr 8989 veya Radarr 7878 endpoint'i açılır. `X-Api-Key` authenticated system/status yanıtında pinned servis adı ve sürümü doğrulanır. Sonuç Core'a config, container ve servis durumlarını birlikte taşıyan typed makbuz olarak döner.

Yetki her dış etki ve sonuç kaydından önce yeniden sınanır. Çapraz servis makbuzu, endpoint drift'i, belirsiz worker sonucu veya kesinti otomatik tekrar edilmez ve secret-free hata durumuna kapanır.

İlgili runtime, IPC, bootstrap ve kalıcı iş paketlerinde 78 PASS; geniş managed-container/readback regresyonunda 109 PASS. Compileall, security policy, queue validation, diff ve Gitleaks PASS. Gerçek iki mimarili container kabulü tamamlanana kadar `installAvailable=false` ve sayaç değişmez.
