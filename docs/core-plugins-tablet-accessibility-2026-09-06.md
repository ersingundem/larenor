# Core bileşen kataloğu: tablet erişilebilirliği

Bu yerel B5.1 dilimi `ServerPluginsScreen` kataloğundaki başlıkları, inceleme eylemlerini ve klavye odağını düzeltir. Mevcut işler ekranına geçiş gerçek ekran/controller ile doğrulanır. Jobs, hesap, PIN, API, controller ve kurulum davranışı değiştirilmez.

Çalışma ağacı `/private/tmp/larenor-core-plugins-tablet-ui`, dal `codex/core-plugins-tablet-ui`, taban `0c7184bd1ca88e65e22bc95128116bc39c816538`. Son üretim/test kaynağı `bdbe3e79a69cb23e96d1f1a9b093d49643e67477`.

## Değişiklik

- Katalog bileşen adı ayrı bir heading düğümüdür. İnceleme düğmesinin görünen metni korunur; erişilebilir adı bileşeni de söyler, örneğin `Jellyfin · Kurulumu incele`.
- Katalog/üst eylemler native `CupertinoButton` olarak kalır; aynı key ve aynı `onPressed` callback'leri kullanılır. Yerel kapsayıcı en az 48×48 hedef, ayrı button semantiği, disabled durumunda eylemsiz semantik ve 4 px odak payı sağlar. Odak rengi mevcut tema primary rengidir.
- Native Tab kaydırması düğmenin kenarını görünür yaparken dışarı çizilen 3,5 px halkayı kesebiliyordu. Son layout karesinde halka yalnız viewport dışında kalıyorsa görünür alana alınır. Zaten görünen üst eylemler arasında Tab/Shift-Tab kaydırma konumunu değiştirmez.
- Odak karesi mounted, yakalanmış primary focus kimliği, mevcut ekran epoch'u, route ve TickerMode ile bağlanır. Kapanmış/örtülmüş/idle sayfanın eski bildirimi kaydırma veya eylem başlatamaz.

Form ve plan önizleme modalının üretim kodu değişmez. Mevcut `SettingsSection`, tipografi, renkler ve tek sütunlu 1000 px azami içerik düzeni korunur. Yeni global tasarım bileşeni veya çeviri anahtarı eklenmez.

## RED → GREEN kanıtı

| Checkpoint | Gerçek koşu | Sonuç |
| --- | --- | --- |
| `6575430` → `f48844b` | İlk 16 tablet testi | 6 PASS / 10 FAIL → 16 PASS |
| Exact `0c7184b` kontrollü tekrar | Düzeltilmiş Text-leaf semantik ölçümüyle başlık/ad/kontrast 12 testi | 2 PASS / 10 FAIL; ardından üretim byte-exact `f48844b` durumuna geri kondu |
| `e440f5c` → `1cd3277` | Gerçek ileri/geri Tab, 600/1280, açık/koyu | 4 FAIL: halka altı 1003,5 > viewport 1000 → 29 tablet testi PASS |
| `164b42c` → `984ccae` | Zaten görünen eylemlerde konum korunumu | 1 FAIL: offset 20 → 0 → 30 tablet testi PASS |
| `bdbe3e7` | Nihai ilgili 10 dosya; 32 tablet testi dahil | **273 PASS / 10 saniye** |

İlk denemede semantik handle temizliği ve klavye odak modunun testte etkinleştirilmesi hatalıydı; bunlar ürün hatası olarak sayılmaz. Native button key'inden alınan semantik üst kapsayıcıya işaret edebildiği için son testler Text leaf'i kullanır. “Kart semantiği birleşiyor” ön yorumu ayrıca kabul edilen bir ürün hatası değildir; kabul, ayrı heading ve bileşeni içeren tek erişilebilir eylem adına dayanır. Örtülü arka sayfanın erişilemezliği widget varlığıyla değil, gerçek root semantik ağacında eylem adının bulunmamasıyla ölçülür.

İlk genişletilmiş koşudaki **54 PASS / 9 FAIL** kaydı saklanır. Eski custom-settings testi `ensureVisible` ardından yeni layout karesini beklemeden y=1025 hedefini tıklıyordu. Yalnız yerel `tap` yardımcısına `pumpAndSettle` ve `hitTestable` doğrulaması eklendi; timeout, sonuç veya güvenlik assertion'ı gevşetilmedi. Yeni testlerdeki diğer yanlış locator/odak modu ölçümleri düzeltildi. Sonraki doğal Tab deneyi gerçekten kırpılan halkayı ayrıca yakaladı; ilk ekran görüntüsü veya sadece kart sınırı bunu tamamlanmış kabul ettirmedi.

## Nihai doğrulama

32 yeni tablet testi gerçek `ServerPluginsScreen`, `ServerPluginJobsScreen`, account/controller ve bounded sentetik HTTP kullanır:

- EN/TR, 600/1280 px, 2x metin; beş inceleme eyleminin ayrı adı ve heading/button ayrımı.
- Tab/Shift-Tab, Enter ile gerçek işler ekranına geçiş, Space ile açık yenileme; geçiş sonrası eski callback sıfır istek.
- Gerçek semantik tap ile ayar formu; örtülü katalog semantiği yok; Enter ile iptal sıfır mutation.
- Busy düğmede semantic tap yok; tutulan eski callback işlem yapmaz.
- İlk/son kart halkası kart sınırında; gerçek ileri/geri Tab ile tüm beş kart halkası navbar/viewport içinde. 1280 px varyantı üst 24/alt 16 px safe inset içerir.
- Görünür üst eylemler arasında offset korunur. Route/idle odak karesinden önce değişirse, kırpılmış halka olmasına rağmen eski kare kaydırmaz ve eski eylem çalışmaz.

İlgili koşu mevcut plugin plan/controller, jobs, hizmet ekranı, media preparation ve gerçek SettingsGate/PIN regresyonlarını içerir. Kurulum/iş iptal yetkisi ve oturum yaşam döngüsünün önceki assertion'ları korunur.

Bağımsız kaynak incelemesi: `bdbe3e7` için ikinci reviewer CLEAR; yeni somut P1/P2 bulunmadı. Root aynı üretim farkını ayrıca inceleyebilir.

Son line coverage: `server_plugins_screen.dart` **449/460 = %97,61**. Bu satır kapsamıdır; branch veya tüm uygulama kapsamı iddiası değildir. Son analiz **3 item / 0 issue**; format **3 dosya / 0 değişiklik**. Tüm SDK komutları `/private/tmp/larenor-flutter-check.py` ile serialize edildi, son süreçler exit 0 ile toplandı.

Özel kanıtlar:

- `/private/tmp/larenor-plugins-tablet-red-verified.log`
- `/private/tmp/larenor-plugins-tablet-red-leaf-baseline.log`
- `/private/tmp/larenor-plugins-tablet-tab-viewport.log`
- `/private/tmp/larenor-plugins-tablet-visible-offset-red.log`
- `/private/tmp/larenor-plugins-tablet-related-final.log`
- `/private/tmp/larenor-plugins-tablet-coverage-final.info`
- `/private/tmp/larenor-plugins-tablet-analyze-final.log`
- `/private/tmp/larenor-plugins-tablet-format-final.log`
- `/private/tmp/larenor-core-plugins-tablet-delivery-evidence.json`

## Özel görsel kontrol ve sınır

Aynı test matrisinde gerçek bundled Inter ve CupertinoIcons ile üretilip `view_image` ile incelenen son PNG'ler:

- `/private/tmp/larenor-plugins-tablet-preview/plugins-tr-dark-600-2x.png`
- `/private/tmp/larenor-plugins-tablet-preview/plugins-en-light-1280-2x.png`
- `/private/tmp/larenor-plugins-tablet-preview/plugins-en-light-600-2x.png`
- `/private/tmp/larenor-plugins-tablet-preview/plugins-tr-dark-1280-2x.png`

Son görüntülerde odak halkasının tamamı görünür, katalog metni genişliğe göre satırlanır. Kaydırılmış sayfanın başka bir satırının ekran dışında olması normaldir; odaklı eylem ayrıca gerçek Tab testiyle kontrol edilir. İlk, kırpılmış halkalı PNG'ler nihai kanıt değildir. Çıktılar özel QA içindir; README galerisi, tüm uygulama tasarımı, tüm yazı boyutlarında kontrast, TalkBack veya fiziksel tablet/DeX kabulü değildir. Boyanan odak halkası hem gerçek canvas hem kart zemini karşısında en az 3:1 olarak test edilir; eski açık tema değeri 1,751:1 idi.

Bu dalda push, CI, emülatör/cihaz kurulumu veya gerçek Server/ev/HA/Docker erişimi yapılmadı. `installAvailable=false` ve mevcut kurulum engelleri değişmez. Bu kanıt önceki yayın paketlerinin CI/APK sonuçlarına eklenemez; birleştirme ve yeni paket kabulü ayrıdır.
