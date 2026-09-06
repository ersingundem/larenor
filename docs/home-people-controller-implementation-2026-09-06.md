# Core kişi controller ve provider dilimi

Bu teslim kişi model/HTTP sözleşmesini güncel Core hesabına ve tek ekran ömrüne bağlar. Liste/sayfalama, yönetici metadata CRUD ve kişi ACL durumunu taşır. Kişi ekranı, SettingsGate/PIN ekran bağlantısı ve Android yolculuğu bu teslimde yoktur. S08.6 veya ürün kabulünün tamamlandığı anlamına gelmez.

Çalışma ağacı `/private/tmp/larenor-home-people-controller`, dal `codex/home-people-controller`, taban `2b550c7a8608e67210b85ee245714912a35b843f`. Üretim/test son kaynak `d0d03ae`; ilk davranış GREEN `051c67d`. Paylaşılan hesap/home/restore/transport, eski room/resource modelleri, Server ve integration_test kaynakları değişmedi.

## Üretim sınırı

- `home_people_controller.dart`: görünür kişi listesi, opak snapshot/cursor, en fazla 128 kayıt; açık yenileme; tek uçuşlu metadata oluşturma/güncelleme/silme. Güncelleme/silme yalnız controller'ın mevcut okumasından seçilmiş aynı immutable kayıt nesnesini kabul eder. Başarılı yazı eski sayfalama snapshot'ını ve cursor'u kaldırır; tam liste yenilemesi açıktır. Yanıt kaybı/bozuk ACK belirsiz sonuç olur, kayıtlar temizlenir ve yeni yazıdan önce açık GET gerekir. Otomatik yazı tekrarı yoktur.
- `home_person_grants_controller.dart`: tek kişi hedefi, gerçek yönetici kullanıcı kataloğu ve kişi ACL GET; yalnız bu okumadan seçilmiş kullanıcı nesnesiyle PUT. `canWrite` hesap rolünü değiştirmez: metadata ve ACL yönetimi `canAdminister` gerektirir. ACL'nin gözlenen en yüksek revision'ı başarısız GET sonrasında da korunur. Belirsiz PUT sonrasında kullanıcılar/ACL temizlenir; yalnız açık kullanıcı+ACL GET ile devam edilir.
- `home_people_providers.dart`: ekran başına autoDispose family ve tek bağlamaya sahip `HomePeopleOwner`. Provider ref ömrü, yakalanmış HomeSession nesnesi, runtime kimliği, home interaction epoch'u ve account generation tekrar doğrulanır. Aynı owner başka provider/container'a verilirse kalıcı olarak emekliye ayrılır. Kaybolmuş/patlayan ekran kontrolü veya interaction epoch değişimi eski owner'ı tekrar canlandırmaz.

Her işlem gerçek `ServerAccountController.withSession` ve mevcut bounded `HomePeopleApi` üzerinden gider; feature'ın ayrı transport'u kapanır, hesap transport'u kapatılmaz. İlk görünürlükte okuma başlar; aynı doğrulanmış bağlamda token yenilemesinin kendi context GET'i iptal edilmez. Pending/expired auth sırasında metadata gösterilmez. Eski pencere/route/oturum yanıtı ve geç 401, shared account hata işleyicisine ulaşmadan iptal edilir. Aktif/geçerli isteğin 401'i hesabı hâlâ reddeder. Kapanmış callback, daha önce gönderilmiş bir Server yazısını geri alamaz; bu dilim geri alma garantisi üretmez.

Kalıcı kişi cache'i, Direct HA kimlik bilgisi okuması veya HA fallback yoktur. API'ler yalnız sentetik HTTP istemcileriyle denendi; gerçek ev/Server/cihaz bağlantısı kurulmadı.

## Sonraki ekran için bağlama sözleşmesi

Üye liste route'u `homePeopleControllerProvider((owner: owner, adminManagement: false, pageSize: 25))` kullanır. PIN korumalı yönetim route'u ayrı owner ile `adminManagement: true`; her kişi ACL route'u yine ayrı owner ile `homePersonGrantsControllerProvider((owner: owner, target: selected))` kullanır. Liste owner'ı ACL provider'ına devredilmez.

Owner callback'i ekranın yakalanmış container, güncel route, native pencere/foreground, SettingsGate/PIN ve idle epoch kontrollerini taşımalıdır. Bu değişimlerde `owner.synchronize()` çağrılır; owner çıkışta kapatılır. Geri gelen ekran yeni owner oluşturur. Controller bir `ChangeNotifier` olarak dinlenir; provider nesnesinin kendisi ekranı otomatik yeniden çizmez. İlk görünür frame'de `setVisible(true)` çağrılır. Form/confirmation callback'leri kendi yakalanmış controller epoch ve modal/form generation'larını `isCurrent` ile yeniden denetler.

Kişi route'una açık giriş eklenmesi sonraki iş: Core ana ekranının her mount'unda otomatik kişi GET eklenmez. Gerçek PIN/native focus kullanıcı akışı, tablet EN/TR/2x semantik düzeni ve E2E bu controller test host'u ile tamamlanmış sayılmaz.

## TDD ve doğrulama

| Kanıt | Sonuç |
|---|---|
| `38fe82f` runtime RED | 3 PASS / 27 beklenen davranış FAIL; derlenebilir controller stub'ları |
| `051c67d` ilk GREEN | 30 PASS |
| Son kişi paketi | 135 PASS: 58 yeni controller/provider + 77 önceki model/adapter |
| Test-only biçim düzeltmesi sonrası yeni testler | 58 PASS |
| İlgili mevcut room/resource, Server account ve HomeSession regresyonları | 418 PASS |
| Scoped analyzer | 7 dosya, 0 sorun |
| Scoped formatter | 7 dosya, 0 değişiklik |
| Yeni üretim satır kapsamı | 470/478 = %98,33; branch kapsamı iddiası yok |

Satır kapsamı: kişi controller 242/246, kişi ACL controller 170/172, provider/owner 58/60. Varsayılan gerçek HTTP factory'sini sırf kapsam artırmak için çalıştırmadık.

Yeni runtime testleri gerçek mounted Consumer ve ProviderContainer, gerçek ServerAccountController/HomeSessionController, sentetik account API/persistence ve gerçek bounded kişi HTTP adapter'ını kullanır. Aynı GlobalKey State'i A container canlı kalırken B'ye taşınır; eski ve yeni controller aynı eski owner ile istek başlatamaz. Gerçek Navigator route örtülmesi sırasında geç 401 ve pop sonrası eski owner'ın uyanmaması ayrıca doğrulanır. PIN/window testleri controller'ın owner/interaction sınırını sınar; henüz kişi ekranının gerçek PIN formunu sınamaz.

Diğer anlamlı negatifler: 128 kayıt sınırında continuation reddi; başka Core/duplicate/snapshot/limit bozuk sayfa; tek uçuş; stale seçili kayıt; member readWrite ile admin işlem reddi; Direct/missing-home/password-change için sıfır feature transport; source/logout/pending/expiry; token rotasyonundan sonra eski 401; sahte ACL subject; kullanıcı GET'inden sonra kayıp yetkiyle sıfır ACL GET; başarısız GET sonrası ACL revision gerilemesi; belirsiz PUT ve eski confirmation'a geç ACK/401/409.

İlk GREEN denemesi 18 PASS/12 FAIL verdi: test host'un widget kapanışında owner retirement'ı uygulamaması, değişmiş kaydın listede yanlış konumdan seçilmesi ve mevcut hesaba tekrar login yapmaya çalışan fixture düzeltildi. Üretim yetki koşulları gevşetilmedi. Nihai kanıtlar yukarıdaki bağımsız son koşulardır.

Bütün Flutter/Dart komutları `/private/tmp/larenor-flutter-check.py` ortak kilidiyle çalıştı. Loglar:

- `/private/tmp/larenor-people-controller-red-final.log`
- `/private/tmp/larenor-people-controller-green-final.log`
- `/private/tmp/larenor-people-controller-final.log`
- `/private/tmp/larenor-people-controller-final-scoped.log`
- `/private/tmp/larenor-people-controller-related.log`
- `/private/tmp/larenor-people-controller-analyze-final.log`
- `/private/tmp/larenor-people-controller-format-check.log`
- `/private/tmp/larenor-people-controller-coverage.info`

Başlangıç pub/codegen yalnız ignored çıktıları hazırladı; üretim hata kanıtı sayılmadı. Bu dal push edilmedi, CI veya Android emülatör koşusu başlatılmadı. Mevcut imzalı APK/CI kanıtlarına bu kaynak eklenmiş sayılmaz.
