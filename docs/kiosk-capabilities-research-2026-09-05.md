# Fully Kiosk Browser kapsamı ve Larenor uygulama planı

Tarih: 2026-09-05. Kullanıcı referansı **Fully Kiosk Browser** olarak doğruladı. İnceleme, `b2eb72f` tabanı ve o sırada çalışma ağacındaki Phase 2 değişiklikleri üzerinde yapıldı. Bu belge araştırma ve uygulama planıdır; cihaz kurulumu, izin, launcher, Home Assistant veya Android yönetim politikası değiştirilmedi.

## Karar

Larenor'un native ev/medya deneyimine kiosk yetenekleri eklenebilir. Ancak tek bir “kiosk açık” anahtarı bütün Android sürümlerinde aynı güvenceyi vermez. Önerilen ürün modeli:

| Profil | Amaç | Sınır |
| --- | --- | --- |
| Ev / duvar paneli | Native Larenor, karartma, ortam ekranı, kontrollü web panelleri | Kullanıcı Android'e dönebilir; uygulama PIN'i işletim sistemi kilidi değildir. |
| Yönetilen kiosk | Ayrılmış cihazda DPC tarafından izin verilen uygulamalarla çalışma | Device-owner/EMM kurulumu, kurtarma yolu ve cihaz testi gerekir. |
| Masaüstü / DeX | Pencere, fare, klavye, harici ekran ve medya kullanımı | Katı kiosk kilidinden ayrı profil olmalı; pencere kontrollerini kapattığını iddia etmemeli. |

Android'in gerçek **lock task** modu DPC izin listesine dayanır; normal ekran sabitleme kullanıcı tarafından sonlandırılabilir. [Android lock task rehberi](https://developer.android.com/work/dpc/dedicated-devices/lock-task-mode)

Özellikle Samsung, DeX'i kiosk/lock-task durumundaki cihazlar için desteklemediğini belirtiyor. Dolayısıyla DeX ve tam işletim sistemi kilidini aynı anda vaat etmek doğru değil. [Samsung DeX ve Knox](https://docs.samsungknox.com/dev/knox-sdk/features/mdm-providers/device-management/samsung-dex-and-knox/)

## Mevcut kodun kanıtladıkları

- [main.dart](../lib/main.dart) ve [ImmersiveModeGuard](../lib/core/immersive_mode_guard.dart) başlangıçta/ön plana dönüşte `immersiveSticky` istiyor. Gerçek görünürlüğü ölçen bir native köprü yok.
- [ScreenPolicyRunner](../lib/features/settings/presentation/screen_policy_runner.dart) ekran uyanıklığı ve uygulama parlaklığını seri uygular; arka planda bırakır. Gece parlaklığı sabit `%5`. `screenOffAtNight` ekranı hemen kilitlemez: uyanık tutmayı bırakır ve Android'in uyumasına izin verir.
- [IdleGate](../lib/features/settings/presentation/idle_gate.dart) dokunma süresine göre saat/tarih/HA hava durumu gösterir. Yalnız `onPointerDown` etkinliği izleniyor; klavye, tekerlek, oynatma ve harici uygulama etkinliği ortak politikaya bağlı değil. Saat sabit konumda; piksel kaydırma yok.
- [Settings providers](../lib/features/settings/providers/settings_providers.dart) gece aralığı ve boşta kalma süresini saklıyor; haftanın günleri, cihaz alarmı, şarj olayları ve sensör politikası yok. Ekranı açık tutma, ortam modu ve gece seçenekleri varsayılan kapalı.
- [PIN saklama](../lib/features/settings/data/pin_lock_store.dart) güvenli depoda PIN/deneme sınırı tutuyor; [ayar kapısı](../lib/features/settings/presentation/settings_gate_screen.dart) arka plana dönüşte yeniden kilitliyor. Bu koruma ayarlar içindir; Home/Recents/bildirim/periferik uygulama engeli sağlamaz.
- [AndroidManifest](../android/app/src/main/AndroidManifest.xml) `HOME`/`DEFAULT` rol adaylığını içeriyor. [MainActivity](../android/app/src/main/kotlin/com/ersingundem/larenor/MainActivity.kt) sade `FlutterActivity`; DPC, `DeviceAdminReceiver`, boot receiver, lock task, kamera/mikrofon veya özel yönetim servisi yok. Manifestte ağ/keşif izinleri var; bu izinler Wi-Fi'yi zorla açma yetkisi vermez.
- [HA frontend](../lib/features/ha_tools/presentation/ha_frontend_screen.dart) ayrı tarayıcı oturumu kullanıyor; uzun ömürlü HA tokenı JS/depolamaya aktarılmıyor. Geri/yenile/hata görünümü var; gezinme `http/https/about` şemalarıyla sınırlı fakat host izin listesi yok.
- [WebviewTile](../lib/features/dashboard/presentation/tiles/webview_tile.dart) genel URL yükleyip JavaScript çalıştırıyor; ortak köken politikası, sekme yönetimi veya native JS komut köprüsü bulunmuyor. Native köprü eklenmeden önce bu yüzey birleştirilmeli.
- [Jellyfin player](../lib/features/media/jellyfin/presentation/player/jellyfin_player_screen.dart) kendi parlaklık sürüklemesini uyguluyor. Yeni kiosk politikası, oynatıcı ile gece/ortam parlaklığının sahipliğini açıkça paylaşmalı; iki bileşenin son yazan olarak davranması kabul edilmemeli.
- [Şifreli yedekleme](../lib/features/backup/data/backup_codec.dart), kurtarma, [sabit release imzası](android-release-signing.md) ve monoton Android sürüm kodu mevcut. Bunlar uzaktan cihaz yönetimi veya sessiz APK kurulumu anlamına gelmez.

Mevcut otomasyon testleri: [ekran yaşam döngüsü](../test/features/settings/screen_lifecycle_test.dart), [gece aralığı](../test/features/settings/night_window_settings_test.dart), [ayar PIN kapısı](../test/features/settings/settings_gate_screen_test.dart). Platform kanalları taklit edildiğinden gerçek donanım kilidi/uyandırma kanıtı değiller.

### Önce çözülmesi gereken API 36 farkı

İncelenen son debug merged manifest `minSdk=24`, `targetSdk=36` içeriyor. [Gradle](../android/app/build.gradle.kts) hedefi Flutter'dan alıyor; bu gözlem kalıcı destek taahhüdü değil, her artifact için tekrar ölçülmeli.

Resmi Flutter API belgesi, target 36+ için `edgeToEdge` dışındaki `SystemUiMode` seçimlerinin çalışmadığını söylüyor. Mevcut `immersiveSticky` çağrısını başarılı “tam ekran” göstergesi sayamayız. [Flutter SystemChrome sözleşmesi](https://api.flutter.dev/flutter/services/SystemChrome/setEnabledSystemUIMode.html)

İlk teknik iş, desteklenen Android sürümlerinde `WindowInsetsControllerCompat` ile native görünürlük ölçümü/uygulamasını denemek; IME, izin penceresi ve ön plana dönüş testleriyle doğrulamaktır. Android'in masaüstü pencere başlığı ayrıca ele alınmalıdır; uygulamanın kapatabildiği bir sistem çubuğu gibi varsayılmamalıdır. [Android immersive ve masaüstü pencere sınırları](https://developer.android.com/develop/ui/views/layout/immersive)

## Resmi özellik ailelerinin karşılığı

Aşağıdaki aileler [Fully Kiosk Browser özellik listesinden](https://www.fully-kiosk.com/en/#features) alınan kısa kapsam başlıklarıdır. Sağ sütunlar Larenor koduna dayalı değerlendirme ve öneridir. “Kısmi” yalnız belirtilen davranışı ifade eder; bütün ayarların eşdeğer olduğu anlamına gelmez.

| Özellik ailesi | Larenor bugün | Uygulanacak karşılık / iş |
| --- | --- | --- |
| Web içerik ve sekmeler | Kısmi: HA frontend ve web karosu | K03: ortak WebPanel, sekme/başlangıç adresi, istemci sertifikası ve oturum modeli. |
| Tarayıcı politikaları | Kısmi: şema filtresi | K03: köken izin listesi, gezinme ve indirme politikası, çerez/depolama ömrü; güvenli hata davranışı. |
| PDF, video, dosyalar | Kısmi: native Jellyfin oynatımı | K05: kullanıcı seçili belgeler, imzalı/denetimli yerel içerik, kota ve oynatma listesi. |
| Uygulama başlatıcı | HOME rol adayı | K02/K04: izinli uygulama kısayolları; native ekranlar ortak gezintide kalır. |
| Araç çubukları ve görünüm | Native ortak tasarım var | K01/K03: profil bazlı çubuklar; native Apple Home düzenini web ayarlarıyla değiştirmemek. |
| Gezinme ve etkileşim | Kısmi: geri/yenile | K03/K11: klavye, fare, erişilebilir odak, tarayıcı geçmişi ve çevre birimleri. |
| Otomatik içerik yenileme | Native yeniden bağlanma var | K03/K12: WebView renderer kurtarma, sınırlı geri çekilme, yeniden bağlanınca doğrulama. |
| Ekran ve cihaz ayarları | Kısmi: uyanıklık/gece kısma | K01/K06: tek ekran politikası, haftalık program, güç/batarya olayları. |
| Ekran koruyucu | Kısmi: saat/hava durumu | K05: albüm/oynatma listesi, piksel kaydırma, karanlık görünüm, çevrimdışı içerik. |
| Kiosk kilidi | Ayar PIN'i var | K02/K04: ayrı çıkış yetkisi, izinli uygulamalar, gerçek DPC kilidi ve kurtarma. |
| Görsel/akustik hareket | Yok | K10: isteğe bağlı yerel algılama; kamera/mikrofon varsayılan kapalı. |
| Cihaz hareketi | Yok | K10: donanım yeteneğine göre sensör ve güç olayı tetikleri. |
| JavaScript cihaz arayüzü | Yok | K08: yalnız güvenilen WebPanel kökenlerine dar komut sözleşmesi. |
| Uzaktan yönetim / REST | Yok | K07: ayrı eşleştirme ve yetkilendirme; ekran/sağlık/ayar komutları. |
| Kullanım istatistikleri | Süreli kullanım sayacı yok | K12: yerel, sınırlı saklama; içeriksiz sayımlar ve kullanıcı seçili dışa aktarım. |
| Çökme/güncelleme kurtarma | Depo kurtarması var | K12/K13: hata döngüsünü kesen yeniden açılma ve yönetilen dağıtım. |
| Kurulum / yapılandırma dağıtımı | Şifreli yedek ve imzalı APK | K04/K13: sürümlü profil, sahiplik kurulumu, yönetilen güncelleme. |
| MQTT / filo yönetimi | Yok | K07/K13: HA ile açık sözleşme ve isteğe bağlı ayrı filo servisi. |

**Tamlık ölçütü:** Bu araştırma aile bazında plan verir. K00 işi, resmi konfigürasyon/API seçeneklerini sürümlü `capability` kimliklerine ayırıp her birini test veya belgelenmiş platform sınırına bağlamalıdır. “350+” pazarlama sayısı ile yüzde hesaplanmamalı; desteklenen model/API/profil kombinasyonunun paydası yayımlanmalıdır. Fully'nin yeni bir ayarı, henüz test edilmemiş Larenor özelliği olarak otomatik “destekleniyor” işaretlenmemelidir.

## Android yetki ve uygulanabilirlik matrisi

| Yetenek | Normal uygulamada yol | Ek yetki / sınır |
| --- | --- | --- |
| Uyanık tutma, uygulama parlaklığı | Pencereye özgü ekran politikası | Tüm cihaz parlaklığını değiştirme ayrı `WRITE_SETTINGS` özel erişimidir; normal runtime izin penceresiyle eşdeğer değil. [Settings.System](https://developer.android.com/reference/android/provider/Settings.System) |
| Gece karartma ve program | Ön planda zaman çizelgesi, saat dilimi değişiminde yeniden hesaplama | Süreç kapalıyken dakik zamanlama özel alarm erişimi gerektirebilir; izin reddinde yaklaşık zamanlama açıkça gösterilmeli. [Android exact alarms](https://developer.android.com/about/versions/14/changes/schedule-exact-alarms) |
| Gerçek ekran kapatma | Standart modda karartma / OS zaman aşımı | `lockNow` için etkin device-admin `force-lock` yetkisi gerekir. Bu işlem güvenli kilit ekranını da etkileyebilir. [DevicePolicyManager](https://developer.android.com/reference/android/app/admin/DevicePolicyManager#lockNow()) |
| Ekranı uyandırma | Uygun Activity yaşam döngüsünde `setTurnScreenOn` | Güvenli PIN/biometrik kilidi sessizce atlamayı vaat etmemek. Tamamen kapanmış cihazın açılması donanım/OEM yeteneği olarak ayrı değerlendirilir. [Activity](https://developer.android.com/reference/android/app/Activity#setTurnScreenOn(boolean)) |
| Home rolü ve başlangıç | Kullanıcının Larenor'u launcher seçmesi | Yönetilen kurulum kalıcı Home tercihi sağlayabilir. Boot receiver tek başına her koşulda ön plana çıkma garantisi değildir. [Dedicated devices cookbook](https://developer.android.com/work/dpc/dedicated-devices/cookbook) |
| Home/Recents/uygulama kilidi | Normal modda kullanıcıya sunulan ekran sabitleme | Gerçek lock task: DPC allowlist; yönetim yetkisi yoksa “kilitli” durumuna geçilmemeli. [Lock task](https://developer.android.com/work/dpc/dedicated-devices/lock-task-mode) |
| Güvenli mod, reset ve kurulum politikası | Normal uygulama API'siyle güvence yok | Ayrılmış cihaz yönetimi ve kullanıcı kısıtları gerekir. Mevcut kişisel cihazda sessizce uygulanacak ayarlar değildir. [Dedicated device restrictions](https://developer.android.com/work/dpc/dedicated-devices/cookbook#public-kiosks) |
| Cihazı yeniden başlatma | Uygulamayı yeniden açmak farklı işlem | `DevicePolicyManager.reboot` device owner içindir. [Reboot API](https://developer.android.com/reference/android/app/admin/DevicePolicyManager#reboot(android.content.ComponentName)) |
| Wi-Fi/Bluetooth aç-kapat | Kullanıcıya sistem akışı göstermek | Modern Android'de normal uygulamalar için sessiz aç-kapat kısıtlı; DO/PO/sistem istisnaları ayrıca ölçülür. [Wi-Fi API](https://developer.android.com/reference/android/net/wifi/WifiManager#setWifiEnabled(boolean)), [Android 13 Bluetooth](https://developer.android.com/about/versions/13/behavior-changes-13#bluetooth-adapter) |
| Kamera/mikrofon algılama | Kullanıcı açınca runtime izin; önce yalnız ön plan | Sürekli arka plan kullanımı FGS türü, bildirim ve while-in-use kurallarına bağlı. Boot sonrası gizli kamera başlatma tasarlanmamalı. [FGS türleri](https://developer.android.com/develop/background-work/services/fgs/service-types), [başlatma sınırları](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start) |
| BLE/USB/NFC/QR | Yeteneğe göre isteğe bağlı bağdaştırıcı | BLE tarama/bağlantı ve USB erişimi ayrı izinler; kamera QR okuma ayrı seçim. Konum çıkarımı başka amaç sayılmalı. [Bluetooth izinleri](https://developer.android.com/develop/connectivity/bluetooth/bt-permissions) |
| Ekran görüntüsü / uzaktan görüntü | Uygulama içi görünüm ve tüm cihaz görüntüsü ayrı | MediaProjection her oturum için kullanıcı onayı ve uygun servis gerektirir; DPC genel bir sessiz ekran kaydı izni değildir. [MediaProjection](https://developer.android.com/media/grow/media-projection) |
| Sessiz APK dağıtımı | Normal kullanımda kullanıcı onaylı installer | Yönetilen cihaz/EMM hattı; imza, paket, sürüm ve kurtarma kontrolü zorunlu kabul kriteri. Diğer durumda onay gerektiren kurulum olarak sunulmalı. [Android managed devices](https://developer.android.com/work/dpc/dedicated-devices) |

Device-admin ile device-owner aynı yetki değildir. Yönetilen sahiplik kurulumu normal bir uygulama izni diyaloğundan ibaret değildir; sıfırlanmış/yeni cihaz hazırlığı gerekebilir. Bu plan hiçbir mevcut cihazın sıfırlanmasını veya sahipliğinin değiştirilmesini yetkilendirmez. [Android cihaz hazırlama](https://developer.android.com/work/dpc/dedicated-devices/cookbook#development)

## Native uygulama ve tarayıcı modu sınırları

1. **Aynı amaç, ayrı uygulama katmanı.** DOM otomasyonu, User-Agent, HTTP auth/istemci sertifikası, sekmeler, çerezler, WebRTC ve HTML form yüklemeleri WebPanel'e aittir. Native oda/medya ekranlarında karşılıkları uygun native ayar/iş akışıdır. Native ekrana sahte URL/DOM üretmek bakım yükünü artırır.
2. **Tek WebPanel altyapısı.** Mevcut HA frontend/web karo yüzeylerine URL doğrulama, host/köken izin listesi, pop-up/harici `intent` kararı, dosya erişimi, zoom/font, indirme, web izinleri ve oturum temizleme politikası ortak verilmeli. TLS doğrulamasını yok sayma seçeneği yerine güvenilir sertifika kurulumu tasarlanmalı.
3. **JS çalıştırma, cihaz yetkisi değildir.** Köprü varsayılan kapalı; komutlar tipli, dar ve kaynak kökeni denetimli olmalı. Yabancı iframe/yönlendirme native yetki kazanamaz. HA ve Proxmox kimlik bilgileri genel web sayfalarına aktarılmaz. [Android WebView native-bridge güvenliği](https://developer.android.com/privacy-and-security/risks/insecure-webview-native-bridges)
4. **Ekran kapalıyken web uygulamasını sürekli çalışır varsaymamak.** Fully de WebView'in bu durumda duraklamasını belgeliyor. Larenor'un native veri katmanı ve yeniden eşitleme davranışı web sayfasının zamanlayıcısından ayrılmalı; sürekli ekran için ortam modu ayrı tercih olmalı. [Fully platform sınırlamaları](https://www.fully-kiosk.com/en/#issues)
5. **Uzaktan arayüzü yeniden tasarlamak.** Fully'nin yerel REST yüzeyi parola parametresi kullanır. Larenor için ayrı eşleştirme, kısa ömürlü/iptal edilebilir kimlik, TLS veya güvenilen tünel, işlem kapsamı ve rate-limit önerilir; HA tokenı yönetim anahtarı olarak tekrar kullanılmaz. [Fully REST referansı](https://www.fully-kiosk.com/en/#rest)
6. **Uyumluluğu adlandırmak.** HA'nın mevcut Fully entegrasyonu gerçek Fully Remote Admin hizmetini bekler. Larenor MQTT discovery/companion sözleşmesi veya test edilen sınırlı uyumluluk adaptörü sunabilir; bütün Fully API'sini uygulamadan mevcut entegrasyona tam uyum iddiası kurulmaz. [Home Assistant Fully Kiosk entegrasyonu](https://www.home-assistant.io/integrations/fully_kiosk/)

## Huawei ve Samsung için ürün kararı

**Huawei:** EMUI arka plan ve pil politikaları süreçleri durdurabilir. Huawei destek belgeleri App launch/Run in background yönetiminin etkisini doğruluyor; bu ayarlar kodla verilmiş bir izin gibi kabul edilemez. Cihaz modeli, Android/EMUI sürümü, WebView sağlayıcısı, GMS varlığı ve launcher seçilebilirliği teşhis ekranına eklenmeli. Varsayılan launcher seçilemeyen cihazda yönetilen kiosk desteği başarısız olarak işaretlenmeli; sistem launcher'ını ADB ile kaldırma “kurulum çözümü” olarak otomatik uygulanmamalı. [Huawei arka plan rehberi](https://consumer.huawei.com/uk/support/content/en-gb00428704/)

Android APK çalıştırabilen Huawei cihazları ile farklı çalışma ortamlarına sahip HarmonyOS ürünleri ayrı destek hedefleridir. Kullanıcının gerçek modeli/sürümü henüz ölçülmedi; “Huawei destekleniyor” şeklinde marka genelinde garanti verilmemeli. GMS gerektiren çevre birimi/algılama bağımlılıkları seçilirse çevrimdışı ve GMS'siz senaryo ayrıca doğrulanmalı.

**DeX:** Masaüstü profili resize, caption-bar insets, fare tekerleği, sağ tık, Tab/Shift-Tab/Enter/Esc ve pencere odak kaybını desteklemeli. Her `inactive` olayını güvenli kullanıcı çıkışı veya uygulama kapanışı sanmamak; PIN koruması arka plan politikasına uygun kalmalı. Sabit yön veya launcher zorlaması bu profilde uygulanmamalı. [Samsung app continuity](https://developer.samsung.com/galaxy-z/app-continuity.html), [DeX giriş uyumu](https://developer.samsung.com/samsung-dex/modify-optional.html)

Knox ayrı platform modülüdür. Genel Android cihazlara bağımlılık olarak eklenmemeli. Ayrıca Knox `setDexDisabled` davranışı Android 16'da değişmiş; eski SDK örneğini bütün Samsung cihazlarına uygulamak güvenilir olmaz. [Güncel DexManager API](https://docs.samsungknox.com/devref/knox-sdk/reference/com/samsung/android/knox/dex/DexManager.html)

## Erişilebilirlik ve mahremiyet varsayılanları

Bunlar Larenor için önerilen ürün kabul kurallarıdır:

- Kamera, mikrofon, yüz algılama, BLE yakınlık, uzaktan görüntü ve uzaktan yönetim ilk kurulumda kapalı. İzin yalnız ilgili özellik açıldığında istenir; ret veya sonradan iptal uygulamayı bozmaz.
- Hareket/yüz varlığı algılama yalnız yaklaşan birinin ekranı uyandırması içindir; kimlik tanıma değildir. Öncelikle cihaz üzerinde, kimlik çıkarmadan çalışır. Ham kare/ses kaydı, yükleme veya geçmiş tutma varsayılan davranış olmaz. Açık algılama göstergesi ve tek adımda durdurma bulunur.
- İsteğe bağlı yüz profili tanıma ayrı bir sonraki araştırma/özelliktir: açık kayıt ve silme akışı, cihazda tutulan şifreli şablon, GMS gerektirmeyen paketli model ve model lisansı incelemesi gerekir. Eşleşme yalnız kişiselleştirilmiş görünüm önerir; sağlık/özel içerik, yönetici ayarı ve kapı açma yetkisini tek başına vermez. Bunlar OS biyometri/PIN ve ilgili eylem yetkisiyle korunur. DeX çoklu pencere, kamera başka uygulamada meşgul, izin iptali ve termal/pil bütçesi ayrı test edilir. Gerçek yüz verisi toplanması veya kameranın açılması bu araştırmanın parçası değildir.
- Cihazın ortam hareketi yalnız panelin uyanmasını etkiler. Kapı açma, alarm kapatma, medya isteği veya HA servisi çağrısı ayrıca tanımlanmış yetki/eylem akışından geçer.
- Kiosk çıkışı yalnız gizli dokunma hareketine bağlanmaz: erişilebilir bakım menüsü, fiziksel klavye yolu ve PIN doğrulama bulunur. PIN deneme sınırı süreç yeniden açılınca korunur.
- TalkBack, büyük yazı, yüksek kontrast, azaltılmış hareket ve sesli yönlendirme test edilir. Ses kısma/bildirim engelleme gibi yönetim politikaları erişilebilirliği bozmamalı; medya, çağrı ve yardım ihtiyacıyla çelişen seçenekler açıkça sunulmalı.
- Erişilebilirlik servisi, kullanıcının verdiği görevden bağımsız olarak diğer uygulamalara dokunmak veya sistem izinlerini otomatik onaylamak için kullanılmaz. OS kilidi için DPC yolu tercih edilir.
- İstatistiklerde URL/query, tuş içeriği, ekran görüntüsü, HA tokenı, konum veya yüz kimliği tutulmaz. Yerel saklama süresi ve dışa aktarma önizlemesi bulunur. Kamera görüntüsü ile tanı raporu ayrı paylaşım işlemleridir.

## Öncelikli iş listesi ve kabul kriterleri

Eforlar tek geliştirici için ilk mühendislik tahminidir: **S ≤2 gün**, **M 3–5 gün**, **L 6–10 gün**, **XL >10 gün**. Gerçek cihaz erişimi, OEM hataları ve mağaza/kurumsal kayıt süreleri dahil değildir. İşler test sonucu görülmeden “tamamlandı” sayılmaz.

| İş | Öncelik / efor | Bağımlılık | Somut kabul kriteri |
| --- | --- | --- | --- |
| **K00 – Yetkinlik envanteri ve teşhis** | P0 / M | Yok | Her resmi özellik/ayar için kimlik, profil, desteklenen API aralığı, izin, donanım, durum ve test bağlantısı. İzin yok/cihaz desteklemiyor ayrımı. APK min/target SDK ve WebView sürümü raporda. Destek yüzdesinin paydası açık. |
| **K01 – Tek ekran/etkinlik politikası** | P0 / M | K00 | API 36 native fullscreen deneyi; IME aç/kapa ve 20 resume geçişi. Dokunma, klavye ve fare idle'ı yeniler. Oynatma/gece/manuel parlaklık önceliği deterministik; çıkışta sistem tercihi geri gelir. Desteksiz durum UI'da doğru gösterilir. |
| **K02 – Profil ve kiosk çıkışı** | P0 / M | K00–K01 | Ev/duvar/masaüstü profili, ayrı bakım/çıkış yetkisi. PIN yanlış denemesi yeniden açılışla sıfırlanmaz. Normal mod gerçek kilit diye gösterilmez; izinli dış uygulamadan dönüş test edilir. |
| **K03 – Güvenli WebPanel** | P1 / L | K00–K02 | HA frontend ve web karosu ortak host politikası kullanır. Sekmeler, başlangıç adresleri, auth/sertifika, cookie/storage, zoom/font, upload/download, pop-up/intent ve hata kurtarma testleri. Yönlendirme/iframe güven sınırını aşamaz; renderer ölümü token sızdırmadan toparlanır. |
| **K04 – Yönetilen cihaz / DPC** | P1 / L–XL | K02; ayrı test cihazı | İzin listesi olmadan `startLockTask` çağrısı “kilitli” sayılmaz. Home/Recents/bildirim/yeniden başlatma senaryoları fiziksel cihazda geçer. Yönetici çıkışı, uninstall/deprovision ve kilitli cihaz kurtarma provası vardır. Kurulum planı hiçbir kişisel cihazı otomatik sıfırlamaz. |
| **K05 – Ortam ekranı ve içerik listeleri** | P1 / M–L | K01; medya oynatıcı | Saat/hava/yerel fotoğraf/video/PDF/web içerikleri; bozuk dosyayı atlayıp devam etme, çevrimdışı cache kotası, piksel kaydırma ve hareket azaltma. Aktif medya oturumu yanlışlıkla idle ekranıyla örtülmez. |
| **K06 – Program, güç ve pil** | P1 / M | K01; gerekirse K04 | Haftalık zaman pencereleri, saat dilimi/yaz saati değişimi, şarj tak/çıkar, düşük pil. Exact alarm reddinde açık fallback. Karartma, ekran kapatma ve tam cihaz kapanması ayrı adlandırılır. 24 saatlik ölçümde wake-lock sızıntısı yok. |
| **K07 – Eşleştirilmiş uzaktan API ve MQTT** | P2 / L | K00–K02; health/action altyapısı | Varsayılan ağ dinleyicisi yok. Read/control/admin kapsamları, iptal, rate-limit ve replay/tekrar denemede eylem çoğaltmama. Sensör keşfi ve komut ack testleri; hiçbir URL/log/export içinde sır yok. |
| **K08 – Sınırlı web→native köprü** | P2 / M–L | K03/K07 | Tipli/sürümlü yöntemler; izinli üst köken kontrolü. Yabancı iframe, HTTP downgrade, yeni sekme ve izin iptali native komut çalıştıramaz. TTS/print/QR gibi işlemler kullanıcı seçimiyle açılır. |
| **K09 – Cihaz bilgisi ve uzaktan görünüm** | P2 / M–L | K07 | Batarya, ağ erişimi, uygulama sürümü ve kaynak kullanımı salt okunur ölçülür. Uygulama görünümü ile MediaProjection ayrıdır. Sistem onayı bitince kayıt biter; PIN/kimlik bilgisi ekranları paylaşılmaz. |
| **K10 – Hareket/karanlık/cihaz hareketi** | P2 / L | K01/K06; izin/sensör katmanı | Ön plan ve izin iptali testleri önce. Yerel algılama, minimum örnekleme, hassasiyet, karanlıkta davranış, kamera meşgul ve Termal/batarya ölçümü. 24 saat bekleme testinde izin dışı örnek alınmaz; olmayan sensör açıkça belirtilir. |
| **K11 – QR/NFC/BLE/USB/TTS/print** | P2 / L | K03/K08; ilgili donanım | Her çevre birimi bağımsız etkinleştirilir. GMS'siz cihaz, izin reddi, kablo çıkarma, okuyucu klavye modu ve yinelenen tarama testleri. Tarama verisi otomatik komut/JS olarak çalıştırılmaz. |
| **K12 – Watchdog ve yerel kullanım ölçümü** | P1 / M–L | K01/K03 | WebView/crash/reconnect kurtarma sayısı sınırlı; başarısızlık döngüsü güvenli bakım ekranına düşer. Yerel içeriksiz sayımlar, saklama süresi, CSV önizlemesi. Force-stop/OS kapatma için desteklenmeyen otomatik dirilme garantisi verilmez. |
| **K13 – Yönetilen dağıtım ve isteğe bağlı filo** | P3 / XL | K04/K07/K12 | İmzalı sürümlü profil, dry-run/diff, yedek/kurtarma. APK sertifika/paket/sürüm doğrulaması. Kademeli dağıtım ve cihaz durumları; sessiz kurulum yalnız yetkili cihazda. Bulut hesabı veya internet, yerel ev kullanımı için zorunlu olmaz. |
| **K14 – OEM sertifikasyonu** | Her aşamanın çıkış kapısı / L+ | Test cihazları | Aşağıdaki matriste geçen kombinasyonlar yayımlanır. Başka model/sürüm “test edilmedi” kalır. Her yeni izin ve native API için denial/revocation/process-death testi. |

İlk teslim dilimi K00–K02 olmalı; bu, bugün varmış gibi görünen fullscreen/idle/kilit davranışını ölçülebilir hale getirir. WebPanel ve ortam ekranı sonraki kullanıcı değeri yüksek dilimdir. DPC ve sensör işleri ayrı kurulum/izin deneyimiyle ilerler. Tam filo yönetimi bağımsız bir backend ürünü olduğu için native panel tamamlanmasını bekletmemeli.

## Doğrulama ve CI planı

| Katman | Planlanan kontrol |
| --- | --- |
| Mevcut Flutter CI | Ekran state-machine, gece/hafta programı, saat dilimi, idle/klavye/fare, parlaklık önceliği, PIN ve izin reddi deterministik testleri. |
| WebPanel sözleşme testleri | Yerel fixture HTTP sunucusu: redirect, iframe, TLS hatası, dosya seçici iptali, cookie temizliği, JS köprü kökeni, renderer kapanışı. Prod HA kullanılmaz. |
| Android native CI | Ayrı emülatör job'unda desteklenen düşük API + 34 + 36; IME, activity recreation, lock-task izinli/izinsiz, permission revoke. Native değişikliklerde çalışır; saat süresine bağlı flaky unit assertion kullanılmaz. |
| Yönetilen cihaz laboratuvarı | Ayrılmış/sıfırlanabilir test cihazı, gerçek DPC enrollment/exit/reboot/update. Günlük uygulama CI'sı kişisel cihazda bu işlemleri başlatmaz. |
| Samsung | Normal tablet + DeX pencere/harici ekran + ayrı managed kiosk oturumu. Dock çıkarma, fare/klavye, ekran yönü ve PIN ile geri dönüş. |
| Huawei | Kullanıcının tam model/EMUI/WebView kombinasyonu. Launcher seçimi, ekran kapalı 24 saat, şarj döngüsü, arka plan ölümü ve GMS'siz çevre birimi testi. |
| Güvenlik/performance | Gizli anahtar içermeyen log/export; remote/JS auth fuzz; WebView bellek kotası; kamera kapalıyken sıfır kare/ses; termal, pil ve ağ baytı karşılaştırması. |

Bu araştırmada bu cihaz testleri çalıştırılmadı. Kanıt, kaynak kodu incelemesi ve erişim tarihindeki resmi belgelerle sınırlıdır. Belgedeki uygulama/efor kararları mühendislik önerisidir; donanım davranışı ölçülmeden evrensel uyumluluk iddiasına dönüşmez.
