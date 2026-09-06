# Keenetic Direct bağlantı sınırı — 6 Eylül 2026

Bu teslim, Keenetic bağlantısının yerel Direct kaynağa ait olmasını ve belirsiz kayıtların açık kullanıcı kurtarması gerektirmesini sağlar. S08.4'ün tamamı veya bütün Keenetic komut ekranlarının yaşam döngüsü kabulü değildir. Gerçek yönlendiriciye bağlanılmadı; cihaz kurulumu, dağıtım ve CI başlatılmadı.

## Kaynak ve kapsam

- İzole çalışma dizini: `/private/tmp/larenor-direct-keenetic-boundary`.
- Dal: `codex/direct-keenetic-boundary`; başlangıç: `c8ccb670e4025c57fb26c0d1f3856aa84b919269`.
- Üretim/test dondurma: `6d043ac`.
- Değişen üretim: Keenetic config/client/credentials store, connection ve telemetry provider'ları, Connect/Home ekranları; iki yeni EN/TR kurtarma metni. Ortak auth, kaynak yöneticisi, credential helper, backup, Server ve protokol değişmedi.
- Testler: üç yeni Keenetic sınır/transport/kurtarma dosyası; mevcut Keenetic ve System test doubles için yalnız optional action parametresi uyumu.

## Davranış

Gerçek kayıt üç alandır: `baseUrl`, `username`, `password`. Boş parola mevcut protokol uyumluluğu için geçerlidir. Cookie'ler yalnız canlı client içindedir. Mevcut `DirectCredentialRecord` üzerindeki kapalı Keenetic enum'u ve özel pending marker kullanılır; yeni serbest alan, token veya başka bir marker anahtarı eklenmez.

Core, kaynak yükleniyor veya kaynak hatası durumlarında kayıt edinme ve client kurulumu kapalıdır. Eski Direct yetkisi, Core'a geçip Direct'e dönülünce yeniden canlanmaz. Okuma ve tam kayıt/silme işlemleri mevcut seri yapılandırma kuyruğunda her platform await sınırında doğrulanır. Eksik, bozuk veya transport'un reddedeceği URL içeren kayıt typed statik hatadır. Marker bulunan kayıt otomatik onarım veya giriş denemesi başlatmaz; kullanıcı tam bağlantıyı yeniden girer ya da kaydı siler. Yarım yazma/silmede marker kalır.

Ayarlar → Entegrasyonlar → Entegrasyonları yönet → Keenetic yolu mevcut PIN kapısını korur. Kurtarma formu boştur; eski parola gösterilmez ve gateway/LAN keşfi yapılmaz. Normal boş formun mevcut gateway doldurma davranışı yalnız geçerli kaynak, route ve draft üzerinde çalışır; geç gelen yanıt düzenlenmiş veya emekliye ayrılmış formu değiştiremez.

Form; pencere/idle, arka plan, route/ticker kaybı, provider yenilemesi ve farklı provider container'a gerçek GlobalKey taşıması sonrasında eski callback'leri ve draft'ları geçersiz kılar. Kendi doğrulamasının eşzamanlı loading yayını yalnız exact action owner için ayrılır. Dış yenileme zaten loading sırasında gerçekleşse de verification sahipliği kontrol edilir. Loading bildirimi action'ı iptal etmişse HTTP client kurulmadan yeniden kontrol yapılır.

İptal yalnız ilgili formun doğrulama client'ını kapatır; bağımsız normal okuyucu veya daha yeni form doğrulaması iptal edilmez. Çıkış işleminin sahibi, kendi loading ekranı boyunca yaşayan Home route'udur; child menünün kaldırılması meşru silmeyi yanlışlıkla iptal etmez. Aynı route'un gerçek yetki/odak kaybı ise kalan alan etkilerini durdurur.

## Kanıt

RED/GREEN checkpoint'leri korunur:

| Sınır | RED | GREEN |
|---|---|---|
| Direct/tuple/marker | `1180b06` — 1 PASS, 26 FAIL | `fd3ebc1` — 30 PASS |
| Gerçek transport, PIN ve form callback | `d19df3c` | `4a6283b` — 47 PASS |
| Transport ile aynı URL kabulü ve gerçek çıkış | `37e5d4d` — 42 PASS, 5 FAIL | `40ee3f5` — 140 PASS |
| Reload, geç gateway ve gerçek reparent | `328830f` — 27 PASS, 3 FAIL | `1ec49f8` — 154 PASS |
| Meşru replacement ve eşzamanlı action iptali | `09b689d` — 67 PASS, 2 FAIL | `685fb32` — 180 PASS |
| Loading sırasında dış reload | `4eb4897` — 180 PASS, 1 FAIL | `6d043ac` — 181 PASS |

İlk form RED grubundaki arka plan fixture'ı geçerli inactive → hidden → paused sırasına düzeltildi; framework geçiş hatası üretim arızası olarak sayılmaz. İlk geniş koşunun 987 geçen testi yanında System fake'in eski signOut imzası yükleme hatası verdi; üretim davranışı değiştirilmeden fake parametresi uyarlandı.

Son odaklı komut, ortak Flutter kilidi üzerinden:

```sh
python3 /private/tmp/larenor-flutter-check.py flutter test \
  test/core/direct_keenetic_boundary_test.dart \
  test/core/direct_keenetic_transport_boundary_test.dart \
  test/features/keenetic test/features/navigation/system_screen_test.dart \
  --coverage --reporter expanded
```

- 181 PASS: 163 Keenetic/store/transport ve 18 System entegrasyon testi; `/private/tmp/larenor-keenetic-final-focused.log`.
- Değişen yedi üretim dosyası: 784/838 satır, %93,56; `/private/tmp/larenor-keenetic-final-coverage.info`. Bu satır kapsamıdır; branch kapsamı iddiası değildir.
- Geniş regresyon: 1008 PASS / 49 saniye; `test/core`, Keenetic, Settings, Navigation ve Health; `/private/tmp/larenor-keenetic-broad-green.log`.
- Son bağımsız inceleme: üretim `6d043ac` için CLEAR; yeni P1/P2 yok. İnceleme sonrası System fake de optional action guard'ını onurlandırır; yalnız bu test dosyası tekrar 18 PASS (`/private/tmp/larenor-keenetic-system-final.log`), assertion değişmedi.
- Dar analiz: 0 issue; `/private/tmp/larenor-keenetic-final-analyze.log`.
- EN/TR, açık/koyu, 600/1200 genişlik, 2x metin: gerçek bundled Inter ile sekiz form vakası. Tab/Space ile silme, görünür kaydırma, en az 48 piksel hedef, tek eylem metni ve framework overflow bulunmaması sınanır. Son ürün görsel kabulü veya fiziksel tablet/DeX kanıtı değildir.
- Gerçek IdleGate içinde native view-focus kaybı eski callback'i ve draft'ı kapatır; ilgisiz view olayı etkilemez, odak dönüşünde yeni bağlantı kurulabilir. HTTP tamamen MockClient ve sentetik `.invalid` hedeflerdir; gateway MethodChannel sentetiktir.

## Açık sonraki sınır

`KeeneticWifiScreen._setUp` mevcut operational child akışında, onay/await sonrasında yalnız mounted kontrolüne dayanıyor. Yeni source-bound client Core geçişini engeller; aynı Direct kaynaktaki eski Wi-Fi onayının native focus veya hesap değişimi sonrasında kullanılması için ayrı action/epoch regresyonu ve dar düzeltme gerekir. Bu pilot bunu çözmüş sayılmaz. Devices/port-forward child akışları da o ayrı kapsamda incelenecektir; mevcut kurulum/protokol testlerinin geçmesi bu sınırın kapandığı anlamına gelmez.

APK98'in doğrulanmış kaynağı `a2658ec` ile bu yerel pilot ayrıdır. Bu dal için yeni CI, APK ve gerçek cihaz kabulü henüz yoktur.
