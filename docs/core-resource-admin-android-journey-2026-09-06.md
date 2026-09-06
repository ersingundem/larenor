# Core kaynak yönetimi: sekizinci Android yolculuğu

Bu dilim yalnız test altyapısıdır. İncelenmiş yönetici UI kaynağı
`68e77b81c01f01aad496de9d116b322592f757a1` üzerinde gerçek hesap ekranı,
HomeSessionScope, PIN kapısı, Client API, HTTP taşıması ve yönetim ekranını
birlikte çalıştıracak **sekizinci uygulama yolculuğu** eklendi. Android üzerinde
henüz çalıştırılmadı; aşağıdaki yerel kanıtlar Android kabulü değildir.

## Sınır ve yolculuk

`AppHarness.start(coreSource: true, coreResourceAdmin: true)` ayrı ve açık bir
test seçeneğidir. `LARENOR_E2E=true` olmadan harness başlatılmaz. Yönetici fixture
ile mevcut üye fixture aynı anda seçilemez; yeni seçenek Core kaynağı olmadan
kullanılamaz. Var olan yedi yolculuğun kaynak metni ve 65 aşama işareti aynen
korundu. Yeni 11 işaretle uygulama toplamı **8 yolculuk / 76 işaret** oldu.
Mevcut dört platform testi değişmedi; sonraki Android çalışmasının toplam hedefi
12 testtir. Runner zaten integration_test dizinini keşfeder; sabit bir aşama
kataloğu bulunmadığından araç, timeout veya CI workflow değiştirilmedi.

Yeni yolculuk şunları doğrular:

1. Core hesabına gerçek HTTP oturumu ile giriş ve yönetim bağlantısının görünmesi.
2. Yanlış PIN ile yönetimin açılmaması ve metadata yazımının sıfır kalması.
3. Doğru PIN sonrası etkin oluşturma düğmesini ve yüklenmiş veriyi bekleme.
4. Bir oda oluşturma; görünür etiket, sıra, revision ve ACL revision doğrulama.
5. Aynı kaydın adını ve sırasını değiştirme; eski etiketin kaybolması.
6. Silme onayını iptal etme; kayıt ve yazım sayacının değişmemesi.
7. Ayrı silme onayı; 204 yanıt sonrası UI ve fixture kaydının silinmesi.
8. Ana listeye dönme; otomatik dönüş okumasının bitmesini bekleyip sayaç tabanı
   alma ve **ayrı kullanıcı yenilemesi** ile boş listeyi yeniden okuma.
9. Eski Direct dashboard kaydının değişmemesi; HA HTTP/WS, abonelik, istemci
   üretimi ve cihaz eylemlerinin sıfır kalması; harness temizliği.

Düğmeler yalnız bulunarak tıklanmaz: gerçek CupertinoButton.onPressed etkinliği
beklenir. Başarı aşamaları UI sonucu ile eşleşen fixture kaydı/yazım sayacı
sonrasında basılır. Core→PIN→metadata akışı test callback'leriyle atlanmaz.
Ağ sınırı mevcut FixtureNetwork aracılığıyla yalnız bu testin IPv4 loopback
adresine ve tam portuna izin verir. Gerçek Core, HA, medya, Docker veya ev
cihazına erişim yoktur. Preferences/secure storage sentetiktir; bu test fiziksel
cihaz depolaması veya Android süreç yeniden başlatma kanıtı değildir.

## Yönetici loopback protokolü

Yeni `SyntheticCoreResourceAdmin`, yalnız `SyntheticCoreAccount` içinde açıkça
seçilince kullanılır. Tam bearer oturumu, tek Authorization başlığı, admin rolü
ve actual sözleşmedeki Core/home kimliği doğrulanır. Varsayılan hesap ve mevcut
üye/read-only fixture yönetici yazımlarını hâlâ reddeder.

İzin verilen uçlar GET liste/tek kayıt, POST create, PATCH label/order ve DELETE
expectedRevision+expectedAclRevision ile sınırlıdır. Cihaz eylemi, ACL değişim
uçları, keyfi provider veya ağ yolu yoktur. JSON gövdesi 4096 byte ile sınırlı,
stream idle beklemesi iki saniyedir; bilinmeyen/tekrarlanan alanlar (escaped aynı
JSON anahtarı dahil), yanlış scalar tipleri, query tekrarları ve stale revision
reddedilir. Saf mevcut HomeResourceMetadata doğrulaması label/order için
kullanılır. Fixture en çok 32 geçici kayıt taşır; bu sınır gerçek Server kapasite
sözleşmesi değildir. Test ID'leri deterministiktir.

Liste sayfalaması Core/home/actor ve güncel kayıt içeriğine bağlı sentetik SHA256
snapshot kullanır. Bu değer üretim HMAC'i veya yetki kanıtı değildir. Tam kayıt
ve response kopyaları fixture'ın değişebilir iç durumunu dışarı vermez. İsteğe
bağlı response gate, tek başarılı in-memory effect sonrasında yanıtı bekletir;
üç saniyelik yanıt zaman aşımı yazımı geri almaz veya yeniden denemez. Bu,
gerçek Server DB dayanıklılığına dair bir iddia değildir.

`home_resource_admin_contract_fixture.dart`, mevcut
`contracts/home-resource-admin.v1.json` dosyasının JSON olarak birebir
karşılaştırılan test companion'ıdır. Gerçek loopback üzerinden createRoom,
createResource, updateRoom, no-op ve delete başarılı yanıtları actual Server
fixture'ıyla tam eşleştirilir. Stale/deleted/error örneklerinde status ve sabit
error code karşılaştırılır; test fixture üretim hata mesajlarını taklit etmez.
Actual sözleşme JSON'u değiştirilmedi.

## Kanıt ve inceleme

- Runtime RED `65e1b80`: **2 geçti / 4 başarısız**. Güvenli henüz uygulanmamış
  fixture admin yollarını 403 ile reddediyordu; import/derleme hatası değildi.
- Minimal GREEN `2c910c7`: **6 geçti**. İlk GREEN denemesinin 5/1 sonucu yanlış
  scope'un 403 dönmesini yakaladı; 404 düzeltmesi sonrası ayrı log yeşil oldu.
- Geniş fixture: **30 geçti**. Duplicate JSON/query, auth/scope/role, UTF8/body
  sınırı, kapalı method/alanlar, snapshot paging, gecikmiş ACK, yanıt kaybında
  effect'in korunması ve kayıt sınırı dahil.
- Son kaynak `38ef649`: yeni 30 test + mevcut 13 account/member testi,
  **43 geçti**, yaklaşık 3 saniye; altı dosyada analyzer **0 bulgu**.
- İlk geniş test denemesinde Dart record içindeki JSON map için yanlış eşitlik
  matcher'ı ve GET body için eksik Content-Length vardı. Bunlar test harness
  hatalarıydı; üretim/runtime RED kanıtı olarak sayılmadı.
- Standart Flutter LCOV yalnız lib altını topladığı için yeni integration_test
  fixture yüzdesi raporlanmıyor. Ayrı /private/tmp package alias denemesi
  package-graph/pubspec/native-assets hazırlığında durdu; kaynak/test runner
  değişmedi, bu deneme ek başarılı test veya coverage kanıtı sayılmıyor.
- Root bağımsız incelemesindeki create/refresh etkinlik yarışı waitEnabled ile
  düzeltildi. İkinci bağımsız kaynak incelemesi de açık P1/P2 bulmadı.
- SDK komutları ortak `/private/tmp/larenor-flutter-check.py` kilidi üzerinden
  çalıştırıldı. Main/push, gerçek cihaz ve CI çalıştırması yapılmadı.

Yerel loglar (depoya eklenmez):

- `/private/tmp/larenor-admin-e2e-fixture-red.log`
- `/private/tmp/larenor-admin-e2e-fixture-minimal-green.log`
- `/private/tmp/larenor-admin-e2e-fixture-expanded-corrected.log`
- `/private/tmp/larenor-admin-e2e-fixture-final.log`
- `/private/tmp/larenor-admin-e2e-analyze-final.log`
- `/private/tmp/larenor-admin-e2e-format-final.log`

Önceki APK99 / `4bc79dc` CI sonucu mevcut yedi yolculuğa aittir. Bu sekizinci
yolculuk için yalnız birleşmiş yeni kaynağın Android CI sonucu kabul kanıtı
olabilir; bu belge o sonucun yerine geçmez.
