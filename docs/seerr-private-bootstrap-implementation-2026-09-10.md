# S06.5 — Seerr private bootstrap başlangıcı

Bu dilim, Larenor'un yönettiği yeni Seerr 3.4.1 container'ına ilk yönetici
kimliğini kapalı ağdan vermek için gereken iki güvenlik sınırını kurar. Seerr
henüz `installable:true` değildir; Sonarr/Radarr kaydı, kütüphane eşleştirmesi,
initialize geri okuması, worker IPC ve iki mimarili gerçek container kabulü
sonraki dilimlerdir.

## Kaynak ve kullanıcı yolculuğu

Yolculuk mevcut S06.5 planından türetildi: Larenor yöneticisi medya yığınını
kurduğunda Seerr, Jellyfin'in Server tarafından üretilen sistem hesabıyla ilk
yöneticisini oluşturmalı; kullanıcı API anahtarı veya servis adresi kopyalamamalı
ve mevcut/yabancı bir Seerr kurulumu değiştirilmemelidir.

Uygulama, sürüme sabitlenmiş upstream sözleşmelere dayanır:

- [Seerr v3.4.1 Jellyfin giriş rotası](https://github.com/seerr-team/seerr/blob/v3.4.1/server/routes/auth.ts)
- [Seerr v3.4.1 ayar rotaları](https://github.com/seerr-team/seerr/blob/v3.4.1/server/routes/settings/index.ts)
- [Seerr v3.4.1 OpenAPI sözleşmesi](https://github.com/seerr-team/seerr/blob/v3.4.1/seerr-api.yml)
- [Seerr v3.4.1 oturum ayarları](https://github.com/seerr-team/seerr/blob/v3.4.1/server/index.ts)

## TDD kanıtı

| Aşama | Commit | Komut ve sonuç |
| --- | --- | --- |
| RED — ilk yönetici | `0ffef42` | `pytest -q server/tests/test_seerr_initial_admin.py` koleksiyonda beklenen `ModuleNotFoundError`; production modülü henüz yoktu. |
| GREEN — ilk yönetici | `f45ad03` | Aynı hedefte **24 PASS**. Servis probe ve katalog regresyonlarıyla birleşik koşum **236 PASS**. |
| RED — private endpoint | `1cca084` | `pytest -q server/tests/test_seerr_endpoint.py` koleksiyonda beklenen `ModuleNotFoundError`; endpoint modülü henüz yoktu. |
| GREEN — private endpoint | `5dc00db` | Endpoint, container binding, resource proof, Arr ve Jellyfin endpoint paketleri birlikte **99 PASS**. |
| RED — Jellyfin hedefi | `23e79b5` | Testler yalnız plandan türetilen `larenor-<installationId>` adını kabul etmeyi istedi; eski adaptör parametreyi desteklemedi. |
| GREEN — Jellyfin hedefi | `4c2db90` | **24 ilk-yönetici** ve **84 Seerr/binding/resource testi** PASS; serbest alias/IP girdisi reddediliyor. |

`pytest-cov` bu sabit yerel test ortamında kurulu olmadığı için yeni modüller
için yüzdelik kapsam üretilmedi. Tam Server koleksiyonu ve GitHub CI, PR
kapısında ayrıca çalıştırılır.

## Doğrulanan davranışlar

| # | Garanti | Test | Tür | Sonuç |
| --- | --- | --- | --- | --- |
| 1 | Yalnız `initialized:false` ve `applicationTitle:Seerr` gözlemi sır aktarımına izin verir. | `test_only_exact_fresh_seerr_instance_can_receive_credentials` | güvenlik/bütünleşme | PASS |
| 2 | Jellyfin sistem hesabı yalnız plandan türetilen `larenor-<installationId>:8096`, TLS kapalı ve Jellyfin türüyle gönderilir. | `test_creates_initial_admin_reads_key_and_destroys_session` | protokol | PASS |
| 3 | Dönen kullanıcı `id=1`, admin biti, Jellyfin kullanıcı türü ve beklenen adla eşleşir. | `test_auth_response_must_be_exact_larenor_jellyfin_admin` | güvenlik | PASS |
| 4 | Yalnız dar `connect.sid` cookie biçimi kabul edilir; Domain enjeksiyonu reddedilir. | `test_missing_or_untrusted_session_cookie_never_reaches_settings` | güvenlik | PASS |
| 5 | API anahtarı pinned Seerr üretim biçiminde geri okunur ve geçici oturum kapatılır. | `test_generated_api_key_must_match_pinned_seerr_contract` | protokol | PASS |
| 6 | Sır, cookie ve API anahtarı sonuç/hata gösterimine girmez. | ilk-yönetici hata ve başarı testleri | unit | PASS |
| 7 | Container yalnız sahipli `/app/config` hacmi ve portsuz internal control network ile kurulabilir. | `test_seerr_builder_mounts_only_owned_appdata_without_public_port` | bütünleşme | PASS |
| 8 | Endpoint yalnız güncel journal binding, exact container ID, çalışan durum, tek ağ ve RFC1918 IPv4'ten türetilir. | `test_drift_never_opens_socket` | güvenlik | PASS |
| 9 | Numeric `TCP/5055` bağlantısı DNS, redirect ve retry kullanmaz; hata socket'i kapatır. | endpoint bağlantı testleri | unit | PASS |

## Açık kabul sınırı

Bu dilim gerçek Seerr container'ında yazma yapmadı. İlk yönetici adaptörü henüz
worker yürütücüsüne bağlı değildir. Güvenli tam akış için aynı retained daemon
lease'i altında fresh-volume kanıtı, endpoint'in her mutation öncesi yeniden
kanıtlanması, Sonarr/Radarr ve Jellyfin kütüphane eşleştirmesi, initialize
readback, şifreli makbuz, UID-korumalı IPC ve amd64/arm64 native fixture gerekir.
