# S06.3 — kaynak hazırlığı uygulama kaydı

5 Eylül 2026. Bu belge [karar notundaki](media-resource-preparation-plan-2026-09-05.md)
altı adımın gerçek kod/test durumunu kaydeder. `installAvailable=false` ve
katalogdaki kapalı kurulum yeteneği korunur. Ev sunucusunda işlem yapılmadı.

## Saf plan: S06.3a

`8ab8006` RED → `0de91a2` GREEN. `resource_models.py` ve `resource_plan.py`,
mevcut stack/katalog/politikaya bağlı 13 öneri türetir: altı imaj cache kaydı,
altı appdata ve bir özel kontrol ağı. Her kimlik Core/ev/hazırlık bağlamına
bağlıdır; gösterim adı kaynak kimliği olmaz. Seçili platform manifest digest'i
ve imaj config digest'i ayrı tutulur. Eski `MediaStackPlan` v1, hash'leri ve
geçmişi değişmez.

Appdata için eski istenen yol ile ileride önerilen sahiplikli yol birlikte
gösterilir; dizin taşınmış veya UID/mount eşlemesi doğrulanmış sayılmaz.
Politika sürümü/digest'i eşitliği politika onayı değildir. Salt plan üretimi
dosya/host/ağ I/O'su veya kurulum yetkisi oluşturmaz. `model_copy` ile gizlenen
ek alanlar ve bool→int normalizasyonu ham alan doğrulamasında reddedilir.

Yerel kanıt: **67 yeni odaklı test**, mevcut katalog/stack ile **249 test**;
iki yeni modülde birleşik satır/dal kapsamı **%95**. Bağımsız kök incelemesi
sözleşme, katalog pinleri, sıfır I/O ve geçmiş v1 sınırını doğruladı. Uzak CI
sonucu henüz bu yeni dilime eklenmedi.

## Kalıcı kaynak makbuzu: S06.3b

`4d38ec4` RED → `9eaf7d1` GREEN. Karar notundaki eski journal'a v2 tablo
migration'ı önerisi daraltıldı: ayrı `resources-v1` özel dizini ve SQLite kaydı
kullanılıyor. Var olan container journal v1'e dokunulmaz. Eksik/bozuk mevcut
kayıt otomatik başlangıç veya yeni kaynak yaratma hakkı sağlamaz.

Niyet → etki başlangıcı → salt okunur uzlaştırma, işlem boyunca tek process/thread
kilidiyle korunur. Makbuzdaki hash yerel bozulma/tutarsızlık kontrolüdür; diski
değiştirebilen operatöre karşı kriptografik saldırı dayanıklılığı iddiası yoktur.
`ready` yalnız güvenilen dahili gözlemcinin geçmiş kaynak makbuzudur; çalışan
servis, güncel erişilebilirlik veya kurulum başarısı değildir.

Yerel kanıt: **92 odaklı test**, mevcut worker/başlatma ve saf planla **216
uyumluluk testi** geçti. 450/450 statement ve 85/86 dal çalıştı. Bağımsız
incelemede geçmişin bütün payload'larını belleğe alma sorunu giderildi:
hedefli kayıt sorgusu ve akış halinde doğrulama kullanılır. Gerçek ayrı process
kilit çakışması, transaction rollback, eksik/değişmiş SQLite şeması, bozuk
makbuz, stale revision, restart ve belirsiz sonuç durumları sınandı.

## İmaj taşıması: S06.3c

`4e3220e` ilk RED, `440bf51` bağımsız inceleme regresyonu RED → `1b76301`
GREEN. `image_resources.py`, yalnız tam kaynak planından yeniden türetilen
katalog imajını kabul eder. Her Unix bağlantısında aynı doğrulanmış socket
üzerinde `/version` kontrolünden sonra sabit v1.47 inspect/pull yolu kullanılır.
TCP, shell, Client registry adresi/kimlik bilgisi, import, prune veya delete yoktur.

Varsayılan çekme sınırları: toplam 900 saniye, veri gelmeyen okuma için
30 saniye, 16 MiB toplam progress çıktısı, 64 KiB satır, 100.000 olay ve
100.000 chunk. Bunlar dahili operatör değerleridir; disk indirme kotası değildir.
Bellekte bütün akış biriktirilmez. İptal okuma sırasında en çok 250 ms aralıkla
kontrol edilir; bağlantı kapatılır, kalmış paylaşılan layer'lar silinmez.

HTTP 200 tek başına yeterli değildir. JSON hata olayı, eksik/kesilmiş akış,
belirsiz HTTP framing ve taşan sınırlar statik hata verir; registry mesajı
ve yapılandırma sırları makbuza/log'a aktarılmaz. Pull dönüşü hâlâ imajın
doğrulandığı anlamına gelmez: sonraki inspect, seçili manifest referansını,
OS/mimariyi ve ayrı config digest'ini denetlemek zorundadır. Cache'te bulamama
yanıtı da son socket kimliği, iptal ve süre denetimini geçer.

Yerel kanıt: **60 geçti, bir gerçek Linux peer testi Mac'te atlandı**;
modül birleşik satır/dal kapsamı **%98**. AMD64 ve ARM64 katalog pinleri,
ARM64 variant, yanlış config, hata/limit, iptal ve Unix HTTP senaryoları
sentetik daemon ile sınandı. Gerçek Linux SO_PEERCRED testi CI için kayıtlıdır.
Bağımsız incelemedeki 404 son-kontrol atlaması iki başarısız regresyonla
yeniden üretildi ve düzeltildi.

Journal ile kayıp yanıt/yeniden başlama bağlantısı ayrıca uygulanıyor.
Bu ilkeller bir production dispatcher'a veya inspection API'sine bağlanmadı.
Daemon image-store kapasitesi ve güncel actor/politika yetkisi ileride gerçek
dispatch öncesi ayrıca kanıtlanacak; appdata kapasitesi bu koşulu karşılamaz.

## Açık kabul kapıları

S06.3d sahiplikli dizinler, S06.3e özel kontrol ağı ve S06.3f gerçek geçici
Linux AMD64/ARM64 Engine kabulü henüz tamamlanmadı. Ardından dar kurulum,
özel bootstrap ve otomatik medya bağlantıları gelir. Container mount koruması,
media inspection salt okunur yetkisi ve gerçek evde manuel kurulum sınırı
değişmedi. Sonuçlar [kalıcı kuyrukta](EXECUTION_QUEUE.md) ayrı kapanır.
