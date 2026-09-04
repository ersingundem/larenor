# Uygulama incelemesi — 4 Eylül 2026

Bu çalışma, mevcut Flutter uygulamasındaki yarım kalan kullanıcı akışlarını ve
Apple Home / Netflix benzeri arayüz hedefini ilerletir. Aşağıdaki değişiklikler
uygulandı; projenin olası bütün özelliklerinin tamamlandığı anlamına gelmez.

## Tamamlanan çalışma

- **Ana ekran:** Apple Home esintili açık/koyu arka plan, aksesuar kartları,
  geniş tablette oda kenar çubuğu, dar ekranda oda seçici ve ev özeti eklendi.
  Aktif ışıklar ve erişilemeyen cihazlar daha görünür. Kullanıcının oluşturduğu
  odalar, sıralama, seçilen cihazlar ve favoriler korunuyor. Home Assistant
  odaları isteğe bağlı içe aktarılıyor; sonraki sunucu değişiklikleri yerel
  düzeni otomatik değiştirmiyor. Hızlı düzenlemelerin kayıt sırası korundu.
- **Home Assistant kapsamı:** Sunucunun sunduğu tüm eylemler dinamik katalogdan
  okunuyor; seçicili formlar, hedef seçimi, zorunlu alan/tür doğrulama ve servis
  yanıtı görüntüleme eklendi. Klima hedef/modları, perde konumu, kilit açma onayı,
  fan hızı, sayı/seçim yardımcıları ve medya kontrolleri cihaz ayrıntısında mevcut.
  İlgili eylem ve cihaz yeteneği bulunmayan kontrol gösterilmiyor. Geliştirici
  araçlarında geçmiş/etkinlik/takvim/şablon/günlük/konfigürasyon denetimi, olay
  dinleme ve REST/WS konsolu var. Genel abonelikler son 50 olayı gösteriyor.
  [Detaylı kapsam ve sınırlar](home-assistant-api-coverage.md).
- **Home Assistant yönetimi:** Alan oluşturma/adlandırma/silme; cihaz adı, alanı
  ve etkinliği; varlık adı, simgesi, alanı, kimliği ve görünürlüğü düzenlenebiliyor.
  Kimlik değişimi yerel oda/favori/gizli cihaz/kart atıflarına taşınıyor.
  Entegrasyon seçenekleri, yeniden yapılandırma, discovery/reauth akışları ve
  otomasyon çoğaltma/çalıştırma tamamlandı. Otomasyon düzenleyicisi JSON tabanlı.
  Native karşılığı olmayan panolar resmi HA arayüzünde, kendi oturumuyla açılıyor.
- **Home Assistant bağlantısı:** İlk HTTP isteği sürerken gelen WebSocket
  olayları korunuyor; yeniden bağlantıdan sonra tam durum listesi alınıyor.
  Eski zaman damgalı yanıtların yeni veriyi ezmesi ve bekleyen komutların
  bağlantı kopunca askıda kalması düzeltildi. Silinen varlıklar da işleniyor;
  heartbeat, komut zaman aşımı ve abonelik iptali yönetiliyor. Yazma işlemleri
  belirsiz zaman aşımında otomatik tekrarlanmıyor.
- **Medya:** Uygulamanın ortak açık/koyu teması, büyük görsel alan, poster sıraları ve film/dizi
  filtreleri geliştirildi. Jellyfin dizileri sezon ve bölüm seçimiyle açılıyor;
  bölümün izleme konumu oynatıcıya ve sunucuya aktarılıyor. Bölüm/dizi kimliği
  eşleştirmesi ve 2.000 öğeyi aşan kütüphanelerin sayfalaması düzeltildi.
  Jellyseerr yokken Sonarr/Radarr araması ve kütüphaneye ekleme kullanılabiliyor.
  Kalite profili/kök klasör eksikleri kullanıcıya gösteriliyor; yinelenen ekleme
  ve istek gönderimleri engelleniyor.
- **Proxmox:** Oturum yenileme, geçerli durumlara göre güç menüleri, container
  klonlaması, uygun depolama seçimi ve küme genelinden boş ID önerisi düzeltildi.
  Yapılandırmada yalnız değişen alanlar gönderiliyor; eşzamanlı düzenleme digest
  kontrolüyle korunuyor. Güç, yedek ve klon görevlerinin sonucu izleniyor.
  İşlemler ekranı ve görev günlüğü eklendi. Konsol, bağlı Proxmox sürümünün
  kendi noVNC/xterm sayfasını oturum çereziyle uygulama içinde açıyor.
- **Keenetic:** Model/sürüm, işlemci/bellek ve çalışma süresi özeti; cihaz araması,
  çevrimiçi filtresi ve IP/MAC/arayüz ayrıntıları eklendi. Oturum çerezleri ve
  HTTP 200 içindeki komut hataları doğru işleniyor. Wi-Fi değişiklikleri
  yönlendiriciye kaydediliyor; işlem bekleme ve hata durumları gösteriliyor.
  Port yönlendirme listesi salt okunur kalıyor.
- **Ortak tasarım:** Dashboard, medya, ayarlar ve yönetim ekranları ortak
  `AppColors`, `AppSurface`, `AppPageScaffold` ve `SettingsSection` yapılarını
  kullanıyor. Zorunlu koyu medya teması kaldırıldı. Ek tanıtım sloganları
  kaldırıldı; Latin slogan tek marka sloganı olarak kaldı.
- **Marka:** “Unus Lar, omnem domum servat.” sloganı aynen korunarak bağlantı,
  ana ekran ve Hakkında bölümüne seçilebilir metin olarak eklendi. Yeni lacivert,
  fildişi ve altın tonlu ev/koruyucu logosu uygulama içinde ve iOS/Android menü
  simgelerinde kullanılıyor. Android uyarlanabilir/tek renkli simgeler yerel
  vektör katmanlarıyla hazırlanıyor. [Üretim notları ve istem](branding/logo-design.md).
- Yeni kullanıcı metinleri İngilizce ve Türkçe kaynaklara eklendi; ilgili API,
  model, kayıt ve ekran davranışları için regresyon testleri yazıldı.

## Doğrulama durumu

Kontroller Flutter 3.47.2 / Dart 3.13.2 ile bu çalışma dizininde yapıldı.
Başlangıçtaki 318 test geçiyordu; değişiklikler mevcut oda düzenleme çalışmaları
korunarak eklendi. GitHub ana dalının başlangıç commit’i `4c74bd8` ile eşleştiği
ve o commit’in CI kontrollerinin başarılı olduğu doğrulandı.

| Kontrol | Durum |
| --- | --- |
| Kod üretimi ve yerelleştirme | `build_runner build` ve `flutter gen-l10n` başarılı |
| Statik analiz | `flutter analyze` temiz; 351 dosyada biçim kontrolü geçti |
| Tüm birim/widget testleri | `flutter test`: 468 test geçti |
| Tablet/telefon ekran görüntüsü incelemesi | 1366×1024 tablet açık/koyu, 390×844 telefon ve 2× yazı boyutu kontrolleri geçti |
| Canlı HA okuma testi | 2026.8.3 üzerinde gerçek Dart REST/WS/admin istemcileriyle geçti; üretimde yazma yapılmadı |
| Gizli anahtar kontrolü | Gitleaks temiz; verilen token depoda bulunmuyor |
| Android debug APK | `flutter build apk --debug` başarılı |

### Çıktılar

- [Açık tablet arayüzü](previews/home-tablet.png)
- [Koyu tablet arayüzü](previews/home-tablet-dark.png)
- [Telefon arayüzü](previews/home-phone.png)
- [Medya arayüzü](previews/media-tablet.png) · [koyu telefon](previews/media-phone-dark.png)
- [Ayarlar arayüzü](previews/settings-tablet.png) · [koyu telefon](previews/settings-phone-dark.png)
- [Araştırma ve sonraki entegrasyon planı](integration-roadmap-2026-09-04.md)
- [Tekrarlanabilir salt okunur denetim aracı](../tool/ha_readonly_audit.dart)
- APK: `build/app/outputs/flutter-apk/app-debug.apk`

Görüntüler gerçek Flutter ekranlarından, sentetik test cihazları/yapımlarıyla
alındı. Medya görüntüsündeki boş posterler görsel bulunamaması durumunu gösterir;
bağlı Jellyfin/Jellyseerr sunucusunda mevcut posterler kullanılır.
Kaynak, testler, görsel önizlemeler, README ve bu rapor birlikte sürümlenir.

## Canlı doğrulama ve sınırlar

- HA 2026.8.3 üzerinde 294 eylem/384 alan/29 yanıtlı eylem, 360 durum,
  94 cihaz/8 alan/668 kayıtlı varlık, 46 entegrasyon/903 kurulum handler'ı ve
  19 panel gerçek istemcilerle okundu. Tek varlıkta 30 dakikalık geçmiş/etkinlik
  sorgusu ve WebSocket aboneliği açma/iptal kontrolü geçti. Takvim entegrasyonu
  bulunmadığından 404 durumu doğrulandı; başarılı takvim sorgusu mock ile sınandı.
- Üretim sunucusunda yalnızca okuma ve abonelik işlemleri yapıldı. Cihaz, alan,
  otomasyon, entegrasyon veya yapılandırma değiştirilmedi. Bütün yazma testleri
  sahte HTTP/WS sunucularıyla yapıldı. Fiziksel eylemlerin yüzde 100 sınandığı
  ya da bütün Home Assistant panellerinin native olarak yeniden yazıldığı iddia
  edilmiyor. Gerçek Android tablet, medya oynatma, Proxmox konsolu ve Keenetic
  model/firmware kabul kontrolleri ayrıca yapılmalı.
- Netflix benzeri ifade arayüzü anlatır. Netflix hesabı, kataloğu veya doğrudan
  Netflix oynatması uygulanmadı; medya oynatma Jellyfin üzerinden yapılır.
- Medya eşleştirmesi sunucuların sağladığı TMDB/TVDB/IMDb verisine bağlıdır.
  Eksik/yanlış kimlikler kusursuz birleştirmeyi engelleyebilir. Gerçek cihazın
  codec, ses, altyazı ve transcode davranışı ayrıca doğrulanmalı.
- Proxmox konsolu sunucunun web istemcisine ve cihaz WebView desteğine bağlıdır.
  Gerçek TLS/kendinden imzalı sertifika ve VM/container konsolu testi yapılmadı.
  Görev günlüğü ilk 500 satırla sınırlı; ekranı kapatmak sunucu görevini iptal etmez.
- Keenetic RCI resmi, kararlı bir uygulama API'si değildir. Model/firmware yanıt
  farkları olabilir. Wi-Fi kapatma işlemi mevcut bağlantıyı kesebilir; bağlantı
  kesilirse son durum yönlendiriciden yeniden kontrol edilmelidir.

## Açık yol haritası

OAuth2/PKCE, gerçek Android lock-task kiosk modu, bildirimler, Assist ses uydusu,
çoklu profil/misafir modu, tema editörü ve iOS derleme/imzalama henüz tamamlanmadı.
Proxmox yedekten geri yükleme, taşıma ve snapshot yönetimi ile Keenetic port
kuralı düzenleme mevcut kapsamda yok. Sürüm imzalama, gerçek cihaz kabul testi
ve dağıtım sahibin ortamına göre ayrıca tamamlanmalı.

Yeni entegrasyonlar için [plan belgesi](integration-roadmap-2026-09-04.md) kaynakları,
öncelikleri, kapsamı ve kabul ölçütlerini içerir; planlanan servisler kurulmadı.
