# S08.4 — Direct diafon ve film gecesi sınırı

6 Eylül 2026. Başlangıç: `7ed736b731843dd41e6234250781f27f6d0382a8`.
İzole dal: `codex/direct-home-routines`. Bu paket yalnız diafon ve film gecesi
kayıt/eylem sahipliğini kapsar; bütün S08.4 kabulü değildir.

## Davranış

DoorStationStore ve MovieNightStore, üretim provider'larından alınırken mevcut
`directHomeAccessProvider` kimliğine bağlanır. Core, başlangıç/pending ve kaynak
hatasında depo okumaları ve yazıları başlamaz. Kaynak değişimi veya provider
ömrünün sonu elde tutulan depo nesnesini kalıcı olarak emekliye ayırır. Direct'e
dönmek eski nesnenin yetkisini geri getirmez. Kapsamsız eski test/Direct depo
kullanımı korunur; üretim HomeSessionScope açık kaynak sağlamaya devam eder.

Okuma ve tek tercih yazısı `ConfigurationWrites` içinde seridir. Platform
çağrısı öncesi/sonrası sahiplik kontrol edilir, okuma kalıcı tercihlerden
`reload` eder. `_preferences()` dönüşünden sonraki continuation da tüketimden
önce ayrı `_check()` içerir. Bu son kontrol bağımsız inceleme sonrası savunma
olarak eklendi; per-platform source-change testleri tam bu microtask aralığının
RED kanıtı olarak sunulmaz.

False, exception veya tamamlanmış yazı sırasında kaybolan sahiplik başarı
sayılmaz; statik `write_unconfirmed` döner. Tek anahtarın tam değeri gerçekten
yazılmış olabilir. Otomatik rollback, retry veya temizleme yoktur. DoorStation
save'in önceden var olan immutable snapshot'ı ve upsert/remove işlemlerinin
aynı kuyruktaki read-modify-write davranışı korunur. Bozuk film gecesi JSON'u
FormatException türünü korur, fakat mesaj/source içinde kayıt içeriği taşımaz.

Kapı coordinator'ı artık hazırlanan intent ve dispatch'i kendi Direct sahipliği
ile bağlar; Core'a geçiş/geri dönüş eski onayı geçerli kılmaz. Kaynak uygun
değilse block/intent provider'ları eski HA state/mapping izlemesini başlatmaz.
Mevcut canlı durum, servis, istasyon commissioning, aktif çağrı, kod, TTL,
tek-kullanım, foreground ve fiziksel eylem kontrolleri gevşetilmedi.

MovieNightLauncher mevcut MediaSession/PIN/etkileşim/playback hedef
kontrollerine ek olarak ilk Direct sahipliğini tutar. Eski launch callback'i
kaynak dönüşünden sonra setup açamaz; eski setup seçimi yeni kaynak altında
persist/scene/play başlatamaz. Diafon editörü de ilk sahipliğini tutar; eski
Save, kaynak dönüşünde yeni bir store provider'ı alarak yetkiyi yenileyemez.
Kaynak sahipliği kullanıcı eylem izni değildir: Direct arka plan okumaları
sırf etkileşim boşta diye kesilmez; mevcut kullanıcı eylem kapıları kalır.

## RED → GREEN

| Bulgu | RED | Minimal GREEN |
|---|---|---|
| Core/pending/error depo bypass, eski cache, geç yazı yanıtı | `876bd55`: 15 FAIL | `1fb7354`: 15 PASS |
| Eski kapı intent'i/fresh Core prepare ve movie Launch | `855d713`: 3 FAIL / 1 PASS | `deb0e4b`: 4 PASS |
| Eski diafon Save yeni Direct store alarak yazıyor | `e2dd527`: 1 FAIL | `3112474`: 1 PASS |
| Film gecesi parser hatası stored JSON source içeriyor | `10a3f1c`: 2 FAIL | `488b9b5`: 2 PASS |

Kapı eylem testleri gerçek HomeSessionController/coordinator/executor ile
sentetik HTTP/WS kullanır; eski mapping/HA state bilinçli sabit tutulur ki
Direct sahiplik kontrolü diğer geçersizleşme yollarından bağımsız ölçülsün.
Depo testleri ayrıca gerçek SharedPreferences platform sınırını kullanır.
İlk action test harness'ındaki async teardown düzeltildi; kabul edilen runtime
RED kanıtı yalnız `actions-red-final.log` dosyasıdır.

Ek vakalar: retained/disposed store, queued source revocation, false/throw ve
etki sonrası hata, caller guard kaybı, optimistic cache yerine durable reload,
soğuk Core command provider, mevcut tek-kullanım ve canlı durum senaryoları,
idle/foreground/PIN akışları ve 2× Türkçe tablet düzeni regresyonları.

Son birleşik regresyon: **542 PASS / 0 FAIL** (32 saniye); core, intercom,
movie-night, backup, navigation ve settings testleri birlikte çalıştı.
Dokuz sahiplenilen kaynak/test dosyasının analizi **0 bulgu** verdi.
Beş değişen üretim dosyasının LCOV satır kapsamı toplam **631/732 (%86,2)**:

| Üretim dosyası | Çalışan / toplam satır |
|---|---:|
| DoorStationStore | 43/44 |
| MovieNightStore | 28/29 |
| intercom_providers | 189/205 |
| MovieNightLauncher | 236/255 |
| IntercomSettingsScreen | 135/199 |

Bu ölçüm dal kapsamı değildir; eski settings ekranının tüm akışlarının %80'i
çalıştı iddiası da taşımaz. Yeni source/retired-editor korumaları gerçek ekran
regresyonlarıyla doğrulandı. Bunlar Android emulator, gerçek kapı/HA/medya veya
yayınlanmış exact-head CI kabulü değildir. Ana dal, global helper, auth, backup şeması, router ve
HomeSessionScope değiştirilmedi. Bütün Flutter/Dart çağrıları ortak
`/private/tmp/larenor-flutter-check.py` kilidiyle bu worktree'de çalıştı.

- `/private/tmp/larenor-direct-routines-store-red.log`
- `/private/tmp/larenor-direct-routines-store-green.log`
- `/private/tmp/larenor-direct-routines-actions-red-final.log`
- `/private/tmp/larenor-direct-routines-actions-green.log`
- `/private/tmp/larenor-direct-routines-editor-red.log`
- `/private/tmp/larenor-direct-routines-editor-green.log`
- `/private/tmp/larenor-direct-routines-json-red.log`
- `/private/tmp/larenor-direct-routines-json-green.log`
- `/private/tmp/larenor-direct-routines-broad-final.log`
- `/private/tmp/larenor-direct-routines-final.lcov`
- `/private/tmp/larenor-direct-routines-analyze-final.log`

Diğer 11 servis credential provider'ı, wellbeing/disclosure, Ambient,
tam entity/service eşleme, ev kapsamlı restore ve typed Core cache sonraki
bağımlı dilimlerde açıktır. Mevcut roadmap kapsamı azaltılmadı. Testlerde
ilgili depo tüketimi/etkileri ölçülür; SharedPreferences getAll'ın bütün cihaz
kayıtlarını fiziksel olarak hiç okumadığı iddia edilmez.
