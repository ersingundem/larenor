# Core kaynak erişimi: dokuzuncu Android yolculuğu

Bu dilim yalnız test altyapısıdır. İncelenmiş ACL UI kaynağı `9492bdb`, UI
paketi `ab678df` ve sekizinci yolculuk paketi `0d29755` üzerine eklendi.
Bağımlılıkları birleştiren checkpoint `37f9847`, son test kaynağı `26c38ff`dir.
Üretim Client/Server kodu, sözleşme JSON'u, workflow ve test runner değişmedi.
Yeni yolculuk Android üzerinde henüz çalıştırılmadı; yerel HTTP testleri ve
analyzer sonucu Android veya fiziksel cihaz kabulü değildir.

## Gerçek UI yolu ve korunmuş sınırlar

`AppHarness.start(connected: true, coreSource: true, coreResourceGrants: true)`
açık, yalnız test için kullanılan seçenektir. `LARENOR_E2E=true` zorunludur.
ACL seçeneği Core olmadan ya da mevcut metadata/member fixture seçenekleriyle
birlikte seçilemez. Eski sekiz yolculuğun kaynak metni ve 76 aşama işareti
`0d29755` ile otomatik karşılaştırıldı ve aynı kaldı. Yeni 13 işaretle toplam
**9 uygulama yolculuğu / 89 aşama işareti** vardır. Mevcut dört platform testi
değişmedi; sonraki Android çalışmasının toplam hedefi 13 testtir.

Dokuzuncu yolculuk gerçek widget ve HTTP taşıması üzerinden şunları uygular:

1. Core hesabı yokken yönetim eylemi görünmez; gerçek PIN kapısından hesap
   ekranına girilir, loopback hesabıyla giriş yapılır ve Core bağlamı okunur.
2. Metadata yönetimi için PIN yeniden açılır; sabit kaydın Erişim yönetimi
   bağlantısı kullanılır. Gerçek users GET yanıtındaki `person_3` seçilir;
   elle subject ID alanı yoktur, ilk seçim yalnız okuma yetkisidir.
3. Yalnız okuma ve ardından okuma/yazma açık Save eylemleriyle kaydedilir.
   UI sonucu, izinler, ACL revision ve HTTP PUT sayısı birlikte doğrulanır.
4. Bir PUT etkisi tamamlandıktan sonra fixture tek kez 503 döndürür. UI belirsiz
   sonucu gösterir ve eski kullanıcı seçimlerini kaldırır. Yalnız açık Yenile
   ile GET yapılır; PUT yeniden gönderilmez ve kaydedilmiş izin okunur.
5. Yetki kaldırma önerisi iptal edilir; izin ve PUT sayısı aynı kalır. Ayrı yeni
   önerinin açık onay düğmesiyle izin kaldırılır.
6. Metadata ekranına dönülüp Erişim yönetimi yeniden açılır. Yeni grants GET
   sonrası boş ACL, güncel revision ve değişmeyen PUT sayısı doğrulanır.

Her tıklama etkin `CupertinoButton.onPressed` durumunu bekler; üretim
callback'leri doğrudan çağrılmaz ve PIN/login adımları test callback'iyle
atlanmaz. Aşama işaretleri statiktir; kullanıcı adı, parola, token veya yanıt
gövdesi yazdırılmaz. HA HTTP/WS, abonelik, WS client üretimi ve cihaz eylemi
sayaçlarının sıfır kaldığı ayrıca kontrol edilir.

## Dar opt-in HTTP fixture

`SyntheticCoreResourceGrants`, mevcut `SyntheticCoreAccount` içinde açıkça
seçilir. Varsayılan hesap, read-only member ve metadata fixture modları aynı
kalır. Fixture tek sabit kaynak ve üç sentetik mevcut hesap taşır; metadata,
provider, cihaz komutu veya geniş bir Core motoru uygulamaz.

Uçlar named users GET, grants GET/PUT ve mevcut sabit kaydın liste/tek kayıt
GET işlemleriyle sınırlıdır. Kullanıcı listesi ve ACL uçları admin ister;
member yalnız kendi mevcut read grant'iyle kaydı okuyabilir. Yetkisiz ve
bulunmayan kayıt aynı 404 sonucunu verir. `read=false, write=false` grant'i
kaldırır, write/read bağımlılığı ve no-op ACL revision davranışı korunur.

Her ACL oturumu ayrı token alır. Eksik, tekrarlı, yanlış veya önceki token;
logout; actor/rol/ilk parola durumu değişimi ve Core/home uyuşmazlığı reddedilir.
Auth ve yakalanmış Core/home bağı, gövde tamamen okunduktan sonra yeniden
kontrol edilir. Etki sonrası yanıt bekletilirken oturum iptal edilirse geç
yanıt 401 olur; gerçekleşmiş etki geri alınmaz ve ikinci PUT üretilmez.

JSON gövdesi en çok 4096 byte, stream idle beklemesi iki saniyedir. Alanlar ve
tipler kapalıdır; tekrarlanan ve Unicode escape ile gizlenen aynı JSON anahtarı,
yanlış scalar, ek secret alanı, yanlış content type, query ve yöntem reddedilir.
Reply gate en çok üç saniye bekler ve harness temizliği kapıyı serbest bırakır.
Gövde başlangıcı latch'i yalnız sentetik host testi gözlemidir; yetki sağlamaz.

Fixture verisi yalnız bellektedir. Sentetik liste snapshot'ı SHA256 kullanır;
üretim HMAC'i, kalıcı Server transaction veya yeniden başlatma dayanıklılığı
kanıtı değildir. Döndürülen grant gözlemi tipli, iç içe değiştirilemez bir
kopyadır. Gerçek ağ sınırı değiştirilmedi: FixtureNetwork yalnız bu testin
IPv4 loopback adresine ve tam portuna izin verir.

Kayıp ACK yalnız açık fault düğmesinden, başarılı etki ve son auth kontrolünden
sonra oluşturulan tipli `GrantsReply.lostAcknowledgement` yanıtıyla işaretlenir.
Bu işaret status/body'den türetilmez; diğer 503, 401 ve protokol hataları normal
reddedilen istek olarak sayılır. Yolculuk fault sonrasında ve sonunda gerçek
`rejectedRequests=0`, `injectedAckLosses=1` bekler. Global AppHarness.close
reddedilen istek/harici hedef kontrollerinin metni eski kaynakla birebir aynıdır.
Host testleri gerçek close'ı kullanır; özel `forSyntheticCleanup` örneği yalnız
sentetik server/ağ temizler ve mount çağrısını açıkça reddeder. Normal start'ın
E2E bayrağı, storage ve mount akışı değişmez.

`home_resource_grants_contract_fixture.dart`, gerçek
`contracts/home-resource-grants.v1.json` dosyasının birebir JSON companion'ıdır.
Host testi kopyayı actual dosyayla karşılaştırır ve gerçek loopback yanıtlarını
empty, readOnly, no-op, secondReadWrite, sorted, upgrade, revoke, revokeNoop,
afterRevoke, stale ve writeRequiresRead örnekleriyle eşleştirir. Named users
yanıtı mevcut Client admin-user modelinin alanlarını kullanır.

## RED → GREEN ve son yerel doğrulama

| Checkpoint | Gerçek sonuç ve kapsam |
| --- | --- |
| `c6eacb2` RED | 1 geçti / 2 başarısız. Henüz uygulanmamış users/grants HTTP uçları beklenen 200 yerine 403 verdi; derleme hatası değildi. |
| `c2b703d` GREEN | Yeni 3 sözleşme/HTTP testi + mevcut 30 metadata testi: 33 geçti. |
| `ecd567b` RED | 23 authority testinde 22 geçti / 1 başarısız. Etki sonrası bekletilen yanıt logout sonrasında yanlışlıkla 200 döndü. |
| `08a97da` GREEN | Yanıt öncesi güncel auth kontrolü; gerçekleşmiş etki korunur. 3 sözleşme + 23 authority + 30 metadata: 56 geçti. |
| `380f512` RED | 7 streamed-body testinde 4 geçti / 3 başarısız. Core/home değişimi eski isteği reddetmiyordu; pozitif vaka ayrıca tiplenmemiş immutable map gözlem hatasını yakaladı. |
| `1dd8e61` GREEN | Gövde sonrası context bağı ve tipli gözlem düzeltildi. 3 sözleşme + 23 authority + 7 streamed-body + 30 metadata: 63 geçti. |
| `f4c8e06` ara GREEN | Format/braces sonrası bütün `test/integration_support`: 81 geçti, yaklaşık 3 saniye. Bu koşu AppHarness.close'ı çalıştırmadığı için sonraki cleanup bulgusunu yakalamadı. |
| `0d4a14f` cleanup RED | 4 gerçek cleanup testinde 3 geçti / 1 başarısız. Kasıtlı ACK kaybı generic rejectedRequests sayıldığı için gerçek close 0 yerine 1 buldu. |
| `0625278` cleanup GREEN | İstek bazlı tipli fault ayrımıyla 4 geçti. Beklenmeyen503 ve açık fault sonrası401 yine close'ı reddeder; cleanup-only mount reddi korunur. |
| `26c38ff` final | Bütün `test/integration_support`: 85 geçti, yaklaşık 4 saniye; analyzer 9 dosyada 0 bulgu, format 9 dosyada 0 değişiklik. |

**85 test**, önceki 18 network/account/member testi, 30 metadata testi ve yeni
37 grants testinden oluşur. 37 grants testi dört dosyaya ayrılır:

- `synthetic_core_resource_grants_test.dart`: 3 sözleşme ve HTTP akışı.
- `synthetic_core_resource_grants_authority_test.dart`: 23 auth, ACL, bounded
  body, stale revision, kayıp/geç ACK ve açık GET recovery denetimi.
- `synthetic_core_resource_grants_stream_test.dart`: 7 gerçek parçalı HTTP
  gövdesi sırasında none/Core/home/actor/role/logout/password değişimi denetimi.
- `synthetic_core_resource_grants_cleanup_test.dart`: 4 gerçek AppHarness
  cleanup, açık fault/beklenmeyen503/401 ayrımı ve mount reddi denetimi.

33, 56, 63 ve 81 testlik koşular son 85 testin alt kümeleridir; toplanmaz.
`server/tests/test_home_resource_grants_contract.py` gerçek FastAPI/SQLite
sözleşme üretim testi ayrıca **2 geçti**. Server kodu veya fixture JSON'u
değiştirilmedi. SDK komutları ortak kilitli wrapper üzerinden çalıştırıldı:

```text
python3 /private/tmp/larenor-flutter-check.py flutter test test/integration_support --reporter expanded
python3 /private/tmp/larenor-flutter-check.py flutter analyze <9 owned Dart files>
python3 /private/tmp/larenor-flutter-check.py dart format --output=none --set-exit-if-changed <9 owned Dart files>
PYTHONPATH=server /private/tmp/larenor-server-project-env/bin/python -m pytest server/tests/test_home_resource_grants_contract.py -q
```

Standart Flutter LCOV bu `integration_test/support` dosyalarını toplamıyor;
fixture için coverage yüzdesi bildirilmez. Önceki UI paketinin 52 hedef testi
ve coverage sonucu bu dilimin yeni test sayısına katılmaz. İlk authority
denemesinde JSON map'i Dart record eşitliğiyle karşılaştıran matcher ve ilk
stream denemesinde FixtureNetwork tarafından uygulanmayan `putUrl` kullanımı
test hazırlığı hatalarıydı; RED kanıtı olarak sayılmadı. Ağ guard'ı gevşetilmedi.
İlk cleanup negatif testindeki aynı anda pumpWidget ve expectLater kullanımı
test guard çakışmasıydı; await/catch ile düzeltilip gerçek 3/1 RED ayrı koşuldu.

Root kaynak incelemesi opt-in account dispatch, etkin Cupertino beklemeleri,
streamed-body context kontrolü, tipli grant gözlemi ve geç ACK iptalinde açık
P1/P2 bulmadı. İkinci bağımsız inceleme gerçek cleanup P2'sini yakaladı; yukarıdaki
RED/GREEN düzeltmesi sonrası `0625278` davranışına CLEAR verdi. Bu inceleme ve
yerel yeşil testler, sonraki birleşik exact source
için Android CI kabulünün yerine geçmez. Bu görevde main/push/CI başlatma,
APK kurulumu, gerçek Core veya ev cihazı işlemi yapılmadı.

Yerel kanıt dosyaları depoya eklenmez:

- `/private/tmp/larenor-grants-e2e-runtime-red.log`
- `/private/tmp/larenor-grants-e2e-authority-runtime-red.log`
- `/private/tmp/larenor-grants-e2e-stream-runtime-red.log`
- `/private/tmp/larenor-grants-e2e-cleanup-runtime-red.log`
- `/private/tmp/larenor-grants-e2e-cleanup-green.log`
- `/private/tmp/larenor-grants-e2e-entire-support-final.log`
- `/private/tmp/larenor-grants-e2e-server-contract.log`
- `/private/tmp/larenor-grants-e2e-analyze-final.log`
- `/private/tmp/larenor-grants-e2e-format-final.log`
- `/private/tmp/larenor-grants-e2e-preservation.json`
- `/private/tmp/larenor-core-resource-grants-e2e-delivery-evidence.json`
