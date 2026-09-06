# S08.4 — API-key kaydındaki belirsizlikten sonra doğrulanmış oturumu kapatma

6 Eylül 2026. Dal `codex/media-credential-confirmation`, başlangıç
`6c5fbb24c31527413661a5de501c2b31c5d5d21f`. Üretim/test dondurması
`5208557444b1c32eee2ca18b791dca143781ef7e`. Son davranış değişiklikleri
provider için `29de495`, ekranlar için `a3d0409`; sonraki kaynak farkları
yalnız format içerir.

Bu dar takip paketi Sonarr, Radarr, Lidarr, Readarr, Jellyseerr, Bazarr ve
Prowlarr içindir. Önceki Direct record sahipliği ve marker mekanizmasını
korur. Ortak `DirectCredentialRecord`, `ArrConnectForm`, auth, backup,
pencere kapsamı veya HTTP protokolleri değiştirilmedi. Jellyfin/qBittorrent
ve diğer pilotların kabulü, bütün S08.4 veya Core adaptör kabulü değildir.

## Düzelen durum

Daha önce doğrulanmış bağlantı varken yeni save/clear sırasında platform
hatası olursa, pending marker eski kaydın yeniden okunmasını engellese bile
provider mevcut `AsyncData` hesabını tutabiliyordu. Böylece mevcut okuma
istemcisi kullanılabilir görünüyordu.

Yedi notifier artık `write_unconfirmed`, `pending_mutation` veya
`storage_failed` hatasında mevcut hesabı `AsyncError` yapar; eski reader
kapanır. Hata state'i yayımlanmadan önce özgün işlem kuşağı ve Direct sahibi
tekrar doğrulanır. Eski işlem yeni kaynak veya login'e hata yazamaz. Genel
HTTP authentication reddi bu kategoriye girmez ve önceki doğrulanmış
bağlantıyı korur. Başarısız işlem hata olarak kalır; başarı veya otomatik
kurtarma üretilmez.

Son marker silme etkisi gerçekleşip platform ACK'i kaybolmuş olabilir.
Bu durumda marker yok ve yeni tuple tam olsa bile çağrı
`write_unconfirmed` kalır. Bu hata `pending_mutation` diye yeniden
adlandırılmaz; storage'da bulunmayan marker varmış gibi sunulmaz. Otomatik
rollback, retry, temizleme veya yeniden okuma yoluyla aynı oturuma güven
kazandırma yoktur. Bu native Keychain/Keystore transaction veya fsync
kanıtı değildir; gerçek süreç yeniden başlatıldığında marker bulunmayan
tam kayıt için yeni bir kalıcı belirsizlik günlüğü eklenmedi.

Dört Arr ana ekranı ile Jellyseerr/Bazarr/Prowlarr ana ve ayrı bağlantı
ekranları toplam on noktada iki kurtarılabilir kodu tanır:
`pending_mutation` ve `write_unconfirmed`. Diğer hatalar güvenli genel
hata olarak kalır. Kurtarma formu boş URL/key ile açılır; LAN discovery
başlatmaz. Kullanıcı açık tam yeniden bağlantı veya clear yapabilir.
Mevcut formun callback kimliği, kaynak/epoch ve her await için eylem
kontrolleri aynen korunur; form API'sine veya davranışına ekleme yapılmadı.

## Gerçek RED → GREEN

| Dilim | Runtime RED | Minimal GREEN |
|---|---|---|
| Doğrulanmış reader + storage belirsizliği | `6ec3857`: 7 PASS / 56 FAIL | `29de495`: 63 PASS |
| Final marker ACK kaybından sonra PIN recovery | `e00168e`: 14 FAIL | `a3d0409`: 14 PASS |

Provider başlangıcındaki eksik import/dynamic fixture hataları runtime
RED değildir; sayılara dahil edilmez. Root'un format checkpoint'i
`f916729` sonrasında yeni 63 test ve dört mevcut core dosyası birlikte
233 PASS verdi.

Yeni UI testleri yedi gerçek provider/store için PIN → Integrations →
Manage Integrations → servis yolunu kullanır. İlk pending kayıt boş formu
açar. Kullanıcının tam login'i marker silmeye kadar gerçekten ilerler;
MethodChannel handler silme etkisinden sonra hata verir. Test marker'ın
yokluğunu, tam yeni tuple'ı, korunmuş `write_unconfirmed` state'ini, yeniden
boşalan iki alanı, sıfır LAN discovery ve otomatik ek HTTP/storage işlemi
olmadığını birlikte doğrular. Ardından ayrı clear ve tam reconnect
senaryoları başarıyla tamamlanır. Geçmiş confirmed reader'ın kapanması
ayrıca 63 provider testinde doğrulanır; UI testinin başlangıcı doğrulanmış
hesap olarak yanlış sunulmaz.

## Son yerel doğrulama

- Yeni provider testleri: **63 PASS**; yeni gerçek PIN UI testleri: **14 PASS**.
- Bunlarla birlikte mevcut dört core credential/action dosyası ve Arr/API-key
  UI, session, parser/model regresyonları: **370 PASS**.
- Yedi provider, on ekran, iki yeni test dosyası analyze: **19 dosya, 0 bulgu**.
- Son UI/test format kontrolü: **11 dosya, 0 fark**. Root'un sekiz
  provider/core-test dosyası ayrı format checkpoint'inde doğrulandı.
- Aynı birleşik koşunun yedi provider satır kapsamı: **471/486 — %96,9**.
- Bu paketin değişen ve LCOV tarafından ölçülen çalıştırılabilir satırları:
  **70/76 — %92,1**; on ekranın yeni koşulları **13/13**.
- Mevcut browse içerikleriyle on ekranın tam dosya kapsamı **258/516 — %50,0**;
  tüm on yedi üretim dosyası **729/1002 — %72,8**. Bu dar hata yönlendirme
  paketi geniş browse davranışının %80+ kabulü olarak sunulmaz.

HTTP `MockClient` ile, secure-storage ise gerçek plugin MethodChannel
sınırındaki sentetik platform handler'ıyla çalışır. LAN keşif widget'ı ve
Wi-Fi sorgusu testte yoktur; fiziksel ağ, gerçek hesap/anahtar, ev servisi
ve Android cihazına erişilmedi. Bütün Flutter/Dart komutları ortak
`/private/tmp/larenor-flutter-check.py` kilidiyle izole worktree'de çalıştı.
Birleşmiş main tam Client ve CI kabulü ayrı adımdır; bu dal push yapmadı.

Geçici kanıtlar:

- `/private/tmp/larenor-media-confirmation-provider-broad.log` — root 233 PASS.
- `/private/tmp/larenor-media-credential-recovery-red.log` — gerçek UI 14 FAIL.
- `/private/tmp/larenor-media-credential-recovery-green.log` — UI 14 PASS.
- `/private/tmp/larenor-media-confirmation-ui-broad.log` — final 370 PASS.
- `/private/tmp/larenor-media-confirmation-ui-analyze.log` — 19 dosya/0.
- `/private/tmp/larenor-media-confirmation-ui-format-check.log` — 11 dosya/0.
- `/private/tmp/larenor-media-confirmation-final-coverage.info` ve
  `/private/tmp/larenor-media-confirmation-coverage-summary.json` — kapsam.
- `/private/tmp/larenor-media-confirmation-command-manifest.json` — son
  formatter/analyze/test argümanları.

Bağımsız inceleme: skill_package_review root'un `f916729` provider/core-test
kaynağını salt okunur değerlendirdi; dar farkta açık P1/P2 yok. Root da
`a3d0409` on ekran farkını ve gerçek PIN 14 senaryosunu bağımsız okudu;
UI incelemesi CLEAR. Bu incelemeler sonraki kod veya diğer pilotlara
aktarılmış kabul değildir.
