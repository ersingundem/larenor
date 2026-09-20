# S06.6 doğrulanmış sonuç ve kurtarma durumu

Bu dilim, kalıcı medya işlerini yeniden çalıştırmadan en son sonucu tek bir
salt okunur Server görünümünde birleştirir. `GET
/api/v1/admin/media/recovery-status` yalnız güncel ve hazır yönetici oturumuna
açıktır. qBittorrent, Sonarr, Radarr, Jellyfin, Seerr ve Music Assistant için
en son kalıcı kaydı gösterir; şifreli payload'ı, kimlik bilgisini, API
anahtarını veya worker ayrıntısını döndürmez.

Tam üç yazılım kabul ölçütü vardır:

1. Container create/start makbuzu servis doğrulaması sayılmaz. Yanıt
   `containerState` ve `serviceState` alanlarını ayrı üretir; yalnız kalıcı
   authenticated readback içeren iş `verified` olur.
2. Restart, iptal ve belirsiz etki kayıtları silmez veya otomatik tekrar
   çalıştırmaz. Okuma yan etkisiz ve idempotenttir; belirsiz sonuç
   `needs_attention` ile `review` eylemine kapanır.
3. İş yetkisi kaybolursa worker etkisi başlamadan kapanır. Eski oturum sonucu
   okuyamaz; yeni yetkili yönetici yalnız sınırlı, secret-free sonuç modelini
   görür.

Yerel TDD paketi bu üç ölçütü gerçek Core veritabanı ve HTTP yönlendirmesiyle
kanıtlar. S06.6 henüz tamamlanmış sayılmaz: required CI ve bağımsız inceleme
kanıtı bu exact kaynak için oluşmadan kuyruk sayacı artmaz. amd64/arm64 gerçek
bileşen kabulü de CI kapısında açık kalır. Ev kurulumu ve fiziksel alıcı
kabulü bu yazılım diliminin kapsamı değildir.

## Bağımsız kabul denetimi

| Kabul ölçütü | Ürün kanıtı | Test kanıtı | Sonuç |
| --- | --- | --- | --- |
| Create/start ve verified ayrımı | `MediaRecoveryStatusManagement._terminal`, `_installation_result`, `_qbittorrent` ve `_arr`; model `containerState` ile `serviceState` tutarlılığını ayrı doğrular | `test_container_receipt_is_distinct_from_verified_music_assistant_result` kalıcı MA readback silinince sonucu yeniden `unverified` yapar; `test_projection_covers_all_six_managed_services_from_durable_readbacks` altı servis kimliğini sınar; `test_failed_bootstrap_cannot_reuse_stale_authenticated_readback` başarısız işte eski readback'in verified sızdırmasını önler | Yerel PASS |
| Restart, iptal, hata ve no-auto-retry | Yanıt `automaticRetry=false` sabitidir; okuma yalnız mevcut şifreli kayıtları doğrulayıp projekte eder, worker çağırmaz veya satır değiştirmez | `test_uncertain_cancellation_is_retained_idempotently_across_restart` belirsiz iptali iki restart okumasında aynı tutar, satır sayısını korur ve `review` dışında eylem üretmez | Yerel PASS |
| Authority loss ve secret-free sınır | Route `require_admin` ve güncel session kontrolü kullanır; cevap modeli yalnız sabit kimlik/durum/eylem alanlarını kabul eder | `test_authority_loss_has_no_worker_effect_and_result_stays_secret_free` worker çağrısının sıfır kaldığını, eski tokenın 401 aldığını ve yeni yönetici yanıtında sır alanı bulunmadığını doğrular | Yerel PASS |

Server endpoint'i OpenAPI üzerinden Admin Client tarafından tüketilebilir,
fakat tablet yüzeyinin eklenmesi S07.4'ün “tek kurulum durumu ve ayarlar”
kabulüne aittir. S06.6'ya ikinci bir Client ekranı eklemek bu bağımlılık
sınırını tekrarlar. Birleşik geçmiş de burada yeni depoya kopyalanmaz: mevcut
servis bazlı bounded list API'leri tam kalıcı geçmişi korur; bu görünüm yalnız
en son kurtarma kararını altı serviste ortaklaştırır.

Installation projeksiyonu yalnız `jellyfin`, `seerr` ve `music_assistant`
kimliklerini kabul eder. Model ileride genişletilip bu görünüm aynı anda
güncellenmezse `test_unknown_future_installation_service_fails_closed` kapalı
503 sonucunu sabitler; bilinmeyen servis sessizce atlanmaz.
