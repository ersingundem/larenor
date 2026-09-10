# S06.5 — Sonarr/Radarr journal-bound yapılandırma etkisi

Bu dilim, exact Sonarr/Radarr `config.xml` binding'ini tek kullanımlık kapalı
helper container'ına ileten worker etkisini ekler. Etki yalnız güncel journal
kaynağı yeniden üretilebildiğinde başlar ve aynı kaynağı sonuçtan sonra tekrar
doğrular.

## Kapalı Docker ve sır sınırı

- Helper image tam SHA-256 kimliği ve platform yalnız `linux/amd64` veya
  `linux/arm64` olabilir. Caller image, komut, volume, hedef yol, container adı,
  ağ ya da Docker gövdesi seçemez.
- Container `1000:1000`, ağ kapalı, salt okunur root filesystem, bütün
  capability'ler düşürülmüş, `no-new-privileges`, 64 MiB bellek ve 32 PID
  sınırıyla çalışır. Yalnız kanıtlanmış appdata volume'ü `/volume` hedefine
  yazılabilir bağlanır.
- Servise göre yalnız `install_sonarr_config` veya `install_radarr_config`
  komutu seçilir. XML ve API key create gövdesine, label'a, komut satırına,
  hataya veya makbuza girmez; bounded Unix Engine stdin ile taşınır.
- Akış create, start, stdin stream, wait ve remove adımlarını izler. Her mutasyon
  öncesinde yetki kapısı yeniden çalışır; timeout, çıktı ve frame sınırları
  sabittir. Redirect, retry veya belirsiz işlemi otomatik temizleme yoktur.
- Yalnız exact canonical JSON helper sonucu, aynı configuration SHA-256 özeti
  ve doğru servise ait durum kabul edilir. Sonarr işi için Radarr durumu gibi
  çapraz servis sonucu başarı olamaz.
- Docker geçersiz container kimliği döndürürse kimlik hiçbir cleanup yolunda
  kullanılmaz. Geçerli kimlikten sonraki stream/wait/cleanup ve kaynak değişimi
  belirsiz etki olarak sınıflanır; özel çıktı hata metnine taşınmaz.

## Kanıt ve açık iş

- Exact kaynak `87449f1724a17e57421d4ccc87fc0cdaf73064d5`.
- **22 etki testi**; binding, helper ve owned-config paketleriyle **160 PASS**.
- Sahte binding, servis sapması, kaynak değişimi, iptal, kapı reddi, malformed
  container sonucu ve bütün lifecycle hata aşamaları sentetik Engine ile kapalı
  olarak doğrulandı.
- `compileall`, güvenlik politikası, kuyruk, diff ve Gitleaks PASS.

Bu dilim kalıcı Core işi veya installation supervisor üzerinden çağrılmaz ve
gerçek Sonarr/Radarr container'ı başlatmaz. Sıradaki adım binding builder ile bu
etkiyi aynı retained-daemon/native-thread yetkisine bağlamak; ardından config
önce olacak şekilde container create/start ve authenticated API readback
zincirini kurmaktır. İki mimarili native kabul tamamlanana kadar S06.5 ve
`installAvailable=false` açık kalır.
