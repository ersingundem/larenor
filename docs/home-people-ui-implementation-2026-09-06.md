# Core kişi profilleri: açık giriş, yönetim ve erişim ekranları

Bu yerel teslim, mevcut kişi modeli/API ve controller katmanını gerçek uygulama ekranlarına bağlar. Kişi profilleri evin metadata kayıtlarıdır; giriş hesabı veya Home Assistant kişisi değildir. Android uygulamasındaki bu teslim, S08.6'nın tamamı veya fiziksel tablet/Android CI kabulü değildir.

- Dal: `codex/home-people-ui`
- İzole çalışma ağacı: `/private/tmp/larenor-home-people-ui`
- Başlangıç: `634bc10f22241a49f776e954735746eee8a0f8b0`
- Son kaynak: `407e1b34340d069ec1c65e6eda5f9cdde4e0bf46` (davranış `3bc69e8`; yalnız eklenen gate koşullarında format).
- İlk UI RED `26a74c6`: derlenen gerçek widget testlerinde 0 PASS / 5 FAIL; açık giriş henüz yoktu. GREEN `c2baaa6`: 5 PASS.
- Yaşam döngüsü RED `6509013`: 25 PASS / 5 FAIL. Desteklenen pencere politikası kapalıyken tutulmuş giriş callback'i route açabiliyordu; örtülü sayfanın fallback geri callback'i üstteki route'u kapatabiliyordu. GREEN `110d76f`: 35 PASS.
- Görünür odak RED `0ac9b98`: gerçek klavye odağında geri düğmesinin 3,5 px dış çizgisi pencerenin solunda kesiliyordu (`left=-3.5`, 1 FAIL). GREEN `3bc69e8`: başlık içindeki 4 px yerel boşluk ve 55 PASS. Diğer üretim farkları blok parantezleridir.

## Uygulamadaki yol

`CoreHomeStatusScreen` içindeki `HomePeopleEntry`, kişi API'sini yalnız açıkça seçildiğinde başlatır. Ana ekranın bağlanması tek başına kişi isteği üretmez. Üye listesi, mevcut oturumla okunabilen profilleri gösterir. Bir yazma izni yönetici rolü anlamına gelmez: metadata oluşturma, ad/sıra değiştirme, silme ve erişim düzenleme mevcut yönetici rolünü ve `SettingsGateDestination.homePeople` PIN kapısını gerektirir.

Kişi listesi ve ayrı erişim route'u farklı `HomePeopleOwner` nesneleri kullanır. Alt route açılınca önceki owner emekliye ayrılır; dönüşte yeni owner ve yeni GET gerekir. Kaynak, hesap, home runtime/epoch veya ProviderContainer değişimi eski handle'ı canlandırmaz. Aynı State/GlobalKey ekranı, aynı hesap/home nesnelerini paylaşan B container'a taşırken A container'ı canlı tutan gerçek widget testleri hem tutulmuş save hem geç 401 sınırını doğrular.

`HomePeopleRoute`, mevcut home/account sahipliği ile route, TickerMode, uygulama yaşam döngüsü, gerçek view focus, window policy ve dış PIN kapısını birlikte denetler. Etkileşim kaybında form alt ağacı ve seçimler bırakılır. Giriş düğmesi ayrıca pencere politikası yükleniyor/hata/focus/PiP/paused durumlarını ve policy epoch'unu denetler. Tutulmuş callback, pencere yeniden etkin olsa bile yeniden yetki kazanmaz.

Silme ve erişim kaldırma, seçilen kişi/hesabı adlandıran satır içi onayla yapılır. Eski Save veya onay callback'i yeni onaya dönüşemez; iptal sıfır HTTP yazısı üretir. Belirsiz yazı sonucunda otomatik POST/PATCH/DELETE/PUT tekrarı veya otomatik uzaktan okuma yoktur; kullanıcı açıkça yeniler. Liste sayfalaması mevcut ID cursor/snapshot sözleşmesini ve 128 kayıt üst sınırını kullanır. Görünür kopya order→ID ile sıralanır; mutation sonrası eski sayfa snapshot'ı kullanılmaz ve tam yenileme görünür kalır.

## Kaynak sınırı

Yeni dört dosya `lib/features/home_people/presentation/` altındadır: `home_people_route.dart`, `home_people_screen.dart`, `home_people_widgets.dart`, `home_person_grants_screen.dart`. Ortak değişimler yalnız Core ana ekranına giriş, SettingsGate'e ayrı `homePeople` dalı/PIN invalidation koşulları ve `homePeople*` EN/TR metinleridir. `homeSource`/arşiv dalına, account/controller/model/API/transport, router, global tema, HA sağlayıcıları veya yedekleme kaynaklarına dokunulmadı. Son gate format farkı yalnız eklenen kişi koşullarındaki üç satırın kırılımıdır.

API ve controller katmanları bu teslimin önceden dondurulmuş bağımlılıklarıdır. UI testleri controller taklidi kullanmaz: gerçek `HomeSessionScope` + `LarenorApp`, `SettingsGateScreen`, `ServerAccountController`, typed kişi controller'ları ve mevcut bounded HTTP transport sentetik `MockClient` yanıtlarıyla çalışır. Kişi kayıt şekilleri gerçek Server HTTP sözleşme fixture'ından alınır. Core testlerinde HA bağlantı provider’ı/REST/WS fabrikaları çağrıldığında hata veren sayaçlarla sıfır fallback doğrulanır. Canlı endpoint, ev/router/Docker veya cihaz üzerinde işlem yapılmadı.

## Yerel kanıt

- Son yeni UI testleri: **55 PASS**; `/private/tmp/larenor-people-ui-final-focused-green.log`.
- Dört yeni ekran dosyasında satır kapsamı **597/620 = %96,29**: liste 284/291, route 108/117, ortak UI 51/51, erişim ekranı 154/161. `/private/tmp/larenor-people-ui-final-coverage.info`. Bu branch coverage iddiası değildir.
- İlgili regresyon: **608 PASS / 32 s**, kişi + kaynak UI/controller, SettingsGate/IdleGate, gerçek HomeSession runtime ve ServerConnection testleri. `/private/tmp/larenor-people-ui-related.log`. 55 yeni test bu sayıya dahildir; sayılar toplanmaz.
- Analyzer: **9 analiz girdisi, 12 Dart dosyası, 0 sorun**, `/private/tmp/larenor-people-ui-analyze-final.log`. Format **12 dosya, 0 değişiklik**, `/private/tmp/larenor-people-ui-format-final.log`.
- Özel görsel üretimi: **4 PASS**, `/private/tmp/larenor-people-ui-preview.log`; 8 PNG, bunlardan 5’i uygulama görüntüsü olarak doğrudan incelendi.

55 test; üye/yönetici ayrımı, gerçek PIN, oluşturma/ad/sıra/silme, ayrı ACL okuma/yazma/kaldırma, iki belirsiz yazıdan açık GET ile toparlanma, snapshot sayfalaması ve mutation sonrası tam yenileme, aktif 401'in hesabı reddetmesi ile emekliye ayrılmış/expired 401'in hesabı düşürmemesini kapsar. Kaynak, logout, rol, PIN loading/rotation/read failure, root route, native view focus, pencere politikası ve background kaybında form/late-ACK sınırları; root PIN geri dönüşü ve ayrı owner ile child-pop taze okuması gerçek ekran üzerinden doğrulanır.

Tablet testleri EN/TR × 320/600/1280 × açık/koyu, 2× metin ölçeğinde bundled Inter ve CupertinoIcons kullanır. Tek button semantics etiketi, başlığın ayrı header olması, 48 px hedef, Tab/Shift-Tab, Enter/Space, sıfır etkili silme/kaldırma iptali, seçili izin semantics'i ve görünür focus çizgisi (kontrast ≥3:1, çizgi genişliği >0) denetlenir. Lazy satırlara test helper'ı sonlu gerçek scroll ile ulaşır; widget yokken `ensureVisible` çağrısı üretim arızası sayılmadı. 80 emoji sözleşme kaydı kayıpsız metin/yerleşim sınırını sınar; bütün emoji glyph/fallback fontlarının doğrulandığı iddia edilmez.

Özel PNG'ler `/private/tmp/larenor-people-ui-previews/` altındadır; gerçek ekranların EN 1280 açık, TR 320/600 koyu ve TR 1280 açık 2× örnekleridir. Bunlar ara QA görselleridir; README son galerisi veya genel frontend/cihaz kabulü değildir. Root `3bc69e8` üretim farkı ve önceki yaşam döngüsü düzeltmelerinin bağımsız kaynak incelemesini CLEAR olarak bildirdi; TR600 koyu ve EN1280 açık erişim/izin görüntüleri ile TR1280 açık listeyi ayrıca inceledi. Bu 2× büyük metin/focus kontrolü tüm uygulamanın varsayılan 17 px tint AA kabulü değildir; genel B5/son tasarım kabulü ayrıdır. Son teslim makbuzu `/private/tmp/larenor-home-people-ui-delivery-evidence.json` içindedir.

## E2E entegrasyon noktaları

Açık giriş `home-people-entry`; liste `home-people-list`; durumlar `home-people-empty`, `home-people-loading`, `home-people-error`; işlemler `home-people-refresh`, `home-people-load-more`, `home-people-back`; satırlar `home-people-row-<id>`. Yönetim `home-people-admin`, ayrı erişim `home-person-grants-screen`. Bu dal mevcut Android journey/fixture/marker/CI dosyalarını değiştirmez ve Android çalıştırmış değildir. Yeni member/admin Android yolculuğu ve bütün S08.6 kabulü sonraki ayrı kanıttır.
