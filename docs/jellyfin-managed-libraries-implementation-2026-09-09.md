# Jellyfin yönetilen kütüphaneler TDD kanıtı

9 Eylül 2026. Yerel olarak doğrulanan kod checkpoint'i
`33bb2d2b5e43c203b21800622f77efd8acba667e`.

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
| Kalıcı medya arşivi | Native CI `34394429050`: `/media/movies` yokken Jellyfin oluşturmayı kapalı `bootstrap_wiring_create_failed` tanısıyla reddetti | `7ac61db`: journal-bound arşiv hacmi, güvenli sabit dizin hazırlığı ve salt okunur `/media` container bağı |
| Sırasız geri okuma | İlk AMD64 koşusu genel sonuç doğrulamasında düştü; ARM64 aynı mount ve kütüphane zincirini geçti | `33bb2d2`: iki tam geçerli Jellyfin sırasını kabul eden, yanlış/ekstra kaydı reddeden matcher ve ayrı kapalı sonuç tanıları |

## Yerel doğrulama

- Yönetilen kütüphane, hacim planı/günlükleri, bootstrap, container binding ve
  native araç paketlerinde **514 PASS**.
- `bootstrap_wiring_failed` public sözleşmeye eklendi. Native tanı yalnız
  gözlem, oluşturma, ikinci kütüphane, çakışma veya son doğrulama aşamasını
  taşır; ham yanıt, parola, session token veya API key taşımaz.
- `git diff --check` ve Python `compileall` temiz.

## Açık kabul sınırı

Larenor artık sekizinci journal-bound kaynağı olarak tek bir kalıcı medya arşivi
üretir. Sabit helper yalnız önceden doğrulanmış bu hacimde `movies` ve `shows`
dizinlerini UID/GID 1000, mod 0750 ile hazırlar; symlink veya metadata çakışması
durur. Jellyfin aynı hacmi `/media` altında salt okunur bağlar ve hem istenen
mount hem tam container inspect sonucu bu yetkiyi doğrular. Exact PR head
`33bb2d2` için [CI 34398527312](https://github.com/ersingundem/larenor/actions/runs/34398527312)
AMD64 ve ARM64 üzerinde geçti; indirilen iki makbuz merge kaynağı `73fbd0a`
için repo doğrulayıcısıyla yeniden geçti. Radarr, Sonarr, qBittorrent, Seerr ve
Music Assistant'ın bu ortak arşive otomatik eşleştirmesi açık kalır.
`installAvailable=false` korunur.
