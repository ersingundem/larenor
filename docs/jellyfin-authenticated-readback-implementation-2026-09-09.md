# Jellyfin kimlik doğrulamalı geri okuma TDD kanıtı

9 Eylül 2026. Doğrulanmış uygulama kaynağı
`2c3f591bfe2e5ad9c0465be4ff2ed6ba3628b4fc`.

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
- Jellyfin 10.11.11 `AuthenticationManager`, API anahtarı listesini oturum
  alanlarıyla değil `ApiKey` kaydından seçilmiş sabit alanlarla üretir:
  [kaynak](https://github.com/jellyfin/jellyfin/blob/v10.11.11/Jellyfin.Server.Implementations/Security/AuthenticationManager.cs#L38-L56).
  Aynı sürümün JSON ayarı null alanları wire yanıttan çıkarır:
  [JsonDefaults](https://github.com/jellyfin/jellyfin/blob/v10.11.11/src/Jellyfin.Extensions/Json/JsonDefaults.cs#L25-L31).

## RED ve GREEN zinciri

| Davranış | RED | GREEN |
| --- | --- | --- |
| Kapalı authenticated readback protokolü | `7668017`: eksik modül nedeniyle collection RED | `0745d70`: ilk 12 senaryo PASS |
| Türkçe ve Unicode görünen adları | `c790748`: güvenli Unicode ad RED | `61be275`: 13 senaryo PASS |
| İkinci doğrulanmış endpoint ve executor bağı | `1f36ed5`: yeni constructor/readback beklentisi RED | `a681d74`: startup ve readback tek retained authority altında PASS |
| UID IPC ve AES-GCM kalıcı devir | `22bae10`: wire/persistence beklentileri RED | `a681d74`: API anahtarı ile kapalı sistem/kütüphane sonucu şifreli kayda yazıldı |
| Geçici Jellyfin oturumunun iptali | `e95e436`: logout isteği ve hata sonucu RED | `d198a72`: doğrulanmış logout zorunlu, belirsiz temizlik sonucu kapalı hata |
| Gerçek readback hata sınırı | `a55ae51`: executor adım bilgisini korumadığı için RED | `d1d4f68`: sır içermeyen sabit readback adımları PASS |
| Jellyfin 10.11 API anahtarı wire biçimi | `e8a7f62`: gerçek `ApiKey` projeksiyonu RED | `175db3c`: null alanları atılmış, oturumdan bağımsız API anahtarı biçimi PASS |
| Wizard öncesi/sonrası sağlık kanıtı | `4390241`: tamamlanmış wizard durumu RED | `2c3f591`: gerçek bool durumu korundu; restart dahil native kabul PASS |

## Test garantileri

| Garanti | Test | Tür | Sonuç |
| --- | --- | --- | --- |
| Mevcut tek, doğrulanmış Larenor API anahtarı yeniden kullanılır; birden fazla veya bozuk eşleşme reddedilir | `test_jellyfin_authenticated_readback.py` | Unit/protokol | PASS |
| Anahtar yoksa yalnız bir sabit `Larenor Core` anahtarı oluşturulur ve yeniden okunmadan kabul edilmez | aynı dosya | Unit/protokol | PASS |
| Sistem ID'si auth sonucuyla eşleşir; wizard tamamlanmadan başarı üretilmez | aynı dosya | Unit/protokol | PASS |
| Kütüphane adları Unicode olabilir; özel konumlar yalnız `/media/...` managed alanında kabul edilir | aynı dosya | Unit/güvenlik | PASS |
| Session token, API key, bootstrap parolası ve medya yolları public model, hata ve repr çıktısına girmez | readback, IPC ve coordinator testleri | Güvenlik | PASS |
| Geçici auth oturumu başarıdan önce kapatılır; logout belirsizliği başarı sayılmaz | `test_session_cleanup_is_required_after_successful_readback` | Unit/güvenlik | PASS |
| Private sonuç UID doğrulamalı Unix IPC'den taşınır ve AES-GCM ciphertext içinde kalır | `test_media_installation_ipc.py`, `test_media_service_bootstraps.py` | Entegrasyon | PASS |
| Container ID, özel endpoint ve retained daemon yetkisi startup/readback öncesi ve sonrasında tekrar doğrulanır | `test_jellyfin_bootstrap_executor.py` | Entegrasyon | PASS |

## Doğrulama

- Jellyfin, managed container, bootstrap ve worker ailesinde **655 PASS**.
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

## Disposable native kabul genişletmesi

İlk native bağ `0da1682`, managed native karakterizasyonu yalnız
container create/start kanıtından çıkarıp gerçek Jellyfin 10.11.11 bootstrap ve
authenticated readback zincirine bağladı. Her amd64/arm64 koşusunda rastgele
geçici bir sistem parolası üretilir; wizard tamamlanır, `Larenor Core` API
anahtarı doğrulanır, sunucu kimliği ile boş başlangıç kütüphane listesi okunur
ve auth oturumu kapatılır. Makbuz yalnız `bootstrapAccountConfigured=true`,
`apiKeyVerified=true`, `libraryCount=0` ve `sessionClosed=true` alanlarını
taşır; parola, session token ve API key içermez. Kaynak attestation listesine
endpoint, startup, readback, executor ve private model modülleri de eklendi.

Son kaynakta **655 ilgili test**, security policy, `compileall`, diff ve queue
doğrulaması yerelde geçti. Tam Server paketi kod hatası göstermedi;
yalnız yerel ortamda sağlanmayan zorunlu sabit `apksig 9.1.0` girdisine bağlı
dört kripto fixture kurulamadı. GitHub Actions koşusu
[`34389549143`](https://github.com/ersingundem/larenor/actions/runs/34389549143),
exact head `2c3f591bfe2e5ad9c0465be4ff2ed6ba3628b4fc` için arm64 ve amd64
makbuzlarını doğruladı. Her iki makbuz `bootstrapAccountConfigured=true`,
`apiKeyVerified=true`, `libraryCount=0`, `sessionClosed=true`,
`restartCount=1` ve `installAvailable=false` taşıyor. S06.5, diğer medya
servislerinin otomatik eşleştirmesi açık olduğu için devam ediyor.
