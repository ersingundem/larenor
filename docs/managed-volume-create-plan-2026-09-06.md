# S06.3d — kalıcı volume oluşturma protokolü

6 Eylül 2026. Sonraki dar yazılım dilimi; **uygulama, test veya kurulum
kabulü değildir**. Exact `e7c15ad` temelinde mevcut managed volume önerisi,
özel gözlem journal'ı ve Unix salt okunur taşıma kullanılır.

## İki uygulama checkpoint'i

1. Ayrı `volume_create_journal.py`: gerçek SQLite kalıcılığı, process lock,
   kapalı create-intent durumları ve restart/reconcile. Mevcut gözlem kaydı
   yaratma iznine yükseltilmez; eski journal biçimi değişmez.
2. `volume_effects.py` ve `volume_preparation.py`: bu kalıcı intent'i gerçekten
   tüketen özel protokol. Durable begin, taze varlık denetimi, yalnız eksik
   hedefe bir POST ve taze inspect. Yerel sentetik Unix sunucuyla istek
   sırası, sayısı, kesilme ve belirsizlik doğrulanır.

Shared HTTP genişlemesi yalnız sabit `/v1.47/volumes/create` yolu ve kapalı
Name/Driver=local/DriverOpts={}/Labels gövdesidir. İsim, etiket, nonce ve
policy mevcut sabit plandan yeniden türetilir. Serbest Docker JSON, host
yolu, harici driver veya seçenek kabul edilmez. Eski volume reader'ın404
sonucu değiştirilmez; yeni missing probe yalnız tam ve doğrulanmış yanıtı
kendi akışında değerlendirir.

## Durum ve güvenlik sınırı

Tüm işlem boyunca kaynak, revision, nonce, daemon/socket, iptal ve private
yetki kontrolü yenilenir. Kalıcı yazı başarısızsa POST yoktur. Mutating veya
uncertain kaydıyla yeniden açılış yalnız GET/reconcile yapar; ikinci POST,
silme, otomatik sahiplenme veya geri alma yoktur.201 yanıtı yeni kaynağın
oluşturulduğu veya yazılabilir olduğu kanıtı sayılmaz. Taze inspect mevcut
isim/etiket/driver/options doğrulamasından geçmelidir.

Terminal sonuç `observed_requires_bootstrap`, `needs_attention` veya
`uncertain` olabilir; `ready` veya kurulum başarısı değildir. In-process
callback gerçek kullanıcıya verilmiş execution grant olarak sunulmaz.
Bu protokol üretim runtime/API/installer'a bağlanmaz; `installAvailable=false`
korunur. Güncel actor ve dispatcher bağlantısı S06.4'ün ayrı işidir.

## İlk testler ve sonraki kapılar

RED hedefleri: eski observation intent'in reddi; durable-write hatasında
sıfır POST; dispatch öncesi/sonrası crash ve kayıp ACK sonrasında replay
olmaması; yabancı isim/driver/options/nonce; callback reentrancy ve revision
değişimi; iptal/peer değişimi; tek201'in başarı sayılmaması; son inspect'te
drift; bounded framing/deadline; gerçek SQLite restart; Unix olumlu akış.
Image/network/volume-reader testleri uyumluluk kapısıdır.

[Depolama değerlendirmesindeki](managed-volume-storage-assessment-2026-09-06.md)
gerçek amd64/arm64 Engine, UID/yazılabilirlik, başlangıç verisi, NoCopy ve
restart kalıcılığı testleri hâlâ zorunludur. Bootstrap yetkisi, container mount
bağlama, dış medya kütüphanesi, Docker veri alanı kapasitesi ve servis sağlık/
otomatik API bağlantıları ayrıca tamamlanmalıdır. Native host kökü yolu
için supervisor/remap/issuer kanıtı volume gözlemiyle karşılanmış sayılmaz.

Gerçek ev Docker/CasaOS/Proxmox ortamında işlem yapılmaz. Bu plan
S06.3d/S06.3f durumunu veya kabul edilen iş sayısını artırmaz.
