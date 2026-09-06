# Core logout: onuncu Android yolculuğu

Bu test dilimi, logout uygulaması `2911ac9cc810c50e639fe1d65046f2dc114283d7` ile yayımlanmış `a27abeaa55a2ea94a0a0eaec1b9a74743c086a9c` geçmişlerini merge ederek oluşturuldu. İzole dal `codex/core-logout-android-journey`, çalışma dizini `/private/tmp/larenor-core-logout-android-journey`. Ana checkout, üretim Dart kodu, workflow, kuyruk ve PROGRESS değiştirilmedi; bu daldan push/CI başlatılmadı.

## Yeni yolculuk

Production HomeSessionScope ve gerçek hesap ekranı altında mevcut PIN kapısından Core login yapılır. İzinli gerçek kaynak satırı görünmeden login tamamlanmış sayılmaz. Yeniden PIN altında logout onayı önce iptal edilir; oturum ve kayıt değişmeden kalır. Sonraki açık onay, mevcut sentetik HTTP logout204 yolunu kullanır. Core status geri gelir, kaynak satırı kaldırılır ve production `SecureServerSessionStore.read()` null döndürür. Core kaynağı ve legacy dashboard kaydı korunur; HA HTTP/WS ve ACL kullanıcı/değişiklik işlemleri sıfır kalır.

AppHarness.start ikinci kez çağrılmaz. Uygulama widget ağacı unmount edilip aynı AppHarness ile yeniden mount edilir; fixture prefs/secure-store ve loopback Server aynı kalır. Yeni account initialize tamamlandıktan sonra session hâlâ null, login/me/context sayaçları değişmemiş ve Direct ekran/HA fallback yoktur. Hesap yönetimini açmak yeniden PIN gerektirir.

Yeni helper veya auth modu yoktur: `coreResourceGrants` mevcut opt-in fixture zaten authenticated logout/revoke204 destekler. Yeni yolculuk ACL ekranını açmaz; grants mutations ve usersReads sıfır olarak ayrıca sınanır. AppHarness.close içindeki network.blocked=0, HA rejectedWrites=0 ve Core rejectedRequests=0 kapıları aynen korunur. 503 veya fault istisnası eklenmez.

## Koruma kanıtı

`a27abea:integration_test/app_journeys_test.dart` içindeki ilk dokuz yolculuğun gövdeleri byte düzeyinde aynıdır; 89 aşama işareti aynı sırayla korunur. Yeni onuncu yolculuk 10 sabit aşama ekler: begin, mounted, account_verified, logout_cancelled, session_removed, remount_begin, remounted_without_session, recovery_pin_required, cleanup_begin, cleanup_complete. Yeni toplam **10 app yolculuğu / 99 işaret**. Dört mevcut native platform testiyle ileride beklenen toplam 14 testtir; bu belge onların çalıştığını söylemez.

Özel koruma kaydı: `/private/tmp/larenor-logout-e2e-preservation.json`. Eski gövde SHA-256: `8408b76fa2fd88626c63bb8f04b0ef9724bfbc3ae51d36d93b57592ff60e51ce`.

## Yerel test ve kanıt sınırı

Yeni host kontrolü gerçek `SecureServerSessionStore`, `ServerAccountController`, bounded API transport ve yalnız ayrılmış loopback soketi üzerinden mevcut sentetik logout204 yolunu çalıştırır. Yeni controller initialize HTTP üretmez, unrelated HA/PIN anahtarları kalır ve **gerçek AppHarness.close** katı sıfır kapılarıyla biter. İkinci host kontrolü dış hedefin FixtureNetwork tarafından soket açılmadan reddedilmesini sınar; gerçek dış bağlantı yapılmaz.

Fixture davranışı değiştirilmediği için bu dilim yeni bir fixture bugfix/RED→GREEN iddiası taşımaz; mevcut davranış için yeni yolculuk/host kabul testidir. Logout üretiminin gerçek RED→GREEN checkpointleri `8d03507` ve `674b977`, final kapsamı `2911ac9` içinde ayrıca korunur.

Mevcut AppHarness hem SharedPreferences hem secure-storage **backend'lerini sentetik bellek ile değiştirir**. Production store sınıfı ve aynı süreçte fixture persistence remount doğrulanır; native Keystore/disk veya OS process restart kanıtı değildir. Önceki 25 platform/runtime logout testi before/after yazma-silme ve belirsiz logout sınırlarını ayrı ele alır. Bu test yeni fault machinery veya native anahtar yönlendirmesi eklemez. Dört native platform testi, bu sınırlı fixture persistence iddiasını kendiliğinden native storage iddiasına dönüştürmez.

Bu dilimde Android emülatörü veya fiziksel cihaz çalıştırılmadı. App journey'nin gerçek Android sonucu sonraki exact CI kaynağına aittir. Aşağıdaki yerel host/analiz sonuçları onun yerine geçmez.

Davranış checkpoint'i `e8bedfe`; aynı kaynak için root bağımsız ilk incelemesi yeni P1/P2 bulmadı.

| Yerel kontrol | Sonuç | Kanıt |
|---|---|---|
| Yeni host logout/cleanup + ağ kapısı dosyası | **2 PASS** | `/private/tmp/larenor-logout-e2e-host.log` |
| `flutter test --no-pub test/integration_support` | **87 PASS**, 5 sn | `/private/tmp/larenor-logout-e2e-entire-support.log` |
| Yeni journey + host testi, `flutter analyze --no-pub` | **2 dosya, 0 issue** | `/private/tmp/larenor-logout-e2e-analyze.log` |
| `dart format --output=none --set-exit-if-changed` | **2 dosya, 0 değişiklik** | `/private/tmp/larenor-logout-e2e-format-final.log` |
| Eski kaynak/işaret karşılaştırması | **9 body/89 marker byte-exact**, toplam **10/99** | `/private/tmp/larenor-logout-e2e-preservation.json` |

İki yeni test 87'nin içindedir; sayılar toplanmaz. Bütün SDK komutları `/private/tmp/larenor-flutter-check.py` ortak kilidiyle çalıştırıldı. `git diff --check` temizdir. Bu yalnız test ekleyen delta için tam Flutter/Server veya yerel Android koşusu tekrarlanmadı; onuncu Android yolculuğunun sonucu gelecekteki exact CI koşusunda doğrulanmalıdır.

## CI102 bulgusu ve dar onarım

[CI102 sonucu](client-delivery-102-2026-09-06.md): eski dokuz yolculuk geçti;
onuncu yolculuk `target['id']` okumasında mount öncesi düştü. Önceki87
host testi bu ifadeyi çalıştırmadığı için hata yakalanmadı. Yeni ortak
`SyntheticCoreResourceGrants.targetId` getter'ı hem gerçek authenticated
resource GET host regresyonunda hem onuncu yolculukta kullanılır. Yolculuktaki
kimlik okuması artık cleanup sağlayan try/finally içindedir.

RED `2be52c0`: 3 PASS/1 gerçek TypeError FAIL. GREEN `d99fc79`:4 PASS;
sonra bütün integration_support **88 PASS/8sn**, tam analiz **0bulgu/6,2sn**.
Başlangıçtaki eksik generated-files derleme hatası ayrı hazırlık kaydında
korunur; RED kanıtına dahil edilmez. Üretim, fixture HTTP davranışı, workflow,
timeout ve eski test beklentileri değişmedi. İlk dokuz yolculuğun kaynak
prefix'i byte-exact; tüm99fazın adı/sırası aynı. Son getter biçim değişikliği
yalnız boş satırdır. `d99fc79` bağımsız kaynak incelemesi CLEAR.

Özel kanıtlar `/private/tmp/larenor-logout-fixture-{red,green,support,analyze}.log`,
`larenor-logout-fixture-repair-preservation.json` ve
`larenor-logout-fixture-repair-review.json`. Yeni exact Android CI sonucu
ayrıca gereklidir;88 host testi emülatör veya fiziksel kabul yerine geçmez.
