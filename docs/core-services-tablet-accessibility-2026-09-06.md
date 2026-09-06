# Core hizmet bağlantıları: tablet erişilebilirliği

Bu dar B5 dilimi `643cbddf6c89085b3a10de7933a59dbe0b394739` tabanından, `codex/core-services-tablet-ui` dalında ve `/private/tmp/larenor-core-services-tablet-ui` çalışma ağacında geliştirildi. Davranış kaynağı `a47b4bda4770c5e598bd561ce3afadc1de98f833`, son kaynak/test kontrol noktası `b16b6e93c3842a4a852066373a940998efb51fb8` olur. Sonraki belge commitinin tam SHA'sı özel teslim makbuzundadır.

Sahiplik yalnız `ServerServicesScreen`, yeni `server_services_tablet_accessibility_test.dart` ve bu belgedir. Controller, hesap/oturum, PIN, pencere politikası, HTTP API, durum metinleri ve çeviriler değişmedi. Bu kaynak yayımlanmış `960691c` / Android108 paketine dahil değildir; main birleştirmesi, push, CI, cihaz kurulumu veya gerçek ev/hizmet isteği yapılmadı.

## Davranış

- Bağlantı adları, platforma sunulan etkin semantik ağaçta yalnız kendi adını içeren ayrı başlıklardır. Denetle, Düzenle ve Unut eylemlerinin erişilebilir adları bağlantının adını bir kez içerir; görünen metin aynı kalır.
- Liste/araç çubuğu yerel native düğmelerinin odak rengi mevcut tema rengidir. Dış çizgiye ayrılan boşluk ve yalnız kırpılan odak için yapılan görünürleştirme, normal Tab/Shift+Tab sırasında çizgiyi navbar ve güvenli görüntü alanı içinde tutar. Ertelenmiş işlem aynı odak, mounted/route/Ticker ve yakalanmış geçerli ekran neslini yeniden denetler.
- Unutma onayı native `CupertinoDialogAction` görünümünü ve mevcut `valid`/`submitted` geri çağrılarını korur. Yerel klavye/semantik katmanı iki ayrı düğme, Enter/Space ve en az 48px etkin hedef sağlar. İç metin doğal boyutunu korur.
- Form alanlarının etkin yüksekliği en az 48px olur. IME Next, native davranışa bırakıldığı için yalnız bir kez ilerler; son alandan İptal'i atlayıp Kaydet'e gitmez. Ölçülen iki form alt eyleminin odak rengi tema rengidir.

Kaydetme ile bağlantı denetimi aynı işlem değildir. Var olan “Kaydedildi · Denetlenmedi”, “Erişilebilir · Kimlik doğrulanmadı” ve “Kimlik doğrulandı” ayrımı; kayıtlı gizli değerlerin okunmaması; belirsiz sonuç sonrası açık yenileme ve yeniden denememe davranışları korunur. Bunların mevcut sözleşme testleri ilgili koşuma dahildir.

## TDD ve ölçüm doğruluğu

| Kontrol noktası / kaynak | Gerçek sonuç | Kanıt |
|---|---|---|
| `1156115` RED, taban üretim | 5 PASS / 27 FAIL | Başlık/ad eksikleri; EN/TR 1x modal ve form alanlarında 45px etkin hedef; 2x modalda sıfır button/tap; Tab ile İptal'e ulaşılamaması; açık sayfa yüzeyinde 1,751:1 odak kontrastı; TR600 Tab çizgisinin 1000px sınırını 3,5px aşması |
| `e1e6c9a` ilk GREEN | 32 PASS / 2s | Aynı gerçek ekran matrisi |
| `e1e6c9a` üzerinde ek form ölçümü | 2 PASS / 6 FAIL | 8 test: IME Next dört durumda Kaydet'e atlıyor; açık formda gerçek çizilen piksel kontrastı 1,745–1,776:1; iki koyu form ölçümü geçiyor |
| `535ddbb` ikinci RED | 2 PASS / 10 FAIL | Önceki 8 forma eklenen 4 etkin başlık ölçümü: raw title flag yeterli değil, yalnız bağlantı adına eşit tek etkin header yok |
| `a47b4bd` ikinci GREEN | 40 PASS / 2s | Ayrı header container, tek native Next ve iki footer focusColor düzeltmesi |
| Aynı üretim, son koruma testleri | 46 PASS / 2s | Busy/retained callback, root route/idle öncesi odak-frame iptali, tutulmuş modal eylemi ve görünür araç çubuğunda offset korunumu |
| Son ilgili 10 test dosyası | 186 PASS / 9s; 18,86s duvar süresi | 46 yeni test bu sayının içindedir; ayrıca toplanmaz. Mevcut Services, account/context/session, bağlantı ekranı, SettingsGate ve IdleGate testleri |
| Son test-only delta | 16 PASS / 2s | Tek brace temizliği ve PNG öncesi gerçek Tab/Shift+Tab odak doğrulaması; 186 koşumuna ek bir toplam değildir |

İlk tanı koşumunda modal klavye testi `Focus.of` yokluğu assertion'ıyla duruyordu. RED commitinden önce gerçek, sınırlı Tab dolaşımı ve açık “İptal'e ulaşılamıyor” beklentisine çevrildi. İlk tanı logu ayrı tutuldu. Semantik hedefler `!isMergedIntoParent` ve `getSemanticsData()` üzerinden ölçülür; raw child rect veya widget dış boyutu tek başına platform hedefi sayılmaz. Normal kısa İptal metninin gerçek `RenderParagraph` dönüşüm oranı da ölçülür.

Son altı testin ilk denemesi 43 PASS / 3 FAIL idi: iki kısa kart, istenen kaydırma konumlarını sağlamıyordu. Yalnız bu üç test dört kartla gerçek kaydırma aralığına geçti; offset önkoşulu açıkça doğrulandı. Bu fixture hataları ürün kusuru olarak sayılmaz. İlgili 186 testten sonra analyzer yalnız yeni testte bir brace uyarısı verdi; son 16 test ve temiz analiz bu düzeltmeden sonradır. Tutulmuş eylemler için public `ActionDispatcher` kullanımı zaten 186 koşumunda yer alır.

## Doğrulama ve görsel sınır

Tüm SDK komutları `python3 /private/tmp/larenor-flutter-check.py` üzerinden seri çalıştırıldı. Tam komut dizileri ve çıkış kodları `/private/tmp/larenor-services-tablet-final-execution.json` içinde bulunur. Ana doğrulama `flutter test` ile şu dosyaları çalıştırdı: yeni tablet testi, `server_services_test`, `server_services_screen_test`, `server_services_preview_test`, `server_account_test`, `server_account_context_test`, `server_session_store_test`, `server_connection_screen_test`, `settings_gate_screen_test`, `idle_gate_test`.

Son analiz 2 item / 0 sorun; format 2 dosya / 0 değişiklik. İlgili koşumda ekran satır kapsamı **538/551 (%97,64)**. Kapsam dosyası `/private/tmp/larenor-services-tablet-final-coverage.info`; test-only son brace/yakalama deltasından sonra üretim değişmedi. Bu dalda tam Client veya Server koşumu yapılmadı.

Root, `b16b6e9` son üretim/test farkını bağımsız olarak inceledi: açık P1/P2 yok (CLEAR). EN600 2x form-keyboard ve EN1280 2x liste PNG'lerini ayrıca açarak odak ve görünür düzeni doğruladı. Bu kaynak incelemesi remote CI veya fiziksel cihaz kabulünün yerine geçmez.

Gerçek `ServerAccountController`, typed API ve mevcut HTTP `MockClient` fixture'ı kullanılır; controller stub değildir, gerçek ağ da değildir. EN/TR 600/1280px ve 1x/2x ölçümleri bundled Inter/CupertinoIcons ile yapılır. İki farklı kayıt fixture'ı seçili DELETE kimlik/revision'ını doğrular. İptal sıfır mutation; Space onayı yalnız seçili revision için bir DELETE üretir. Kapsam gerçek TalkBack, Android emulator/cihaz veya tüm uygulama tasarım kabulü değildir.

Özel PNG'ler `/private/tmp/larenor-services-tablet-preview` altındadır. İncelenen örnekler:

- `services-list-tr-dark-600-2x.png`
- `services-list-en-light-1280-2x.png`
- `services-form-keyboard-en-600-2x.png`
- `services-form-keyboard-tr-1280-2x.png`
- `services-modal-en-600-1x.png`
- `services-modal-tr-600-2x.png`

Odak çizgileri tam görünür; modal normal metni küçülmez, büyük metin sarılır. Formun üstteki odaksız içeriği, son alana/alt eylemlere ilerlenmiş kaydırma konumunda kısmen görünmez; odaklı eylem görünürdür. Görseller README galerisine eklenmedi. Ölçülen odak kontrastı, uygulamanın tüm normal boyut metinleri için genel AA iddiası değildir. Apple-design ilkelerinden ölçeklenebilir metin, açıklayıcı semantik adlar, tam klavye erişimi ve güvenli alan korunumu uygulandı; Android ürün hedefi 48px olarak korundu.

Loglar `/private/tmp/larenor-services-tablet-` önekiyle `corrected-red.log`, `green.log`, `form-corrected-red.log`, `final-boundary-red.log`, `expanded-green.log`, `final-focused-corrected.log`, `related.log`, `final-delta.log`, `analyze-final.log` ve `format-final.log` dosyalarıdır. Önceki başarısız tanı/fixture/analyzer logları da korunur. Son SDK session `92018` exit0 ile tamamlandı ve reaped; makbuz `/private/tmp/larenor-core-services-tablet-delivery-evidence.json` içindedir.
