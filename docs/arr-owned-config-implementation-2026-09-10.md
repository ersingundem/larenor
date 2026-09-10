# S06.5 — Sonarr/Radarr sahipli yapılandırma sözleşmesi

Bu dilim, Larenor'un yönettiği **yeni** Sonarr `4.0.19.2979` ve Radarr
`6.3.0.10514` örnekleri için ilk `config.xml` dosyasını saf ve kapalı bir
üreticiyle hazırlar. Var olan veya kullanıcı tarafından yapılandırılmış bir
örneği sahiplenmez; dosya sistemi, Docker ya da ağ etkisi oluşturmaz.

## Doğrulanan upstream davranışı

- Her iki ürünün `ConfigFileProvider` uygulaması API anahtarını tireleri
  kaldırılmış bir GUID olarak üretir. Larenor aynı tel biçimini 16 güvenli rastgele
  byte'ın 32 küçük harfli hex gösterimiyle üretir:
  [Sonarr kaynağı](https://github.com/Sonarr/Sonarr/blob/v4.0.19.2979/src/NzbDrone.Core/Configuration/ConfigFileProvider.cs),
  [Radarr kaynağı](https://github.com/Radarr/Radarr/blob/v6.3.0.10514/src/NzbDrone.Core/Configuration/ConfigFileProvider.cs).
- Upstream entegrasyon fixture'ları `ApiKey`, `AuthenticationMethod`,
  `AuthenticationRequired` ve `Port` değerlerini başlangıçtan önce aynı dosyaya
  yazar. Larenor bunlara listener, TLS, browser, telemetri, otomatik güncelleme,
  log seviyesi ve örnek adı için sabit allowlist ekler:
  [Sonarr fixture](https://github.com/Sonarr/Sonarr/blob/v4.0.19.2979/src/NzbDrone.Test.Common/NzbDroneRunner.cs),
  [Radarr fixture](https://github.com/Radarr/Radarr/blob/v6.3.0.10514/src/NzbDrone.Test.Common/NzbDroneRunner.cs).
- API kimliği `X-Api-Key`, sorgu alanı veya Bearer taşıyıcısından okunabilir;
  ilerideki Larenor adaptörü yalnız header kullanacak ve anahtarı Client'a
  vermeyecek:
  [Sonarr doğrulayıcı](https://github.com/Sonarr/Sonarr/blob/v4.0.19.2979/src/Sonarr.Http/Authentication/ApiKeyAuthenticationHandler.cs),
  [Radarr doğrulayıcı](https://github.com/Radarr/Radarr/blob/v6.3.0.10514/src/Radarr.Http/Authentication/ApiKeyAuthenticationHandler.cs).

## Uygulanan kapalı sınır

`arr_owned_config.py` yalnız `sonarr` ve `radarr` kimliklerini kabul eder.
Portlar sırasıyla `8989` ve `7878`, örnek adları `Larenor Sonarr` ve
`Larenor Radarr` olarak sabittir. Üretilen dosyada tarayıcı açma, telemetri ve
upstream otomatik güncelleme kapalıdır; güncellemeyi Larenor'un doğrulanabilir
bileşen yaşam döngüsü yönetecektir.

Geri doğrulama, XML'i esnek biçimde yorumlamaz. Beklenen baytları aynı girdiden
yeniden üretip sabit zamanlı karşılaştırır. Böylece ek element, farklı port,
değişen güvenlik ilkesi, başka servis dosyası, farklı API anahtarı, DTD/entity
ve boyut/type sapması kabul edilmez. Yapılandırma ve anahtar nesne `repr` çıktısına
girmez.

## Kanıt ve açık iş

- 36 yeni test; anahtar üretimi, iki servis fixture'ı, exact byte geri okuması,
  yanlış servis/anahtar, sapma, aktif XML ve secret-free hata davranışı.
- Katalog ve medya stack testleriyle birlikte **218 PASS**.
- `compileall`, güvenlik politikası ve `git diff --check` PASS.

Bu dilim yapılandırmayı diske yazmaz ve container başlatmaz. Sıradaki dilim,
journal ile kanıtlanmış Sonarr/Radarr appdata hacmine aynı ağsız, salt okunur
helper kalıbıyla atomik ve no-overwrite yazma etkisini bağlayacak; ardından gerçek
iki mimarili container başlangıcı ve authenticated `/api/v3/system/status`
geri okuması yapılacaktır. qBittorrent download-client ve kök klasör kayıtları
bu native kabulden sonra eklenecektir. S06.5 ve `installAvailable=false` açık
kalır.
