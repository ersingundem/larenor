# Tablet ayar satırları: uygulama ve doğrulama

Bu çalışma `3076f5f` başlangıcından, yalnız
`codex/tablet-settings-accessibility` dalındaki izole çalışma ağacında yapıldı.
Ana yayın ağacı değiştirilmedi; dal push veya merge edilmedi.

## Davranış

- Ortak `SettingsActionTile`, native `CupertinoButton` ile Tab/Shift+Tab,
  Enter/Space ve tek adlandırılmış button semantiği sağlar. Dokunma hedefi en az
  48 piksel; metin ölçeği sınırlanmaz. Devre dışı satır okunabilir kalır fakat
  pointer semantik eylemleri engellenir.
- `SettingsNavRow`, Ayarlar kategori listesi, bağlantı adresi ve Server
  kasa/güncelleme girişleri bu bileşeni kullanır. Server'ın mevcut `_callback`,
  PIN, hesap, arka plan ve görünürlük sınırları korunur. Anahtar satırları
  sarılmadı; hesap/cache/router mimarisi değişmedi.
- İkincil HA adresi başlığın altında, sınırlandırılmış genişlikte satıra bölünür;
  tam adres semantikte bir kez kalır ve bağlantı düzenleyicisine aynen aktarılır.
- Geniş Ayarlar ekranında detail Navigator çevresindeki yerel semantik container,
  nested route bariyerinin master listesini erişilebilirlik ağacından düşürmesini
  önler. Gerçek root Navigator üzerinde gösterilen modal hâlâ iki paneli engeller.
- Odak halkasının list section klibinin içinde kalması için satırda 4 piksel
  iç boşluk bulunur. Koyu temadaki seçili satır zemini için mavi odak rengi
  hafif açılır; açık/koyu normal ve seçili zeminlerde kontrast en az 3:1 test edilir.

## RED → GREEN

| Checkpoint | Kanıt |
| --- | --- |
| `4aa6a90` RED | 12 çalışan gerçek ekran testi başarısız: 8 eksik button semantiği, 4 uzun HA adresinde yatay RenderFlex taşması. |
| `3c9a00a` GREEN | Aynı 12 test geçti: gerçek Settings → Display → Kiosk, ConnectionPane → ConnectScreen, member Server kasa/güncelleme geçişleri. |
| `2b68e18` ek RED | Gerçek Inter/CupertinoIcons yükleyen 16 varyant, devre dışı native button üzerinde tap semantiğini saptadı. |
| `3894abb` ek GREEN | Pointer semantik eylemleri kapatıldı; koyu seçili zemin için 2.9715:1 çıkan odak kontrastı düzeltildi. 38 hedefli test geçti. |

Son test temizliği yalnız güncel `flagsCollection` API'sine geçişi ve özel PNG
çıktısının `runAsync` içinde alınmasını içerir; üretim davranışı `3894abb` ile sabittir.

## Yerel doğrulama

Bütün Flutter/Dart komutları çalışma ağacından, ortak
`python3 /private/tmp/larenor-flutter-check.py` kilidiyle çalıştırıldı.

- **38 hedefli PASS**: 16 ortak satır varyantı (EN/TR, açık/koyu, 600/1200,
  1x/2x), 8 gerçek Settings/HA yolculuğu, 2 root-modal bariyer kontrolü,
  4 Server klavye yolculuğu ve 8 eski callback/lifecycle kontrolü.
- **965 geniş regresyon PASS**: `test/shared`, `test/features/settings`,
  `test/features/server`, `test/features/client_updates`,
  `test/features/navigation`, `test/features/auth`, `test/features/kiosk`.
  Mevcut PIN/reauth, update, doğrudan HA ve navigasyon regresyonları dahildir.
- Dokuz ilgili Dart dosyasında scoped analyze temiz; format dokuz dosyada
  sıfır değişiklik; `git diff --check` temiz.
- Satır kapsamı: `SettingsActionTile` **35/35 (%100)**; `ConnectionPane`
  **15/15 (%100)**; `SettingsNavRow` **20/22 (%90.9)**;
  `SettingsSplitScreen` **77/82 (%93.9)**; `ServerConnectionScreen`
  **372/390 (%95.4)**. Bu Dart LCOV satır kapsamıdır, branch kapsamı iddiası değildir.

Özel kanıt dosyaları:

- `/private/tmp/larenor-settings-accessibility-red.log`
- `/private/tmp/larenor-settings-accessibility-green.log`
- `/private/tmp/larenor-settings-disabled-red.log`
- `/private/tmp/larenor-settings-accessibility-final-focused.log`
- `/private/tmp/larenor-settings-accessibility-regression.log`
- `/private/tmp/larenor-settings-accessibility-coverage.info`
- `/private/tmp/larenor-settings-accessibility-analyze.log`
- `/private/tmp/larenor-settings-accessibility-final-format.log`
- `/private/tmp/larenor-settings-accessibility-preview-final.log`

## Görsel QA ve sınırlar

`/private/tmp/larenor-settings-accessibility-qa/` altında dört PNG üretildi ve
tek tek görüntülenerek incelendi: `tr-{light,dark}-600-2x-{first,last}.png`.
Bunlar bundled Inter ve CupertinoIcons ile gerçek Flutter rasterlarıdır.
Etiket, ikon, odak halkası ve ilk/son gruplanmış satır klibi temizdir; README
galerisine eklenmedi. Özel PNG dışa aktarımı ilk denemede test saatinde bekledi;
`runAsync` düzeltmesinden sonra iki render testi geçti.

Bu dilim diğer doğrudan `CupertinoListTile` çağrılarını topluca dönüştürmez.
Root-modal testi gerçek split ekranın üstündeki root Navigator bariyerini
sınar; SecurityPane'in yerel PIN diyaloğunu root modal diye sunmaz. Mevcut
SettingsGate PIN testleri geniş regresyonda geçti. Yeni dalın GitHub CI veya
fiziksel Huawei/DeX/TalkBack kabulü bu yerel sonuçlardan çıkarılamaz.
