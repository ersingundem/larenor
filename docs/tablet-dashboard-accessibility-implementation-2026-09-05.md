# B5.1 — Dashboard kartlarının klavye ve semantics dilimi

2026-09-05 · İzole dal `codex/tablet-dashboard-accessibility`, başlangıç `5fecbfcd7a2765f85e09f152c265830a7494c5cc`, son kod/test checkpoint `8b1946a`. Android tablet ve DeX pencere kullanımı için sınırlı ortak kart düzeltmesidir; B5.1’in tamamı veya fiziksel cihaz kabulü değildir.

## İnceleme ve sonuç

Apple-design incelemesi erişilebilirlik, renk, yerleşim, tipografi ve odak/klavye ilkelerine göre yapıldı. Kullanıcı ayarlı 2× metin, klavyeyle erişim, tek anlaşılır ekran okuyucu duyurusu, en az 48×48 kontrol ve kırpılmayan görünür odak temel alındı. [Erişilebilirlik](https://developer.apple.com/design/human-interface-guidelines/accessibility), [yerleşim](https://developer.apple.com/design/human-interface-guidelines/layout), [tipografi](https://developer.apple.com/design/human-interface-guidelines/typography), [odak ve seçim](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection).

| Somut bulgu | Son davranış |
| --- | --- |
| HomeAccessoryTile ve 11 servisin kullandığı ServiceTileShell yalnız GestureDetector üzerinden çalışıyordu; Tab/Enter/Space yoktu. | Dashboard-private `DashboardTileButton` native CupertinoButton kullanır. Her kart tek tam ad/durum etiketine sahiptir; görsel metin ikinci kez okunmaz. |
| Aksesuarın uzun basma menüsüne fiziksel klavyeden erişilemiyordu. | Context Menu tuşu ve Shift+F10 mevcut korumalı menü callback’ini çağırır. Popup kapandığında native odak korunur. |
| Termostat dial’ında screen-reader artır/azalt vardı, hardware keyboard odağı yoktu; cihaz adı interaktif duyuruda eksikti ve sıcaklık tekrarlanıyordu. | Odaklanan slider’da ok tuşları mevcut adım/min/max kurallarını kullanır. Label cihaz adı + yerelleştirilmiş hedef sıcaklık, value hedef, hint mevcut ölçümdür. Dial görselleri tekrar duyurulmaz. Pan önizlemesinde artırma işlemi duyurulan değere uyar. |
| Servis kartının kaydedilmiş navigation callback’i eski pencere/route durumundan sonra çalışabiliyordu. | Generic widget kendi lifecycle generation’ını, AppInteractionScope identity/epoch değerini, mounted, route ve TickerMode durumunu yeniden doğrular. Idle→wake, background→resume, hidden, covered, reparent ve disposal eski callback’leri geçersiz kılar; yeni klavye aktivasyonu çalışır. Consumer bağımlılığı eklenmedi. |

Native odak çizgisi kartın dışına boyandığı için içte 4 px pay ayrıldı; mevcut aksesuar ve servis row-height hesaplarına 8 px eklendi. İlk TR/EN 2× örnekleri zaten taşmıyordu; düzen değişikliği bu odak payını karşılar. MediaPlayerTile mevcut native 48 px etiketli düğmelerini ve slider davranışını korur; üretim dosyası değişmedi.

Callback koruması yalnız ortak dashboard düğmesindedir. Uygulama başlangıcı, HomeSessionScope, router, Settings, source/store, global theme, modeller ve API değişmedi. Mevcut HA işlem/hesap/mahremiyet korumaları korunmuştur; bütün testler sentetik provider/HTTP kullanır.

## RED → GREEN ve doğrulama

- Klavye RED `ed5c650`: 5 runtime hata / 29 PASS → minimal GREEN `9f3cbc4`: 34 PASS.
- Menü ve climate duyurusu RED `6c10a34`: 2 hata / 34 PASS → GREEN `03c6203`: 36 PASS.
- Climate pan-preview duyuru/işlem eşleşmesi RED `c3f2ace`: 1 hata / 72 PASS → GREEN `1a943ac`: 73 PASS.
- Eski servis navigation callback’leri RED `673f3e0`: 6 hata / 13 PASS → generic guard GREEN `aeb233b`: 90 ilgili PASS. Lifecycle fixture gerçek inactive→hidden→paused→hidden→inactive→resumed sırasını kullanır.
- Son dashboard suite: **343 PASS**, yaklaşık 13 saniye. Yeni test dosyasında 19; mevcut climate/media/scene dosyasına 7 yeni test eklendi. İki eski guard testindeki GestureDetector locator’ı native CupertinoButton callback’ine geçirildi; eski state/hesap/hidden negatif beklentileri korunur.
- Son lint düzeltmesinden sonra odaklı delta: **49 PASS**, 1 saniye; dokuz owned dosyada scoped analyze **0 bulgu**, 2,1 saniye. `git diff --check` temiz.

Flutter LCOV **satır kapsamı**, branch kapsamı değildir:

| Üretim dosyası | Kapsam |
| --- | --- |
| dashboard_tile_button.dart | 63/64 — %98,4 |
| climate_tile.dart | 181/188 — %96,3 |
| service_tile_shell.dart | 40/40 — %100 |
| dashboard_card_presentation.dart | 18/18 — %100 |
| home_accessory_tile.dart, mevcut tüm menü akışları dahil | 164/219 — %74,9 |
| Beş dosya toplamı | 466/529 — %88,1 |

Gerçek widget tema renklerinden hesaplanan odak kontrastı: kart açık **4,02:1**, koyu **5,42:1**; climate açık **4,02:1**, koyu **4,66:1**. Testler native çizginin grid clip sınırları içinde kaldığını, 48 px minimumu, TR/EN 2× metni, tek semantics node’unu, busy yinelenen komut reddini ve yeni callback ile yeniden klavye kullanımını doğrular.

Bütün Flutter/Dart komutları ortak `/private/tmp/larenor-flutter-check.py` kilidiyle bu izole worktree’de çalıştırıldı. Hazırlık offline pub ve mevcut build_runner codegen kullanır. Geçici kanıtlar: `/private/tmp/larenor-dashboard-final-regression.log`, `/private/tmp/larenor-dashboard-final-delta.log`, `/private/tmp/larenor-dashboard-final-analyze-green.log`, `/private/tmp/larenor-dashboard-final-lcov.info`.

Yeni exact-head GitHub CI, tam Client suite ve fiziksel Huawei/DeX/TalkBack kabulü bu yerel dilimin kanıtına dahil değildir. Genel B5.1 kapsamında diğer kart/editor/gesture yüzeyleri ayrıca ele alınacaktır; gerçek HA veya ev servisine bağlanılmadı.
