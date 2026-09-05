# Merkezi hizmet bağlantıları

Larenor Client içinde **Ayarlar → Larenor Server → Hizmet bağlantıları**,
Server'daki yönetici hesabının hizmet kayıtlarını yönetir. İlk parola değişimi
ve varsa yerel Ayarlar PIN'i gerekir. Member hesabı bu API'leri kullanamaz.

## Bağlantı kaydı ile çalışan entegrasyonun ayrımı

Bağlantı ekleme/düzenleme, adı, türü, adresi ve açıkça verilen kimlik bilgilerini
Larenor Server'da saklar. Bu işlem yazılım kurmaz veya bir dış servisin ayarlarını
değiştirmez. Mevcut HA/medya/ağ Client bağlantıları otomatik olarak bu kayda
taşınmaz; gerçek kontrol akışlarının Server adaptörlerine geçişi S08 paketidir.

**Bağlantıyı denetle** kısa bir kimlik/sürüm kontrolü yapar. Gerekli hizmetlerde
giriş, dış serviste geçici bir oturum oluşturabilir. Kontrol cihazları açmaz,
medya oynatmaz, indirme başlatmaz veya ağ/VM ayarlarını değiştirmez.

| Gösterilen durum | Anlamı |
| --- | --- |
| Kaydedildi · Denetlenmedi | Yapılandırma var; henüz erişim kanıtı yok |
| Erişilebilir · Kimlik doğrulanmadı | Beklenen servis yanıtı alındı; kimlik bilgilerinin kabul edildiği kanıtlanmadı |
| Kimlik doğrulandı | Desteklenen yetkili kontrol yanıtı doğrulandı; bütün işlemlere yetki veya fiziksel cihaz sonucu anlamına gelmez |
| Erişilemiyor | Ağ, TLS, süre sınırı veya geçici servis hatası |
| Kimlik bilgileri reddedildi | Deneme kimlik/yetki kontrolünü geçemedi |
| Denetim desteklenmiyor | Bu API/kimlik bilgisi biçimi veya yanıt desteklenmiyor; çalışıyor gibi gösterilmez |

Durum kontrol anını gösterir. Bağlantı adresi veya kimlik bilgileri değişince
eski sonuç temizlenir. Kontrol sürerken kayıt değişirse, silinirse veya
yöneticinin yetkisi/oturumu iptal edilirse eski sonuç saklanmaz.

## Desteklenen kontrol yolları

Bu tablo bağlantı kontrolünün kapsamıdır; bütün dış servis API'lerinin veya
otomatik kurulumun tamamlandığı anlamına gelmez. Client alanları seçilen hizmete
göre değişir. Alternatif giriş yöntemleri birlikte gönderilmez.

| Hizmet | Kimlik bilgisi / kontrol |
| --- | --- |
| Home Assistant | Erişim tokenı; salt okunur `/api/config` |
| Sonarr, Radarr | API anahtarı; v3 sistem durumu |
| Lidarr, Readarr, Prowlarr | API anahtarı; v1 sistem durumu |
| Bazarr | API anahtarı; sistem sürümü |
| Seerr | API anahtarıyla mevcut kullanıcı; anahtarsız yalnız herkese açık ayarlar. Bu kontrolde sürüm dönmeyebilir |
| Jellyfin | Kullanıcı tokenı **veya** API anahtarı; sistem bilgisi. İlk kurulum bypass'ı kimlik doğrulaması sayılmaz |
| Immich | API anahtarı **veya** token; yetkili Server about bilgisi. Anahtarsız sürüm yalnız erişim kanıtıdır |
| AdGuard Home | Kullanıcı adı + parola; DNS servis durumu |
| qBittorrent | Kullanıcı adı + parola; sınırlandırılmış SID oturumu ve uygulama sürümü |
| Music Assistant | Uzun ömürlü token; HTTP `info` komutu. Motoru kurmaz, sağlayıcı hesabına giriş yapmaz veya oynatma başlatmaz |
| Keenetic | Kullanıcı adı + parola; Web UI challenge/oturum akışı ve `show version`. KeenDNS Digest/proxy veya etkileşimli MFA bu kontrolün kapsamında değildir |
| Proxmox | Tam `user@realm!tokenid=secret` tokenı **veya** `user@realm` + parola; sürüm bilgisi. Etkileşimli MFA taklit edilmez |
| Frigate, ESPHome | Herkese açık sürüm kontrolü; kayıtlı sırlar gönderilmez, sonuç kimliği doğrulanmış olarak gösterilmez |

Arr ve AdGuard'da girişin kapalı olması veya yerel ağ bypass'ı nedeniyle açık
yanıt alınırsa kayıtlı sır gönderilmez; durum yalnız erişilebilir olarak kalır.
Kimlik bilgisi reddi ile eksik yetki aynı `unauthorized` sınıfındadır; özellikle
kısıtlı API anahtarlarında ilgili okuma iznini kontrol etmek gerekir.

Kullanıcı adı/parola ile giriş gerektiren kontroller dış servisin kendi oturum
süresine tabidir. Tokenlar geçersizse burada saklamak onları yeniden geçerli
hale getirmez. Canlı servis sürümleri ve cihazlar ayrıca kabul testine girer.

## Saklama ve düzenleme

- Kayıtlar Server veritabanında AES-GCM ile şifrelenir; anahtar veri dizininden
  ayrıdır. API yalnız kimlik bilgisi alanlarının adlarını döndürür.
- Düzenleme ekranı kayıtlı sırları geri göstermez. Aynı adreste değerleri
  koruyabilir, açıkça değiştirebilir veya temizleyebilirsin.
- Adres değişince eski sırlar başka bir hedefe otomatik gönderilmez; yeni
  kimlik bilgileri veya açık temizleme gerekir.
- **Bağlantıyı unut**, yalnız Larenor kayıt satırını kaldırır. Dış hizmeti,
  container'ı, medya arşivini veya cihazı kaldırmaz.
- En fazla 128 kayıt vardır. Eşzamanlı değişiklikler revizyonla korunur;
  belirsiz yazma otomatik tekrarlanmaz, önce liste yenilenir.

## API

Tüm yollar `/api/v1` altında ve Server admin yetkisiyle çalışır.

| Yöntem ve yol | Davranış |
| --- | --- |
| `GET /admin/services` | Sırları içermeyen kayıt listesi |
| `POST /admin/services` | `name`, `kind`, `baseUrl`, `credentials` ile kayıt oluşturma |
| `PATCH /admin/services/{id}` | `expectedRevision`, `name`, `baseUrl`; isteğe bağlı açık credential değişimi |
| `DELETE /admin/services/{id}?expectedRevision=N` | Yalnız yerel kayıt unutma |
| `POST /admin/services/{id}/check` | `expectedRevision` ile salt okunur servis kontrolü |

Kontrolün toplam süresi 12 saniye, aynı anda en fazla dört kontrol ve bir kayıt
için tek kontrol sınırı vardır. Meşgul durumda `429` döner. Kontrol yeni bir
yapılandırma revizyonu oluşturmaz. Alan ve hata şemalarının kaynak sözleşmesi
yöneticiye açık `GET /api/v1/openapi.json` çıktısıdır.

HTTP taşıması yalnız sabit kontrol yollarını kullanır; yönlendirme/proxy veya
otomatik tekrar yoktur. DNS yanıtları bağlanmadan önce denetlenir, HTTPS
sertifikası ve sunucu adı doğrulanır, yanıt boyutu sınırlıdır. Yerel ağ hedefleri
desteklenir; bulut metadata, link-local, multicast ve belirsiz adresler reddedilir.
Kendinden imzalı sertifika için doğrulamayı kapatan bir seçenek sunulmaz.

## Test kanıtı ve sınırlar

- [Server CRUD ve şifreli depolama](../server/tests/test_services.py)
- [HTTP, DNS, TLS ve süre/boyut sınırları](../server/tests/test_service_transport.py)
- [Servis yanıt sözleşmeleri](../server/tests/test_service_probes.py)
- [Admin API, yarışlar ve gerçek loopback HTTP akışı](../server/tests/test_service_probe_api.py)
- [Client sözleşmeleri](../test/features/server/server_services_test.dart),
  [ekran ve yaşam döngüsü](../test/features/server/server_services_screen_test.dart)

Bu testler sentetik veriler ve yerel fixture servisleri kullanır; ev sunucularına
bağlanmaz. Güncel test sayıları ve açık cihaz kabul işleri
[ilerleme dosyasında](PROGRESS.md) izlenir. CasaOS/Proxmox kurulumu ve gerçek
HomePod/medya/ev sistemi kabulü kullanıcıyla en son yapılır.
