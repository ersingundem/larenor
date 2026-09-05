# Medya posterleri: tablet erişilebilirlik dilimi

Bu dilim Media ana ekranı ve Jellyfin kütüphanesindeki ortak poster eylemini
klavyeyle erişilebilir kılar; kütüphane ızgarası büyütülmüş başlık satırına
yer ayırır. Medya oynatma/kuyruk, hesap, Core kapsamı, API veya genel tema
yeniden tasarlanmadı. Yeni CI ve fiziksel tablet kabulü ayrıca izlenmelidir.

## Çalışma ve kapsam

- İzole çalışma ağacı: `/private/tmp/larenor-tablet-media-accessibility`
- Dal: `codex/tablet-media-accessibility`; başlangıç: `4b98680`
- Dondurulan üretim: `dc77c4a`
- Üretim dosyaları: `lib/shared/widgets/poster_card.dart` ve
  `lib/features/media/jellyfin/presentation/jellyfin_library_screen.dart`
- Test dosyaları: `test/shared/widgets/poster_card_accessibility_test.dart` ve
  `test/features/media/hub/media_poster_accessibility_test.dart`

`PosterCard`, dokunma ile aynı callback'i çağıran yerel `CupertinoButton`
kullanır. Başlık ve mevcut durum rozeti aynı düğme semantiğinde kalır.
Tab/Shift+Tab, Enter/Space ve görünür odak halkası vardır; odak halkası kart
sınırının içinde tutulur. Önceden alınmış callback, etkileşim epoch'u,
controller kimliği, yaşam döngüsü, rota görünürlüğü veya kartın eylem callback'i
değişince geçersiz olur. Gizli/etkileşimsiz düğme etkinleştirilemez; yeni
görünür callback klavyeyle çalışabilir.

Jellyfin ızgarası sabit en/boy oranı yerine gerçek kullanılabilir genişlik,
sütun aralığı ve `PosterCard.heightFor` sonucunu kullanır. Başlık yazı
ölçeğine göre alan kazanır. Mevcut tek satır ellipsis tasarımı korunur;
uzun başlığın tamamı erişilebilir adında ve açılan ayrıntıda bulunur.

## RED → GREEN kanıtı

| Aşama | Checkpoint | Yerel sonuç |
| --- | --- | --- |
| Poster klavye/semantik + başlık yüksekliği RED | `98b1e5c` | 11 beklenen hata; posterler 24 Tab adımında erişilemiyor, düğme semantiği yok, 2× satır için gereken 26px yerine yaklaşık 7.24/7.41px ayrılıyor |
| En küçük GREEN | `9a2e4cc` | 11 PASS |
| Eski callback RED | `657b19d` | 6 beklenen hata: idle, gizleme, arka plan, kaplı rota, controller değişimi, dispose |
| Callback yaşam döngüsü GREEN | `dc77c4a` | 17 PASS |
| Son test genişletmesi | Üretim `dc77c4a` değişmeden | 22 PASS; gerçek-font, 40 poster boyunca klavye kaydırması, ters Tab, modal, geri kullanılan kart, gerçek Media/Jellyfin geçersiz callback testleri |

733 ilgili test ayrıca geçti: tüm `test/features/media`, medya gezinmesi,
ortak tasarım tokenları/görsel yerleşim, poster bileşeni ve gerçek
`HomeSessionScope` runtime testleri. Bu koşudan sonraki iki ilave test ve test
analizi temizliği son 22 testte doğrulandı. Dört dosyanın analizi sorunsuz.

Son odaklı satır kapsamı: `PosterCard` 97/102 (%95.1),
`JellyfinLibraryScreen` 26/31 (%83.9); toplam 123/133 (%92.5).
Kapsam kanıtı mevcut ağ görsel indirme veya fiziksel cihaz testi yerine geçmez.

## Tablet ve özel görsel QA

EN/TR, 600/1200 genişlik, 2× yazı, açık/koyu koşulları gerçek bundled Inter
ve CupertinoIcons ile test edilir. İlk/son ızgara satırının başlık yüksekliği,
en az 48px düğme, odak çerçevesinin kart içinde kalması ve odak/zemin
kontrastının en az 3:1 olması doğrulanır. Gerçek kütüphanede Tab 40 öğenin
tamamına kaydırarak ulaşır; Shift+Tab bir önceki öğeye döner.

600px/TR/2×, 12 sentetik öğeli açık/koyu PNG'ler `view_image` ile incelendi:
dikey başlık kırpılması, kart çakışması veya odak halkası kesilmesi görülmedi.
Bu görüntüler özel QA içindir; README galerisine eklenmedi. Sentetik
kütüphane adı `Library` içerik verisidir; uygulama yerel ayarı ayrıca `tr`
olarak doğrulanır.

- `/private/tmp/larenor-media-a11y-preview/library-tr-600-2x-light.png`
- `/private/tmp/larenor-media-a11y-preview/library-tr-600-2x-dark.png`

## Yerel komut ve günlükler

Bütün Flutter/Dart komutları ortak kilit üzerinden çalıştırıldı:
`python3 /private/tmp/larenor-flutter-check.py`.

- İlk RED: `/private/tmp/larenor-media-a11y-red.log`
- Callback RED: `/private/tmp/larenor-media-a11y-guard-red.log`
- 733 regresyon: `/private/tmp/larenor-media-a11y-regression.log`
- Son 22 test: `/private/tmp/larenor-media-a11y-final.log`
- Son kapsam: `/private/tmp/larenor-media-a11y-final-coverage.info`
- Analiz: `/private/tmp/larenor-media-a11y-analyze.log`

Görüntüler son testte `--dart-define=MEDIA_A11Y_PREVIEW_DIR=/private/tmp/larenor-media-a11y-preview`
ile üretilebilir. Bu seçenek yalnız sentetik widget çıktısı yazar; gerçek
sunucu, ev, oynatma veya Docker işlemi yapmaz.

## Ana dal birleşimi

İzole freeze `cb792c0bc7a5ca10a8d6cda1afbc66a7f13bea89`, bağımsız son
kod/test/PNG incelemeleri temiz; ana dala
`14b7b62c05d2b1475818acecc9d2270d55f9f2c9` ile birleştirildi. Root da
600/TR/2× açık/koyu gerçek kütüphane görüntülerini kontrol etti.

Birleşik main üzerinde tam Client **2.837 test PASS** (4:04), `flutter analyze`
sıfır bulgu (4,5 saniye) ve 803 Dart dosyasında biçim kontrolü sıfır değişiklik
verdi. Loglar `/private/tmp/larenor-root-media-full-flutter.log`,
`/private/tmp/larenor-root-media-full-analyze.log`,
`/private/tmp/larenor-root-media-format.log`. Yeni exact-source CI ve fiziksel
tablet kabulü ayrıca beklenir.
