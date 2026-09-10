# Sonarr/Radarr iki mimarili native kabul kapısı

Exact uygulama commit'i: `6cc334db10b51b6abca7974dc88e749adce84719`.

Yeni opt-in GitHub iş akışı Sonarr ve Radarr'ı ayrı ayrı gerçek
`linux/amd64` ve `linux/arm64` runner'larında çalıştırır. Her matris işi yalnız
kendisine ait ephemeral Docker daemon, cgroup, mount namespace, socket ve boş
Docker istemci yapılandırması kullanır. Dış Docker socket'i, proxy, emülasyon,
secret veya serbest hedef girdisi kabul edilmez.

Koşu katalogda digest ile sabitlenmiş servis imajını ve helper imajını hazırlar;
appdata ile ortak medya hacmini doğrular; Server tarafından üretilen API
anahtarıyla config/create/start zincirini yürütür. Exact private endpoint'ten
authenticated system/status sonucu okunur, container yeniden başlatılır ve aynı
servis adı ile sürüm ikinci kez doğrulanır. Public makbuz yalnız kaynak commit'i,
platform, servis, imaj/helper digest'leri ve doğrulanmış durumları taşır.

Yerel TDD ve ortak karakterizasyon regresyonunda **239 PASS**; Ruff, compileall,
security policy, queue validation, diff ve Gitleaks PASS. Bu belge gerçek native
koşunun geçtiğini iddia etmez. Dört GitHub matris makbuzu exact PR head üzerinde
başarılı olup tekrar doğrulanana kadar `installAvailable=false` ve sayaçlar
değişmez.
