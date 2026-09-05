# Core ana ekranında yetkili oda ve kaynak listesi

Bu teslim S08.6'nın Client tarafındaki **salt okunur ilk liste dilimidir**. Admin kayıt/ACL düzenleme, cihaz komutları, Core adaptörleri, sürekli yetki yayını ve kalıcı kaynak önbelleği bu teslimde yoktur.

## Kaynak ve çalışma sınırı

- İzole dal: `codex/core-home-resource-list`.
- Çalışma ağacı: `/private/tmp/larenor-core-home-resource-list`.
- Başlangıç: `7ed736b731843dd41e6234250781f27f6d0382a8`.
- Dondurulmuş üretim: `5288636`.
- Server ortak sözleşme checkpoint'leri `c02efb2` ve `285629c`, cherry-pick yerine merge ile aynı geçmişe alındı. `contracts/home-resources.v1.json` gerçek authenticated Server HTTP yolculuğundan üretilir; Dart testleri aynı dosyayı tüketir. İkinci Core etiketleri açıkça farklıdır.
- Üretim sahipliği yalnız yeni `lib/features/home_resources/`, mevcut Core durum ekranındaki sliver girişi, bounded Server transport'un exact home-resources GET query allowlist'i ve EN/TR metinleridir. Router, account/session store, HomeSessionScope, backup ve Server üretim kodu değiştirilmedi.

## Davranış ve sınırlar

Core ana ekranı yalnız güncel, doğrulanmış Core/home/user oturumuyla izin verilen odaları ve kaynakları gösterir. Hazır oturumla ilk görünür GET bir kez başlar; yenileme ve sonraki sayfa açık kullanıcı eylemleridir. Yenileme önce eski listeyi kaldırır. Boş sonuç yalnız başarılı cevap sonrasında gösterilir; hata veya yetki belirsizliği boş ev diye sunulmaz.

Transport her okumanın kendi sahibindedir. Route, idle, arka plan, native odak veya kaynak/hesap/ev değişimi listeyi ve sayfa imlecini temizler, yalnız bu transport'u kapatır ve geç cevapları reddeder. Hesabın shared context GET'i iptal edilmez. Oturumun 30 saniyelik yenileme sınırında metadata kapanır; kullanıcının açık yenilemesi mevcut account refresh protokolünü kullanabilir. Pending context boyunca ev verisi kapalı kalırken PIN korumalı hesap kurtarma kullanılabilir.

Ekranı terk eden aynı-token isteğinin geç 401 cevabı artık `cancelled` olarak tutulur; güncel hesabı silemez. Etkin, aynı oturumla çalışan isteğin 401'i mevcut account reddetmesini hâlâ uygular. Token rotasyonu aynı tuple üzerinde router'ı korur. Server login tek başına Direct HA kaynağını değiştirmez. Core altında HA connection provider/REST/WS fallback'i yoktur.

Public kayıt modeli exact alanları, Core/home ref'i, gerçek integer schema/revisions, read permission, 32-hex IDs, 64-hex snapshot ve Server'ın 80 Unicode codepoint etiket sınırını doğrular. Server'ın Python whitespace/label sözleşmesi korunur; izin verdiği C1/bidi karakterler için farklı bir Client protokolü icat edilmez. Etiketler yalnız metindir. `write` metadata izni cihaz kontrolü veya admin ekranı olarak sunulmaz.

Sayfa boyutu varsayılan 25, API sınırı 100, oturumda tutulan toplam üst sınır 512'dir. Her sayfa requested limit'e, artan wire ID'ye ve opaque snapshot'a bağlıdır. Görünen immutable kopya `order → id` sırasına girer; controller/wire ID dizisi ve cursor değişmez. Yeni sayfalar geldikçe yalnız yüklenmiş altküme yeniden sıralanır. Sliver key/index eşlemesi mevcut satır ve semantics kimliğini korur. 512'nci kayda lazy liste üzerinden erişim testlidir.

Remote ACL değişiklikleri açık GET ile yeniden değerlendirilir; push veya kesintisiz yetki tespiti iddiası yoktur. Kaynak/ACL metadata'sı diske yazılmaz. Yeniden oluşturulan uygulama/hesap örneği listeyi Server'dan tekrar ister; bu widget kanıtı native OS process restart veya cihaz disk dayanıklılığı iddiası değildir.

## RED → GREEN kanıtı

| Checkpoint | Kanıt |
| --- | --- |
| `5406422 → f7987a8` | Strict model/query sınırı; query runtime RED, model missing-module RED ayrı kaydedildi; ilk GREEN 41 PASS. |
| `7304b7f → 3d5f62a` | Gerçek HomeSessionScope ve synthetic HTTP hesabında Core liste eksikliği runtime RED; ilk gerçek ekran GREEN 52 PASS. |
| `abb66ca → 71104aa` | Native window focus kaybında geç read yayınlanması: 8 PASS / 1 FAIL → 10 runtime PASS. |
| `5d8dd78 → 5420ec6` | Route/background sonrası aynı-token geç 401 hesabı düşürüyordu: 5 PASS / 2 FAIL → 17 runtime PASS; aktif 401 reddetmesi ayrıca korunuyor. |
| `cbbfb26 → 5288636` | Sonraki sayfadaki düşük `order` kaydı yanlış yerdeydi; sıra, keyed row kimliği, cursor ve More keyboard focus runtime GREEN. |

Son kaynak için doğrulama:

- **82 odaklı test PASS**, `/private/tmp/larenor-core-home-resources-final-coverage.log`.
- **940 geniş regresyon PASS**: `test/core`, `test/features/server`, `test/features/home_scope`, `test/features/navigation`, `test/features/settings`, `test/features/home_resources`; `/private/tmp/larenor-core-home-resources-broad.log`.
- Son order/authority/lifecycle delta: **22 PASS**, `/private/tmp/larenor-core-home-resources-final-delta.log`.
- Odaklı analyzer: **No issues**, `/private/tmp/larenor-core-home-resources-analyze.log`.
- Scoped format kontrolü: **16 dosya, 0 değişiklik**, `/private/tmp/larenor-core-home-resources-format-check.log`.
- Yeni feature line coverage: **377/380 (%99,2)**; model 80/82, API 15/16, controller 138/138, widget 144/144. `/private/tmp/larenor-core-home-resources-coverage.info`. Bunlar executable line ölçümleridir; tüm branch'lerin veya güvenlik senaryolarının yüzde yüz kanıtı değildir.
- Bağımsız salt okunur inceleme: aynı-token stale 401 bulgusu RED/GREEN ile kapandı; `5288636` son order/source farkında yeni P1/P2 yok.

Tüm Flutter/Dart komutları ortak kilit üzerinden çalıştırıldı: `python3 /private/tmp/larenor-flutter-check.py ...`. Canlı Server/HA/Docker veya fiziksel cihaz çağrısı yapılmadı; push/CI bu izole görevde başlatılmadı.

## Tablet ve özel görsel QA

Sekiz gerçek bundled Inter/CupertinoIcons koşulu: EN/TR × 600/1200 × açık/koyu, hepsi 2× text scale. Tek accessible button adı, ayrı heading flag, 48px minimum hedef, Tab/Shift-Tab + Enter/Space, odak kontrastı ≥3:1 ve uzun Unicode etiket wrapping testi geçti. Özel PNG export koşusu ayrıca 4 PASS:

- `/private/tmp/larenor-core-home-resources-qa/core-resources-tr-600-2x-light.png`
- `/private/tmp/larenor-core-home-resources-qa/core-resources-tr-600-2x-dark.png`
- `/private/tmp/larenor-core-home-resources-qa/core-resources-en-1200-2x-light.png`
- `/private/tmp/larenor-core-home-resources-qa/core-resources-en-1200-2x-dark.png`

600 açık/koyu ve 1200 açık render'ı görsel olarak incelendi: focus/selection target, etiketler ve wrapping taşmıyor. Sentetik 80-emoji satırında Flutter test host'una OS emoji fontu yüklenmediği için no-glyph yer tutucuları görülebilir; gerçek Android emoji fontu görünümü bu PNG'lerle doğrulanmış sayılmaz. Bunlar özel QA görselleridir; son frontend/README galerisi ve fiziksel tablet kabulü ayrı kalır.
