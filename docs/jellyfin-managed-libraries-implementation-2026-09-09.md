# Jellyfin yönetilen kütüphaneler TDD kanıtı

9 Eylül 2026. Yerel olarak doğrulanan kod checkpoint'i
`a0d14209286b9be1c023e10dd18309d8cf298179`.

## Teslim edilen davranış

Larenor bootstrap, kimliği ve API anahtarı doğrulanmış Jellyfin 10.11.11
oturumundan sonra üçüncü kez aynı journal/container/private-network yetkisini
kanıtlar. Sabit `Larenor Movies` ve `Larenor Shows` kütüphanelerini sırasıyla
`/media/movies` ve `/media/shows` konumlarında idempotent biçimde oluşturur,
sonucu yeniden okur ve ancak tam eşleşme varsa private readback'e geçirir.

Public isteklerde kütüphane adı, yolu, Jellyfin adresi, token, proxy veya retry
alanı yoktur. İlgisiz mevcut kütüphaneler korunur. Aynı adı, yolu veya türü
çakışan kayıtlar değiştirilmez ve silinmez; işlem `jellyfin_library_conflict`
ile insan incelemesine ayrılır. Kısmi oluşturma tekrar denenmez.

## RED ve GREEN zinciri

| Davranış | RED | GREEN |
| --- | --- | --- |
| Sabit ve idempotent iki kütüphane sözleşmesi | `1f998d3`: modül yok, collection RED | `a62b904`: oluşturma, çakışma, tekrar ve kapalı giriş testleri PASS |
| Bootstrap yürütücüsü bağı | `33e6bf5`: eski constructor yeni bağımlılığı kabul etmedi | `a0d1420`: üçüncü doğrulanmış endpoint, IPC/runtime ve native receipt sözleşmesi PASS |

## Yerel doğrulama

- Yönetilen kütüphane, bootstrap, IPC/runtime ve native araç paketlerinde
  **306 PASS**.
- `bootstrap_wiring_failed` public sözleşmeye eklendi. Native tanı yalnız
  gözlem, oluşturma, ikinci kütüphane, çakışma veya son doğrulama aşamasını
  taşır; ham yanıt, parola, session token veya API key taşımaz.
- `git diff --check` ve Python `compileall` temiz.

## Açık kabul sınırı

Mevcut S06.4 yönetilen Jellyfin container binding'i yalnız `/config` ve
`/cache` volume'larını bağlar. Katalogdaki onaylı medya kökü `/media` için
salt okunur tasarlanmıştır fakat kurulum worker'ının mount sözleşmesine henüz
alınmamıştır. Bu nedenle gerçek iki mimarili Jellyfin koşusu geçmeden bu dilim
kabul edilmiş sayılmaz. Native sonuç, Jellyfin'in eksik medya yolu davranışını
kapalı aşama koduyla gösterecek; sonraki uygulama onaylı medya kökü kimliğini ve
mount yetkisini ayrı kanıtlayacaktır. Radarr, Sonarr, qBittorrent, Seerr ve Music
Assistant otomatik eşleştirmesi de açık kalır. `installAvailable=false` korunur.
