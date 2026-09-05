# Larenor Server içinde bütünleşik medya ve müzik

**5 Eylül 2026 — güncel ürün kararı; uygulama devam ediyor.**

Kullanıcı tek Larenor Server kurar ve Larenor Client hesabıyla yönetir. Music
Assistant, Jellyfin, Seerr ve indirme/kütüphane bileşenleri bu ürünün dahili
bileşenleridir. Yeni kurulumda kullanıcıdan ayrı uygulama kurması, bir Music
Assistant hesabı açması veya servisler arasında URL/API anahtarı taşıması
istenmez. İç süreçlerin ve kalıcı verilerin ayrılması işletim detayıdır;
kullanıcıya ayrı sunucu ürünleri olarak sunulmaz.

Bu hedef henüz tamamlanmadı. Bugün hesap/kasa/güncelleme ve mevcut hizmet
bağlantı yönetimi çalışır; dahili katalog, süreli gereksinim önizlemesi,
salt okunur işçi ve [altı bileşen için kalıcı birleşik hazırlık](media-preparations-implementation-2026-09-05.md)
uygulandı. Kaynak oluşturma ve otomatik servis eşleştirmesi geliştirilecek.
Eski MA-only Docker paketi birleşik ürünü
karşılamaz ve yeni kurulum için hedef yol değildir.

## Client'taki akış

1. Larenor Server'a giriş yap ve ilk parolayı değiştir.
2. Medya/müzik özelliklerini, sunucuda izinli medya konumlarını ve kullanım
   tercihlerini seç. Teknik bileşen listesi yönetici ayrıntısı olarak kalır.
3. Tek kurulum önizlemesinde toplam kaynak, veri erişimi ve ağ gereksinimlerini
   incele. Larenor gerekli bileşenleri ve aralarındaki bağlantıları kurar.
4. Spotify/Apple Music/YouTube Music gibi harici sağlayıcılarda gerekli hesap
   onaylarını Client'taki yetkilendirme akışında tamamla; oynatıcıları seç.
5. İstek, indirme, içe aktarma ve oynatma durumunu aynı medya ekranından izle.
   Sonraki değişiklikler Client'ın kalite, klasör, kaynak ve oynatıcı ayarlarıdır.

Sağlayıcı aboneliği ve hesap sahibinin gerekli onayı otomasyonla atlanmaz.
Client üçüncü taraf sağlayıcı parolasını bir Larenor giriş parolası gibi
saklamaz. Dahili bileşenler için ayrı elle girilen sunucu tokenları gerekmez.

## Server'ın üstleneceği işler

| Alan | Hedef davranış | Bitti sayılma ölçütü |
| --- | --- | --- |
| Bileşen yaşam döngüsü | Sabit sürümlü bileşenleri tek Larenor kurulumuyla başlatma/durdurma, durum ve kontrollü güncelleme | Yeniden başlatma ve kesilen kurulumdan toparlanma testi; mevcut veriyi koruma |
| Dahili kimlik bilgileri | Güçlü yerel anahtar/hesapları üretme, gerekli bileşene özel verme, şifreli Server deposunda tutma | Client/yanıt/log/plan içinde sır bulunmaması; anahtar yenileme ve yetki testleri |
| İndirme ve arşiv | İndirme istemcisi, film/dizi yöneticileri, kategoriler ve ortak dosya konumlarını eşleme | İstek → indirme → içe aktarma yolu; hardlink/yol uyuşmazlığı ve kısmi hata testleri |
| İstek ve oynatma | İstek yöneticisini film/dizi yöneticilerine ve medya kütüphanesine bağlama | Eşleştirilmiş kullanıcı/kütüphane, durum geri okuma ve yinelenen işlem koruması |
| İndeks ve altyazı | Gerektiğinde arama/indeks, altyazı ve müzik arşivi bileşenlerini ortak ayarlardan yapılandırma | Her ek bileşenin sürüm/API/izin ve lisans kontrolü; eksik destek açık görünür |
| Dahili müzik motoru | Music Assistant'ı Larenor tarafından yönetilen bileşen olarak çalıştırma; sağlayıcı/oynatıcı/kuyruk API'lerini Larenor yetkileriyle sunma | Ayrı MA URL/token kurulumu olmadan Client akışı; gerçek HomePod/Cast kabulü |
| Bağlantı denetimi | Her yapılandırma adımından sonra beklenen bağlantıyı geri okuyup sınama | Çalışan süreç ile doğrulanmış entegrasyon ayrı durumlar; gizli kısmi başarı yok |
| Yedek ve geri yükleme | Larenor hesapları, bağlantı sırları, medya tercihleri ve bileşen verilerinin tutarlı yedeği | Yeni test kurulumunda geri yükleme ve bağlantıların yeniden doğrulanması |

İlk sabitlenmiş katalog Jellyfin, Seerr, Sonarr, Radarr, qBittorrent ve Music
Assistant'ı kapsar. Diğer medya bileşenleri mevcut envanter ve upstream desteğine
göre eklenir; katalogda adının bulunması tüm fonksiyonlarının doğrulandığı
anlamına gelmez. Bileşen gereksinim önizlemesi henüz otomatik kurulum değildir.

## Mevcut kurulumları koruma

Mevcut CasaOS/HA/medya uygulamaları bulunursa otomatik sahiplenilmez veya
değiştirilmez. Kullanıcı isterse mevcut hizmet bağlantısını ayrıca ekleyebilir;
bu yol yeni Larenor kurulumunun zorunlu onboarding'i değildir. Kurulum işçisi
yalnızca kendi kayıtlı kaynaklarında çalışır. Aynı isimdeki yabancı konteyner,
port veya veri dizini çakışma olarak gösterilir.

Yeni otomatik bağlantı adımları kalıcı iş günlüğüne bağlanır. İşlemden sonra
cevap kaybolursa durum geri okunur; aynı hesap, kütüphane veya istemci körlemesine
ikinci kez oluşturulmaz. Yetki iptali sonraki yazma adımlarını durdurur; kısmen
oluşan veri başarılı kurulum olarak veya sessizce silinmiş olarak gösterilmez.

## Teslim sırası

1. **S06:** Katalog ve gereksinim sözleşmesi; kalıcı, yetkili kurulum işleri ve
   sınırlı işçi; bütün medya sistemi için tek kurulum önizlemesi.
2. **S07:** Dahili Music Assistant ve medya bileşenlerini ortak pakete alma;
   ilk yapılandırma ve otomatik API bağlantısı adaptörleri.
3. **S08:** Client medya/müzik isteklerini Larenor API'sine taşıma; sağlayıcı
   onayları, kuyruk/oynatıcı ve işlem durumları; mevcut doğrudan yolların geçişi.
4. **S09:** Tek kurulum/güncelleme/yedek akışı, temiz kurulum ve yükseltme CI'ı,
   sonra kullanıcıyla CasaOS/Proxmox ve gerçek tablet/alıcı kabulü.

Takip: [PROGRESS](PROGRESS.md), [Server/Client mimarisi](server-client-architecture-2026-09-05.md).
