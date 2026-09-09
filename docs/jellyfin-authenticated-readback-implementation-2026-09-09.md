# Jellyfin kimlik doğrulamalı geri okuma TDD kanıtı

9 Eylül 2026. Uygulama kaynağı `d198a728aeccf7a37ed95150097f84e7a7299d50`.

## Kullanıcı yolculuğu

Larenor yöneticisi tamamlanmış özel Jellyfin bootstrap işleminden sonra ayrı
uygulamalar arasında anahtar kopyalamadan sunucunun doğrulanmış kimliğini ve
kütüphanelerini görmek ister. Larenor Core bu nedenle yalnız daha önce
kanıtlanmış container ve özel ağ bağlantısında sistem kullanıcısıyla oturum
açar, tek Larenor API anahtarını bulur veya oluşturur, kimliği/kütüphaneleri
geri okur, geçici oturumu kapatır ve sonucu şifreli bootstrap kaydına yazar.

## Resmî API temeli

- Jellyfin `UserController` üzerindeki `POST /Users/AuthenticateByName`,
  istemci ve cihaz kimlikli MediaBrowser başlığıyla bir `AccessToken` üretir:
  [kaynak](https://github.com/jellyfin/jellyfin/blob/cf09de60e4e5844ad181d7ef9019151c54969d44/Jellyfin.Api/Controllers/UserController.cs#L203-L229).
- `ApiKeyController`, yükseltilmiş oturum için `GET /Auth/Keys` ve
  `POST /Auth/Keys?app=...` sözleşmelerini tanımlar:
  [kaynak](https://github.com/jellyfin/jellyfin/blob/cf09de60e4e5844ad181d7ef9019151c54969d44/Jellyfin.Api/Controllers/ApiKeyController.cs#L31-L59).
- Kimlik okuması `GET /System/Info`, kütüphane geri okuması
  `GET /Library/VirtualFolders` üzerinden yapılır:
  [SystemController](https://github.com/jellyfin/jellyfin/blob/cf09de60e4e5844ad181d7ef9019151c54969d44/Jellyfin.Api/Controllers/SystemController.cs#L61-L72),
  [LibraryStructureController](https://github.com/jellyfin/jellyfin/blob/cf09de60e4e5844ad181d7ef9019151c54969d44/Jellyfin.Api/Controllers/LibraryStructureController.cs#L59-L69).
- Geçici bootstrap oturumu `POST /Sessions/Logout` ile iptal edilir:
  [SessionController](https://github.com/jellyfin/jellyfin/blob/cf09de60e4e5844ad181d7ef9019151c54969d44/Jellyfin.Api/Controllers/SessionController.cs#L422-L433).

## RED ve GREEN zinciri

| Davranış | RED | GREEN |
| --- | --- | --- |
| Kapalı authenticated readback protokolü | `7668017`: eksik modül nedeniyle collection RED | `0745d70`: ilk 12 senaryo PASS |
| Türkçe ve Unicode görünen adları | `c790748`: güvenli Unicode ad RED | `61be275`: 13 senaryo PASS |
| İkinci doğrulanmış endpoint ve executor bağı | `1f36ed5`: yeni constructor/readback beklentisi RED | `a681d74`: startup ve readback tek retained authority altında PASS |
| UID IPC ve AES-GCM kalıcı devir | `22bae10`: wire/persistence beklentileri RED | `a681d74`: API anahtarı ile kapalı sistem/kütüphane sonucu şifreli kayda yazıldı |
| Geçici Jellyfin oturumunun iptali | `e95e436`: logout isteği ve hata sonucu RED | `d198a72`: doğrulanmış logout zorunlu, belirsiz temizlik sonucu kapalı hata |

## Test garantileri

| Garanti | Test | Tür | Sonuç |
| --- | --- | --- | --- |
| Mevcut tek aktif Larenor anahtarı yeniden kullanılır; birden fazla veya iptal edilmiş eşleşme reddedilir | `test_jellyfin_authenticated_readback.py` | Unit/protokol | PASS |
| Anahtar yoksa yalnız bir sabit `Larenor Core` anahtarı oluşturulur ve yeniden okunmadan kabul edilmez | aynı dosya | Unit/protokol | PASS |
| Sistem ID'si auth sonucuyla eşleşir; wizard tamamlanmadan başarı üretilmez | aynı dosya | Unit/protokol | PASS |
| Kütüphane adları Unicode olabilir; özel konumlar yalnız `/media/...` managed alanında kabul edilir | aynı dosya | Unit/güvenlik | PASS |
| Session token, API key, bootstrap parolası ve medya yolları public model, hata ve repr çıktısına girmez | readback, IPC ve coordinator testleri | Güvenlik | PASS |
| Geçici auth oturumu başarıdan önce kapatılır; logout belirsizliği başarı sayılmaz | `test_session_cleanup_is_required_after_successful_readback` | Unit/güvenlik | PASS |
| Private sonuç UID doğrulamalı Unix IPC'den taşınır ve AES-GCM ciphertext içinde kalır | `test_media_installation_ipc.py`, `test_media_service_bootstraps.py` | Entegrasyon | PASS |
| Container ID, özel endpoint ve retained daemon yetkisi startup/readback öncesi ve sonrasında tekrar doğrulanır | `test_jellyfin_bootstrap_executor.py` | Entegrasyon | PASS |

## Doğrulama

- İlgili altı paket: **110 PASS**.
- Branch coverage: değişen ve doğrudan bağlı beş modülde toplam **%80**.
- `compileall`, `git diff --check` ve kuyruk doğrulaması temiz.
- Kullanıcının ev ağına, gerçek Jellyfin kurulumuna veya kimlik bilgilerine
  erişilmedi; bütün bağlantılar sentetik, önceden doğrulanmış stream'lerdir.

## Açık kabul sınırları

Bu dilim API anahtarı, sunucu kimliği ve mevcut kütüphaneleri güvenle kalıcı
duruma taşır; otomatik Radarr/Sonarr/qBittorrent/Seerr/Music Assistant
eşleştirmesini henüz tamamlamaz. Yeni kütüphane oluşturma, paylaşılmış medya
mount kabulü ve disposable gerçek Jellyfin 10.11 container kanıtı S06.5'in
kalan kapılarıdır. `installAvailable=false` korunur.
