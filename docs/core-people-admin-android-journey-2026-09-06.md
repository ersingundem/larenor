# Core kişi yönetimi Android yolculuğu

Bu dal kişi profili oluşturma, metadata güncelleme, hesap izinleri ve silme işlemlerini mevcut üretim ekranlarından geçen ayrı bir Android yolculuğuyla tanımlar. Kişi profili ev metadata kaydıdır; giriş hesabı veya HA person değildir. Bu belge yerel fixture/host kanıtını native Android çalıştırmasından ayırır; yeni yolculuk henüz emülatörde çalıştırılmadı.

## Kaynak ve kapsam

- İzole dal: `codex/core-people-admin-android-journey`.
- Çalışma ağacı: `/private/tmp/larenor-core-people-admin-android-journey`.
- Başlangıç: `662a023f3d69a12c200623cf5ac2f0571ee831b8`.
- Yeni fixture: `integration_test/support/synthetic_core_people_admin_account.dart`.
- Yeni registrar: `integration_test/support/core_people_admin_journey.dart` içindeki `registerCorePeopleAdminJourney()`.
- Üretim UI/controller/model/transport ve AppHarness API değişmedi. Default account ve yalnız okuyan üye fixture değişmedi. AppHarness başlangıcından sonra ve mount öncesinde açık admin fixture seçilir.

Üretim ekranlarının gerçek PIN ve hesap girişi üzerinden kişi oluşturulur, adı/sırası değiştirilir. Gerçek `/admin/users` okumasından seçilen hesaba önce okuma, sonra okuma/yazma izni verilir. İzin kaldırma ve kişi silme ayrı somut onaylarında önce iptal, sonra kabul edilir. Son açık yenileme boş listeyi doğrular. Her faz HA HTTP/WS, dış ağ ve beklenmedik Core ret sayaçlarının sıfır kaldığını denetler. Alt rotadan dönünce yeni liste sahibinin yeni GET okuması beklenir.

## Protokol sınırı

Fixture yalnız test sunucusunun loopback portunda çalışır. Üretim Server auth, SQLite, şifreleme, ACL izolasyonu veya HMAC kanıtı değildir. Embedded `home-people.v1.json` içindeki gerçek HTTP sözleşmesinin 16 adımı durum/yanıt eşliğiyle sınanır; yeni durumların snapshot değeri açıkça sentetiktir. Metadata revision ve ACL revision ayrı kalır. Eski CAS ile yazı tekrarına izin verilmez; yanıt kaybında fixture yeni çağrı üretmez.

İstek yolu/query/body alanları kapalıdır. Gövde en çok 4096 byte; chunklar arasında 2 saniye hareketsizlik sınırı vardır (toplam akış süresi iddiası yok). Kayıt sayısı 128 ile sınırlıdır. Geçerli bearer, rol ve Core/ev bağı gövde öncesi, gövde sonrası ve bekletilen ACK sonrası yeniden kontrol edilir. Normal 503/401/protokol hataları global ret sayacına dahildir; özel hata allowlist'i veya sayaç sıfırlama yoktur.

## Korunum

Başlangıçtaki 11 app yolculuğu ve 107 faz korunur. Ana hedef dosyasından yalnız yeni import ve registrar satırı çıkarıldığında önceki dosya byte olarak aynıdır; eski 10 inline timeout ve üye yolculuğu değişmez. Yeni yolculuğun 14 fazı ve 3 dakikalık kendi timeout'u vardır. Bu dal tek başına 12 app yolculuğu / 121 faz içerir; başka dalın archive yolculuğu bu sayıya dahil değildir.

Yerel korunum makbuzu: `/private/tmp/larenor-people-admin-preservation.json`.

## Doğrulama

- Fixture runtime RED `23a8f46`: 0 PASS / 20 FAIL; minimal GREEN `a1dede3`: 20 PASS.
- Yardımcı runtime RED `4c69cca`: dikey lazy scroll 0 PASS / 1 FAIL (`No element`); delayed-enabled/current-route 0 PASS / 3 FAIL. Eski genel yardımcının yatay EditableText scrollable seçimi ve sabit pump ile erken tap davranışı gerçek widget testlerinde görüldü.
- Yardımcı GREEN `85c35f2`: genişletilmiş 32 HTTP + 2 gerçek AppHarness cleanup + 4 actual widget helper testi, toplam 38 PASS / 2 s.
- Son kaynak `cc723be1192850f9e969e819af04af5a0589b4d3`: yalnız formatter/braces/interpolation temizliği; bütün `test/integration_support` 151 PASS / 9 s, 7 analiz öğesi 0 sorun, 7 dosya format kontrolünde 0 değişiklik. 38 yeni test, 151 toplamın içindedir; önceki tam Client sayısına eklenmez.

Yeni worktree'deki başlangıç generated-source yükleme hatası runtime RED sayılmadı. HTTP test yardımcı gönderiminin UTF-8/contentLength uyumu hazırlık aşamasında düzeltildi; bu denemeler üretim UI/Server hatası olarak sunulmadı. Bu test dosyaları Flutter'ın standart LCOV kapsamına dahil olmadığından fixture/journey satır kapsamı yüzdesi iddia edilmez.

Yardımcı testleri gerçek PeoplePage/CupertinoButton ve PeopleButton ile 3 saniye gecikmeli etkinleşme, örtülen rotanın tekrar güncel olması ve yatay metin alanı varken lazy dikey hedefi sınar. Yeni yardımcı yalnız kendi yolculuğuna aittir: single mounted/current/Ticker/enabled düğme, dikey viewport ve scroll sonrası layout frame kontrolü; callback doğrudan çağrılmaz. Global `waitUntil` veya `tapVisible` gevşetilmez.

HTTP negatifleri gövde sırasında login/retire/rol/Core/ev değişimini, effect sonrası gecikmiş ACK'te aynı sınırları, kapalı JSON/izin/query alanlarını, bağımsız CAS ve snapshot paging'i kapsar. Yanıt gelmeden client kapandığında metadata bir kez kalır, tekrar istek veya yeni catch kuralı gerekmez. Normal 503 tek effect ve bir ret olarak kalır. Gerçek AppHarness.close normal CRUD/ACL akışında geçer; beklenmedik 401 sonrası aynı global sıfır ret şartı hata verir. Dış kayıt listesi değiştirilemez; iç map değerleri ayrı derin kopyalardır. Kopyayı değiştirmek fixture kayıtlarını değiştirmez.

Yerel loglar:

- `/private/tmp/larenor-people-admin-fixture-runtime-red.log`
- `/private/tmp/larenor-people-admin-fixture-first-green.log`
- `/private/tmp/larenor-people-admin-scroll-red.log`
- `/private/tmp/larenor-people-admin-readiness-red.log`
- `/private/tmp/larenor-people-admin-expanded-green.log`
- `/private/tmp/larenor-people-admin-entire-support-final.log`
- `/private/tmp/larenor-people-admin-analyze-final.log`
- `/private/tmp/larenor-people-admin-format-final.log`

Bağımsız kaynak incelemesi: Einstein (`/root/server_release_completion`) `85c35f2` ve formatter farkında yeni P1/P2 bulmadı; root pozitif yolculuk ve helper sırasını, son test/analiz/format loglarını ayrıca okudu. Bu inceleme Android yürütmesi değildir.

Native Android yürütmesi, önceki APK veya önceki tam Client koşusunun sonucu bu yeni dal için başarı sayılmaz. PIN dokunmaları, Server girişi ve HTTP istekleri test fixture verileriyle çalışır; gerçek ev/router/medya servisi veya cihaz kurulumu yapılmaz.
