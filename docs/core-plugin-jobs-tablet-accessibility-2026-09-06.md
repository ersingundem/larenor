# Core iş geçmişi ve ayrıntı ekranı: tablet erişilebilirliği

Bu B5.1 dilimi yalnız `ServerPluginJobsScreen` sunumunu ve yeni gerçek ekran testlerini değiştirir. Hesap/PIN, controller, revision, polling, API ve kuruluma ilişkin mevcut kurallar korunur. Yeni küresel yardımcı, tema veya çeviri anahtarı eklenmedi.

Çalışma ağacı `/private/tmp/larenor-core-plugin-jobs-tablet`, dal `codex/core-plugin-jobs-tablet`, taban `d6bab76bb103eb3086858471148dbae4b5e6c979`. Son üretim `a1e5366937ec23bba28e49e795be5c64aab0968d`; son üretim/test checkpoint'i `30b7fd4aa52ac8323b660b4b00a23bb1d9459546`.

## Davranış ve sınır

Bölüm adları ayrı heading semantiği taşır. Geçmişte görünen “View check / Denetimi görüntüle” yazısı korunurken erişilebilir ad hizmeti, gözlenen durumu ve tarihi içerir. Her eylem aynı key ve aynı native `onPressed` callback'i kullanır. Yerel kapsayıcı en az 48×48 hedef, disabled durumda eylemsiz semantik ve mevcut tema primary rengiyle 4 px odak payı sağlar.

Native Tab kaydırması sonrasında yalnız kırpılmış halka görünür alana alınır. Post-frame işlem captured focus node, mevcut owner/epoch, mounted, route ve TickerMode denetimlerini tekrarlar. Görünür eylemler arasında gereksiz offset değişmez; eski odak bildirimi sayfa örtülmüş/pasifleşmişse kaydırmaz veya istek başlatmaz.

İptal modalı native `CupertinoDialogAction` üzerinde kalır. Yerel klavye/semantik katmanı Enter/Space ve named button rolü ekler; mevcut `valid()` ve seçili iş/revision kontrolleri değişmez. Dış 48 px kısıt normal metinde etkin hedefi korur. İç metin doğal genişliğini kullanır; normal Cupertino `FittedBox` kısa etiketleri gereksiz küçültmez. Bu düzen genel dialog sistemi değişikliği değildir.

## Gerçek RED → GREEN ve ölçüm düzeltmeleri

| Checkpoint | Çalışan ölçüm | Sonuç |
| --- | --- | --- |
| `fc36eb1` → `b980870` | EN/TR600/1280@2x başlıklar, bağlamlı View, gerçek klavye iptal ve doğal Tab odak/kontrast | 0 PASS / 20 FAIL → 20 PASS |
| `ca7485f` → `bc49d3c` | Birleşmiş gerçek semantik düğümde 1x/2x hedef, tek named tap action | 6 PASS / 2 FAIL: TR1x hedef45 px → 28 toplam PASS |
| `1cdb014` → `a1e5366` | Kısa Back/Geri metninin ekranda çizilen yüksekliği / layout yüksekliği | 4 PASS / 4 FAIL: EN0,27852/TR0,59524 ölçek → 34 toplam PASS |

İlk modal `ecbdc69` deneyi ham child düğümünü 32 px ölçüyordu. Normal Cupertino ağacı bu düğümü üst eyleme birleştirdiğinden 32 px doğrudan ürünün ekran okuyucu hedefi değildi. Doğru test tüm kök ağacında `!isMergedIntoParent` düğümlerinin `getSemanticsData()` label/flags/actions ve etkin rect değerlerini kullanır. Böylece gerçek eksik TR1x45 px olarak daraltıldı; merged-up child'lar ikinci tap hedefi sayılmaz. Dört ham32 px failure ayrı ürün kusuru iddiası değildir. 48 px rect hesaplamasındaki 47,99999999999994 kayan nokta için yalnız 1e-9 ölçüm toleransı vardır; 45 px RED kalır.

Metin ölçümü `MatrixUtils.transformRect(RenderParagraph.getTransformTo(null), rect)` ile yapılır. `getMaxScaleOnAxis` z eksenindeki1 nedeniyle bu iki boyutlu küçülmeyi ayırt etmedi; ilk geçiş bu yüzden görsel kanıt sayılmaz. Son doğru ölçüm ve PNG aynı sonucu verir. Compile-only import/isim sorunları, yanlış yönlü lazy scroll, kaydırılamayan kısa detail/no-jump düzeni ve henüz kırpılmamış preframe fixture beklentileri ürün RED olarak sayılmaz. Preframe negatifleri 600×900 pencerede gerçekten kırpılmış başlangıcı doğrular.

## Doğrulama

Yeni 34 test gerçek Jobs ekranı, hesap/controller, sentetik bounded HTTP ve bundled Inter/CupertinoIcons kullanır. EN/TR600/1280, 2x; modal ayrıca1x. Başlık/action ayrımı, tek erişilebilir ad, 48 px etkin hedef, Tab/Shift-Tab, Enter/Space, iptal sıfır mutation, onay tam bir POST ve `expectedRevision=1`, kapanmış/örtülmüş/idle modalın tutulan klavye eylemi sıfır yeni mutation doğrulanır. Busy düğmede semantic tap yoktur. Doğal ileri/geri Tab tüm dört geçmiş satırının boyanan halkasını navbar/viewport içinde tutar;1280 varyantında24/16 px safe inset vardır. Mevcut Jobs testleri PIN/account/background/hidden, cancellation revision conflict ve explicit recovery/polling sınırlarını ayrıca korur.

- `bc49d3c` üretimi + genişletilmiş testler: **307 PASS / 13 s**, 11 ilgili dosya (Jobs, Plugins, media preparation, hizmetler ve SettingsGate). Bu önceki kaynak sonucu son font düzeltmesinin testi diye sunulmaz.
- Son `a1e5366` üretimi ve final test-only public `ActionDispatcher`/brace düzeni: **55 PASS / 4 s**, gerçek Jobs ekranı regresyonları +34 tablet testi. Önceki307 ile toplanmaz.
- Son Jobs line coverage **381/395 = %96,46**; branch/tüm uygulama coverage iddiası yok.
- Analiz **2 item / 0 issue**; format **2 dosya / 0 değişiklik**. Önceki test-only analiz6issue kaydı korunmuştur; final sonuç temizdir.
- Tüm SDK komutları `/private/tmp/larenor-flutter-check.py` ile seri yürütüldü. Son koordinatör2514 ve tüm alt süreçleri exit0 ile toplandı.

Özel loglar: `/private/tmp/larenor-jobs-tablet-red.log`, `larenor-jobs-tablet-modal-effective-red.log`, `larenor-jobs-tablet-modal-painted-font-red.log`, `larenor-jobs-tablet-related-final.log`, `larenor-jobs-tablet-final-delta-verified.log`, `larenor-jobs-tablet-final-coverage.info`, `larenor-jobs-tablet-analyze-verified.log`, `larenor-jobs-tablet-format-verified.log`. Bunlar `/private/tmp` altındadır. Yapılandırılmış makbuz `/private/tmp/larenor-core-plugin-jobs-tablet-delivery-evidence.json`.

## Özel görsel kontrol

Son kaynakta üretilip `view_image` ile açılan örnekler:

- `/private/tmp/larenor-jobs-tablet-preview/jobs-modal-en-600-1x.png`: normal boyutta okunur etiketler ve görünür klavye odağı.
- `/private/tmp/larenor-jobs-tablet-preview/jobs-modal-tr-600-2x.png`: sarılan onay metni, iki ayrı eylem ve görünür halka.
- `/private/tmp/larenor-jobs-tablet-preview/jobs-history-tr-dark-600-2x.png` ve `jobs-history-en-light-1280-2x.png`: odaklı satırın tamamı görünür, metin ve eylem taşmıyor.

İlk çok küçük1x yazılı görüntü yeniden üretilmiş final görüntüyle değiştirilmiştir; RED çizilen geometri logu korunur. Bunlar özel QA'dır, README galerisi veya fiziksel TalkBack/DeX/genel tasarım kabulü değildir. Odak kontrast testi2x gerçek kart zemini karşısında en az3:1 içindir; tüm uygulamada normal17px tint metni AA iddiası değildir.

Bu dalda main, Server, contracts, Android, integration_test veya CI düzenlenmedi. Push, gerçek Server/ev/HA/Docker erişimi veya cihaz kurulumu yapılmadı. CI106 ve önceki APK sonuçları bu yeni dilimin kabulü değildir. Diğer restore modal ekranlarının benzer ölçümleri ayrı sonraki checkpoint/kapsamdır.
