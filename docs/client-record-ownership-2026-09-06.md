# S08.4 — Mevcut Client kayıtlarının sahipliği

6 Eylül 2026. Envanter ana dal ve yeni kaynaklı düzen diliminin kodundan
çıkarıldı. Bu tablo bütün kayıtların kabul testlerini geçtiği anlamına gelmez.
S08.4, her satırın gerçek erişim sınırı doğrulandığında kapanır; yalnız oda
adlarını kopyalamak yeterli değildir.

| Kayıt / kaynak | Sahiplik | Core davranışı ve kalan kabul |
| --- | --- | --- |
| `dashboard_layout`, DashboardRepository | Eski Direct ev düzeni | Yalnız açık PIN önizlemesi oda adlarını tüketir; entity/alan/web referansları otomatik taşınmaz. Yeni dilimin 93 odaklı testi ve bağımsız incelemesi geçti; birleşik/CI kabulü ayrıca izlenir. |
| `dashboard_layout_core_v1_*` | Core + ev + kullanıcı | Canonical tuple anahtarı, embedded tuple, revision ve kayıt özeti; bozuk kayıtta legacy fallback yok. Backend'de ortak oda registry'siyle henüz eşlenmez. |
| HA CredentialsStore / connectionConfigProvider | Direct ev bağlantısı | URL/token Core'a otomatik bağlanmaz. d8edab5 gerçek provider/store/transport sınırını, eski write/clear callback reddini ve kalıcı yarım-kayıt kurtarmasını ekledi; son 53 test ve inceleme temiz; 8c3b60d CI ve APK 96 kabulü geçti. |
| Sonarr/Radarr/Lidarr/Readarr | Direct medya bağlantısı | 0298c5a kaynak/tuple/PIN/recovery sınırı192 odaklı/547 ilgili testle; ardından7553a3f belirsiz yazı reader/kurtarma düzeltmesi370 ilgili testle geçti. Bağımsız inceleme ve4bc79dc/APK99 kendi CI kabulü tamamlandı. |
| Jellyseerr, Bazarr, Prowlarr | Direct medya bağlantısı | 37bd4c8:151 yeni/241 ilgili;7553a3f belirsiz yazı sonrası reader/boş recovery370 ilgili PASS. Bağımsız inceleme ve4bc79dc/APK99 CI kabulü geçti. |
| qBittorrent | Direct medya bağlantısı | 13d022a:121 odaklı/531 ilgili PASS,%94,1 ilgili kapsam. Cookie/version, sahipli iptal, belirsiz yazı reader retirement ve açık recovery. Bağımsız inceleme ve4bc79dc/APK99 CI kabulü geçti. |
| Jellyfin | Direct medya bağlantısı | 142dc36:98 yeni/297 ilgili PASS; credential tuple ile cihazID ayrı, UDP bind/stop, nativefocus/providerreload ve belirsiz token recovery. Bağımsız inceleme ve4bc79dc/APK99 CI kabulü geçti. |
| Proxmox | Direct altyapı bağlantısı | 48289eb:6 alanlı tuple, açıkTLS, nativefocus/reload/PIN recovery;213 odaklı/665 ilgili PASS,%86,8 ilgili kapsam. Bağımsız inceleme ve4bc79dc/APK99 CI kabulü geçti. |
| Keenetic | Direct ağ bağlantısı | dc87062 bağlantı/store/PIN/kurtarma181 odaklı/1008 ilgili PASS;74e3f44 operasyon202 odaklı/1047 ilgili PASS. Wi-Fi onayı ve cihaz/port okuyucuları kaynak/hesap/route sahibiyle bağlı; bağımsız inceleme temiz. Sonraki yerel birleşimde; yeni CI gerekli. |
| `enabled_services` ve taşıma bayrağı | Direct servis yapılandırması | Core yetenek kataloğu değildir. İlk seed bütün Direct servis sırlarını tarayabilir; Jellyfin device ID de yazabilir. d8edab5 Core'da seed/taşıma/store erişimini ve kaynak değişiminden sonra device ID yazısını durdurur; olumlu Direct davranış ve kayıt hataları test edildi; 8c3b60d CI ve APK 96 kabulü geçti. |
| DoorStationStore / `DoorStation.storageKey` | Direct ev diafonu | HA adresi ve kamera/çağrı/kapı entity referansları içerir. Başka eve kopyalanmaz; cc3db2 provider/store ve eski kapı eylemi/ayar callback reddini ekledi; 542 ilgili test/inceleme temiz, 808938e birleşik Client 3.115 test/analiz geçti; a2658ec Android98 ve bağımsızAPK kabulü tamamlandı. |
| MovieNightStore / `MovieNightPreset.storageKey` | Direct ev rutini | HA adresi ve başlangıç/bitiş sahne/script bağları içerir. Oda adı kopyası bu davranışları taşımaz; cc3db2 provider/store ve geç film eylemi reddini ekledi; statik depolama hatası ve mevcut Direct davranış testleri geçti, 808938e birleşik Client 3.115 test/analiz geçti; a2658ec Android98 ve bağımsızAPK kabulü tamamlandı. |
| WellbeingStore ve WellbeingDisclosureStore | Kişisel/cihaz özel veri + Direct HA bağları | Ortak ev kaydı olarak paylaşılmaz. Kaynak erişimi reddedildiğinde gizlilik filtresi boş/izinli hale gelemez; kişisel erişim ve PIN politikası korunur. 4eac0f6 diliminde253 ilgili test ve bağımsız inceleme geçti;4bc79dc/APK99 kendi CI kabulü tamamlandı. Kişisel ayar okuması kaynak bağımsız, ölçüm okumaları ayrı PIN/özel görünüm iznine bağlıdır. |
| `ambient_photos_v1` dosya arşivi | Kullanıcının seçtiği cihaz özel fotoğrafları | Core ambient ekranı arşivi yüklemiyor; cihazın açıkça seçilmiş kişisel arşivi Core evine atanmaz. 4eac0f6 kaynak bağımsız erişim ve belirsiz ayar yazısı testleri geçti; bağımsız inceleme ve4bc79dc/APK99 kendi CI kabulü tamamlandı. Arşiv silinmez veya otomatik paylaşılmaz. |
| Görünüm/dil, PIN, ekran/güç/zamanlama, pencere/DeX | Cihaz ayarları | Core/ev kimliğinden türetilmez. Evler arasında kişisel düzen kopyası bunları değiştirmez. Mevcut cihaz davranışı regresyonları korunur. |
| `home_source_v1` | Cihazın açık kaynak seçimi | Normal backup allowlist'ine alınmaz. Hatalı kayıt veya başarısız yazı sessiz Direct fallback üretmez. S08.3 kabulü mevcut. |
| SecureServerSessionStore | Cihazın gizli Core oturumu | Normal preferences/backup değildir; saklanan tuple tek başına yetki vermez. Login/refresh/context ve parola kapıları S08.1–3'te kabul edildi. |
| Backup restore journal ve allowlist | Açık yerel geri yükleme işlemi | Genel depo taramasıyla yeni Core anahtarları eklenmez. 9b11195 HA yarım-kayıt işaretini yeni snapshot/preview/restore dışında tutar; eski journal kurtarmasını engellemez veya işareti silmez. Tuple/revision bağlı preview/journal/rollback S08.5'in ayrı kabulüdür. |
| Dashboard WebviewTile URL ve izinler | Direct ev kartı | 0a742a9 wrapper Direct sahibini generic WebPanelView’e taşır; cold Core/retained-container/GlobalKey/geç native callback sınırları79 ilgili test+bağımsız inceleme ile geçti. Sonraki yerel birleşimde; yeni CI gerekli. |
| WebView cookie/localStorage/cache | Paylaşılan cihaz web oturumu | HA frontend ve Proxmox web console login'i API credential tuple'ından ayrıdır. Aynı cookie store'unun API yetkisi veya Core kaydı olduğu varsayılmaz; açık kullanıcı temizleme politikası korunur. |
| Yerel ses URI/artwork ve native oynatma durumu | Kişisel, geçici cihaz durumu | URI snapshot veya kalıcı credential deposuna yazılmıyor. Native ses route/Flutter engine ömründen bağımsız; yeni kaynak sessiz autoplay başlatamaz. Audit ek kalıcı store bulmadı; gerçek Core kaynak grafiği kabulü ayrıca izlenir. |
| Native `client_updates` staging | Geçici APK indirme/kurulum alanı | Ev snapshot'ı değildir. Mevcut session/source ve gerçek imza doğrulaması uygulanır; Core kayıt taşımasına katılmaz. |

## Test sınırı

S08.3, Core runtime'ının eski ev ekranlarını/provider tüketicilerini kurmamasını
kanıtladı. Bu envanter daha dar bir ek şartı kaydeder: başka bir Core ekranı
yanlışlıkla Direct provider/store'a erişse de kayıt veya ağ işlemi başlamamalı.
Gerçek `connectionConfigProvider` ve sayaçlı platform deposu kullanılmalı;
`ScopeHarness` içindeki bağlantı provider'ı override'ı bu yolu tek başına sınamaz.

Core ready/pending/signed-out/first-password, kaynak loading/error,
Direct→Core sırasında geciken okuma/login, eski signOut/save/clear ve Direct
olumlu davranışları ayrı senaryolardır. Kaynak sahipliği, idle veya arka plan
izniyle aynı şey değildir; geçerli Direct arka plan okumaları gereksiz yere
kesilmez. Önceden yola çıkmış yazı otomatik geri alınmaz veya yeniden denenmez.

Klasik SharedPreferences `getInstance/reload` altta tüm haritayı okuyabilir.
Ölçülen sınır hedef kaydın tüketimi, yayınlanması, mutasyonu ve ağ erişimidir;
bu aynı uygulama süreci içinde işletim sistemi seviyesinde bellek izolasyonu
veya cihazda sıfır fiziksel preference okuması iddiası değildir.

## Adaptörlere kalan işler

HA kimlik/sır eşlemesi ve ilk typed snapshot cache S08.7'de, medya/müzik
S08.8'de, altyapı S08.9'da kapanır. Web URL/origin izinleri ve özel sağlık
bilgileri genel HA eşlemesine sessizce dahil edilmez. Bu sonraki işler
S08.4→S08.5→S08.7→S08.4 biçiminde bir kabul döngüsü oluşturmaz.

## Son birleşimde envanter denetimi

`8d9e4d2` üzerinde `lib` genelindeki Store/SharedPreferences/secure-storage
yazıları ile dosya/Directory/cookie işlemleri yeniden arandı. Yeni Core
metadata/grant taşıması kalıcı Client deposu eklemez; kayıtların sahibi
mevcut Core registry’sidir. Native Android kaynaklarında ayrıca doğrudan
SharedPreferences yazısı bulunmadı. URI/artwork seçimi ve update staging
mevcut kişisel/geçici satırlarda kalır. Bu metin taraması gerçek provider
negatif testlerinin yerine geçmez.

Paylaşılan WebView veri temizliği mevcut WebPanelDataCoordinator bariyerini
kullanır: açık kullanıcı işlemi, emekli panellerin native tamamlanmasını
bekleme, her await sonrasında current kontrolü ve başarısızlıkta kapalı kalma.
Bu cookie deposu API credential tuple’ı veya Core ev kaydı olarak sınıflanmaz.
Birleşik tam testler ve yeni CI tamamlanmadan S08.4 toplam kabulü verilmez.
