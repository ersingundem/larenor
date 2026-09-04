# Larenor — sonraki geliştirme planı

Tarih: 4 Eylül 2026. Durum: **öneri; aşağıdaki yeni entegrasyonlar henüz uygulanmadı.**

Hedef, günlük ev işlerini az dokunuşla tamamlayan; medya, ev otomasyonu ve ev sunucularını aynı tasarımda buluşturan bir uygulama. “En iyi” için ölçütümüz entegrasyon sayısı değil: işlemin tamamlanması, anlaşılır hata durumu, güvenilir yeniden bağlantı ve gerçek cihazdaki akıcılık.

## Mevcut temel ve kanıt

Bu turda ortak açık/koyu tasarım, tek Latin slogan, yeni logo, dinamik Home Assistant eylemleri, yönetim formları, geliştirici araçları ve tam HA arayüzüne erişim eklendi. [API kapsam matrisi](home-assistant-api-coverage.md) native ekranları, genel API araçlarını ve henüz native olmayan işlevleri ayırır.

Gerçek HA 2026.8.3 sunucusunda yalnızca okumayla 294 eylem, 384 eylem alanı, 360 canlı varlık, 94 cihaz, 8 alan, 668 kayıtlı varlık ve 46 entegrasyon doğrulandı. Eylemler çalıştırılmadı; cihaz/yapılandırma değişikliği yapılmadı. Eylem listesinin okunabilmesi, bütün eylemlerin fiziksel cihazlarda çalıştırıldığı anlamına gelmez.

Adaylara ilişkin sınırlı bileşen kontrolünde MQTT, Energy, Conversation ve Backup yüklüydü. Music Assistant, Frigate, Immich, AdGuard Home, Pi-hole, Paperless ve ESPHome, HA bileşen listesinde yoktu. Bu sonuç, bu servislerin ağda ayrı çalışmadığını kanıtlamaz. Yeni servis kurmak bu planın otomatik bir parçası değildir.

## İncelenen projelerden alınacak dersler

Depoların README, ilgili kaynak dosyaları ve API belgeleri incelendi; başka projelerden uygulama kodu aktarılmadı. GitHub metadata kontrolünde aşağıdaki depolar arşivlenmiş değildi. Tarihler son push bilgisidir; son kararlı sürüm veya kalite puanı değildir.

| Proje | Gözlem ve Larenor için karar | Son push / lisans |
| --- | --- | --- |
| [Home Assistant Android](https://github.com/home-assistant/android) | Android bildirimleri, widget ve konum özellikleri ile HA erişimini birleştiriyor. Larenor’da masaüstü API erişimiyle tablet işletim sistemi entegrasyonunu ayrı kabul testleriyle izleyelim. Assist mikrofonu, dosya seçimi ve bildirim kaydı ayrıca tamamlanmalı. | 2026-09-04 / Apache-2.0 |
| [Mushroom](https://github.com/piitaya/lovelace-mushroom) | Görsel kart düzenleyicisi, ikon/renk seçimi, açık/koyu tema. [Işık kartı](https://github.com/piitaya/lovelace-mushroom/blob/main/src/cards/light-card/light-card.ts) parlaklık ve renk kontrollerini ayırıyor. Sıradaki iş: Larenor’ın genel eylem formunu günlük kullanım için cihaz yeteneklerine göre özel kontrollere dönüştürmek. | 2026-09-01 / Apache-2.0 |
| [Bubble Card](https://github.com/Clooos/Bubble-Card) | Kartlar, açılır paneller ve modüler özelleştirme. [Popup arka planı](https://github.com/Clooos/Bubble-Card/blob/main/src/cards/pop-up/backdrop.js) tema ve etkileşim katmanını yönetiyor. Larenor’da oda içinden ayrılmadan cihaz ayrıntısı ve sahne düzenleme; kaydırma/dokunma testleri öneriyorum. | 2026-09-04 / MIT |
| [Music Assistant](https://github.com/music-assistant/server) | Müzik kaynakları ile hoparlörleri tek sunucuda topluyor. Larenor’ın mevcut film/dizi akışına ayrı bir Müzik bölümü eklemek için güçlü aday. | 2026-09-04 / Apache-2.0 |
| [Frigate](https://github.com/blakeblackshear/frigate) | Kamera olayları ve kayıtları mevcut snapshot ekranından daha ileri bir güvenlik akışı sağlayabilir. | 2026-09-04 / MIT |
| [Immich](https://github.com/immich-app/immich) | Aile albümlerini mevcut bekleme ekranıyla birleştirmek için uygun aday. | 2026-09-04 / AGPL-3.0 |

## Uygulama sırası

### 0. Önce günlük Home Assistant deneyimini derinleştir

**Kapsam:** bu turda eklenen sıcaklık/kapak/fan/kilit/medya kontrollerini renk/renk sıcaklığı, alarm, vakum ve cihazın diğer gelişmiş yetenekleriyle genişletmek; görsel otomasyon düzenleyicisi; enerji tüketim grafikleri; Assist için Android mikrofon/oturum akışı; yetkiye göre yönetim ekranları. Floor/label/category/helper yönetimi için native formlar da burada ele alınmalı. Genel API konsolu ve resmi HA arayüzü bu özelliklerin native olarak bittiği anlamına gelmez.

**Bağımlılık:** API kapsam matrisi, gerçek tablet modeli, ayrı test HA örneği ve deneme cihazları. Mevcut üretim sunucusu salt okunur kalır; bu izin değiştirilmeden orada yazma testi yapılmaz.

**Kabul:** her native kontrol yalnızca sunucunun desteklediği özelliği gösterir; aynı komut iki kez gönderilmez; zaman aşımında otomatik yazma tekrarı yapılmaz; 403/bağlantı kaybı açıklanır; renk, pozisyon ve otomasyon değişiklikleri test sunucusundan geri okunarak doğrulanır. Kullanıcı kayıt/iptal akışını JSON yazmadan tamamlar.

### 1. Music Assistant — ilk yeni entegrasyon

**Değer:** evde çalan müzik, oda/hoparlör seçimi, sıra ve favoriler mevcut medya alanına gelir.

**İlk teslim:** bağlantı ve sunucu yetenekleri; albüm/çalma listesi arama; hoparlör seçme; oynat/duraklat; ses ve sıra ekranı. İkinci teslim: çoklu oda grupları, podcast/sesli kitap devam etme.

**Teknik dayanak:** resmi API, Bearer kimlik doğrulamasıyla `/api` üzerinden komut/argüman zarfı kullanıyor; sıra, medya ve kütüphane komutları belgelenmiş. Hesaplar ve sağlayıcı destekleri Music Assistant sunucusunun yapılandırmasına bağlı. [API belgesi](https://www.music-assistant.io/api/)

**Efor:** büyük. **Kabul:** kuyrukta aynı öğeyi iki kez eklemeden oynatma; başka istemcideki değişimin yenilenmesi; bağlantı kaybından sonra doğru oynatıcı/konum; kaynak yetkisi yokken anlaşılır hata.

### 2. Frigate — kamera olayları ve kayıtlar

**İlk teslim:** kamera listesi, kişi/araç/zaman filtresi, olay görüntüsü ve klip oynatma. Sonraki teslim: canlı görüntü ve kayıt zaman çizelgesi.

**Teknik dayanak:** olaylar için HTTP API var. Kimlik doğrulanan API/UI portu 8971; JWT/Bearer ve viewer rolü destekleniyor. Olay görüntülemek için yönetici yetkisi varsaymayalım. [Olay API’si](https://docs.frigate.video/integrations/api/events-events-get/), [kimlik doğrulama](https://docs.frigate.video/configuration/authentication/)

**Efor:** büyük; canlı akış/codec kısmı ayrı iş paketi. **Kabul:** viewer hesabı, boş kayıt ve silinmiş klip durumları; süre dolan oturum; görünmeyen kamera için erişim hatası; tabletin codec desteğiyle gerçek oynatma testi.

### 3. AdGuard Home + Uptime Kuma — altyapı özeti

**AdGuard ilk teslim:** DNS durum/istatistikleri ve sorgu özeti; ikinci teslimde süreli koruma duraklatma. Keenetic ekranından bu özete geçiş. Resmi [OpenAPI şeması](https://github.com/AdguardTeam/AdGuardHome/blob/master/openapi/openapi.yaml) istemci sözleşmesinin kaynağı olur. Depo lisansı GPL-3.0, son push 2026-09-04.

**Kuma ilk teslim:** servis durumu ve yanıt süresi; Proxmox VM kartlarıyla kullanıcı tarafından eşleştirme. Resmi `/metrics` çıktısı `monitor_status` ve `monitor_response_time` sağlıyor; API anahtarıyla kimlik doğrulama belgelenmiş. İlk aşama izleme okumasıdır; tam monitor CRUD taahhüdü değildir. [Prometheus entegrasyonu](https://github.com/louislam/uptime-kuma/wiki/Prometheus-Integration). Depo lisansı MIT, son push 2026-09-04.

**Efor:** orta. **Kabul:** güncellik zamanı, erişilemiyor/bakım/kapalı ayrımı; eski ölçümün canlıymış gibi gösterilmemesi; Türkçe karakterli monitor adları; servis yeniden başladıktan sonra toparlanma.

### 4. Immich — aile albümleri ve bekleme ekranı

**İlk teslim:** albüm seçici, fotoğraf ızgarası, sadece seçilen albümlerden slayt gösterisi. Yükleme/silme/yüz tanıma yönetimi ilk teslimde yok.

**Teknik dayanak:** resmi OpenAPI şemasında albüm ve asset thumbnail/original yolları ile `x-api-key` kimlik doğrulaması mevcut. İncelenen `main` şeması bir RC sürümü bildirdiğinden geliştirme hedefi kurulu kararlı sunucu sürümüne sabitlenmeli. [OpenAPI](https://github.com/immich-app/immich/blob/main/open-api/immich-openapi-specs.json)

**Efor:** orta. **Kabul:** albüm izni kaldırıldığında fotoğrafların gösterilmemesi; sınırlı önbellek; yön/aspect oranı; gece saatlerinde ekran politikasına uyum.

### 5. Paperless-ngx — ev belgeleri

**İlk teslim:** belge arama, etiket filtreleme ve önizleme; bakım kılavuzu/fatura gibi belgeleri yerel oda/cihaz kayıtlarına bağlama. Sonra kullanıcı başlatmalı tarama/yükleme eklenebilir.

**Teknik dayanak:** dokümante REST API, token kimlik doğrulaması, tam metin arama ve sayfalama mevcut. [Resmi API](https://github.com/paperless-ngx/paperless-ngx/blob/main/docs/api.md). Depo lisansı GPL-3.0, son push 2026-09-04.

**Efor:** orta. **Kabul:** sayfalı sonuç, yetkisiz belge, büyük PDF, boş arama ve bağlantı kaybı; ortak duvar tabletinde belge alanının PIN arkasında kalması.

## Ortak teslim koşulları

Her yeni entegrasyon aynı bağlantı, liste, ayrıntı, yükleniyor/boş/hata düzenini ve uygulama temasını kullanacak. Yeni slogan eklenmeyecek. Kimlik bilgileri güvenli depoda tutulacak; servisler arası aktarılmayacak. Sunucunun sürümü/özellikleri belirlenmeden varsayımsal düğmeler gösterilmeyecek.

Her iş paketi için mock sözleşme testleri, telefon/tablet açık-koyu ekran kontrolleri ve o servise ait gerçek okuma testi gerekir. Yazma kabul testleri ayrı deneme sunucusunda yapılmalı. Gerçek Android tablette 24 saat açık kalma, ağ kesilip gelmesi, arka plana gidip dönme, büyük yazı ve TalkBack kontrolleri yayına çıkış ölçütü olmalı.

**Önerdiğim sıra:** native HA kullanım derinliği → Music Assistant → Frigate → AdGuard/Kuma → Immich → Paperless. Kullanım önceliğine göre Frigate ile Music Assistant yer değiştirebilir. Yeni servis kurulumu veya hesap bağlama bu araştırma sırasında yapılmadı.
