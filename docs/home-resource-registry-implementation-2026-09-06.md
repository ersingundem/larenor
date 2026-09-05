# S08.6 — Ev kaynak kaydı ve hesap bazlı erişim sözleşmesi

**6 Eylül 2026 · Üretim kaynağı: `133786e58e2015a80a3b1b1d73c0e1c7c67442ac`.**
İzole dal `codex/home-resource-registry`, taban `07ac473`.
Bu belge [genişleme planındaki](feature-expansion-plan-2026-09-05.md) S08.6'nın
kalıcı kayıt ve HTTP API dilimini kaydeder; S08.6'nın tamamının kabulü değildir.

Larenor Server'ın mevcut tek Core/ev bağlamında oda ve kaynak metadatası artık
kalıcı olarak saklanır. Admin kayıtları ve açık kullanıcı izinlerini yönetir;
hazır, geçerli oturumu olan üyeler yalnız izinli kayıtları listeleyip okuyabilir.
Kimliği Server üretir, yeniden adlandırma ve restart aynı kimliği korur.
Client yönetim arayüzü ve gerçek cihaz komutları bu dilimde yoktur.

## Kimlik ve yetki sınırı

`ResourceRef`, `schemaVersion: 1`, `coreId`, `homeId`, `kind` ve `id` alanlarından
oluşur. `kind` yalnız `room` veya `resource` olabilir. Core/ev kimlikleri mevcut
[kalıcı bağlamdan](core-context-implementation-2026-09-05.md) gelir; yeni kayıt
kimliği Server'ın ürettiği 32 küçük hex karakterli UUID'dir. Client ID, sahip,
upstream URL/kimlik, dosya yolu, token veya keyfi seçenek enjekte edemez.

Grant subject mevcut `users.id` hesap kimliğidir. Bu bir HA `person` kimliği,
hesapsız hane kişisi veya aile profili değildir. Ayrı hane kişi modeli ve
sağlayıcıya değişmez kaynak bağlama sonraki dilimlere kalır. Kasa, hesap,
oturum ve servis kimlik bilgileri kayıt türlerine dahil değildir; admin rolü
başkasının kişisel kasasını açmaz.

`permissions` kesin boolean `read` ve `write` alanlarını taşır; `write=true`
ancak `read=true` ile geçerlidir. Admin kayıt/ACL yönetimini yapar. Üyenin
`write` izni gelecekteki komut sözleşmesi için saklanır; bugün yalnız izin
kararı olarak tüketilir, cihaz işlemi veya komut endpoint'i sağlamaz.
Süreç içi `authorize()` güncel kontrol yapar ve taşınabilir bir yetki belgesi
döndürmez. Her ilerideki gerçek işlem kendi güncel yetki kontrolünü gerektirir.

Kayıt metadatasının `revision` değeri ile `aclRevision` ayrıdır. Gerçek
ad/sıra değişikliği yalnız kayıt revision'ını, gerçek izin değişikliği yalnız
ACL revision'ını artırır. Böylece yeniden adlandırma geçerli grant'leri
kalıcı olarak iptal etmez; eski revision taşıyan devam eden istek reddedilir.
Değişiklik içermeyen yazmalar revision artırmaz.

## Tüketilen HTTP API

Aşağıdaki yollar `/api/v1` altındadır. `core_id` ve `home_id`, veritabanı
işlemi içinde Server'ın yetkili bağlamıyla eşleşmelidir; başka Core/ev admin
için de 404'tür. İlk parolasını değiştirmemiş, iptal edilmiş, süresi dolmuş
veya devre dışı kullanıcı oturumları kabul edilmez.

| Yol ve yöntem | İstek / sonuç |
| --- | --- |
| `GET /home-resources/{core_id}/{home_id}` | `limit` 1–100, varsayılan 25; isteğe bağlı `after` ve `expectedSnapshot`. Sonuç `{scope,entries,snapshot,nextAfter}`. |
| `GET /home-resources/{core_id}/{home_id}/{record_id}` | `{record}`; erişilemeyen ve eksik kayıt aynı 404 yanıtıdır. |
| `POST /admin/home-resources/{core_id}/{home_id}` | `{kind,label,order}` → 201 `{record}`. |
| `PATCH /admin/home-resources/{core_id}/{home_id}/{record_id}` | `{expectedRevision,expectedAclRevision,label,order}` → `{record}`. |
| `DELETE /admin/home-resources/{core_id}/{home_id}/{record_id}` | Query'de `expectedRevision` ve `expectedAclRevision` → 204. Yalnız yerel kayıt ve grant'leri silinir. |
| `GET /admin/home-resources/{core_id}/{home_id}/{record_id}/grants` | `{grants,aclRevision}`. |
| `PUT /admin/home-resources/{core_id}/{home_id}/{record_id}/grants/{subject_id}` | `{expectedAclRevision,permissions}` → `{grant}`. `read=false,write=false` açık grant'i kaldırır. |

Kayıt yanıtı `{ref,label,order,revision,aclRevision,permissions}`, grant yanıtı
`{subjectId,target,aclRevision,permissions}` biçimindedir. `target`, kayıt
referansıdır. Fazla alanlar ve tür dönüşümleri reddedilir. Etiket trim sonrası
1–80 karakterdir; kontrol/surrogate karakter içeremez. `order` 0–10.000,
revision'lar 1–2⁶³−1 aralığında kesin tam sayıdır. Küçük metadata istekleri
mevcut 8 KiB gövde sınırına uyar. Şema korumalı OpenAPI'ya ve gerçek app/core
başlangıcına bağlanmıştır; yalnız kullanılmayan saf tipler değildir.

## Gizli etkinliği açıklamayan sayfalama

Bağımsız inceleme ilk sürümde bir P2 buldu: üyeye dönen genel
`registryRevision`, görünmeyen kayıtlardaki değişiklik sayısını açıklıyor ve
bu değişiklikler üyenin ikinci sayfasını gereksiz yere geçersiz kılıyordu.
Public alan kaldırıldı. `snapshot` ve `expectedSnapshot` şimdi 64 küçük hex
karakterli, opak HMAC-SHA256 değeridir.

HMAC'ın ayrı alanı `larenor:home-resource-visible-snapshot:v1` olur. Yetkili
Core/ev, güncel kullanıcı ID/revision'ı ve ID sırasındaki **bütün görünür
public kayıtlar** canonical JSON ve uzunluk önekleriyle bağlanır. Yalnız
geçerli sayfa hash'lenmez; `after` ve sayfa boyutu snapshot'ı değiştirmez.
İç genel sayaç ve gizli kayıtlar public snapshot'a girmez. Token bir erişim
yetkisi değildir; aynı işlemde güncel oturum ve ACL yine kontrol edilir.

`after` varsa `expectedSnapshot` zorunludur. Görünür metadata/izin değişirse
eski snapshot 409 alır. Gizli kayıt veya gizli ACL değişikliği aynı üyede
aynı snapshot'ı ve ikinci sayfayı korur. Başka kullanıcı, başka Core/ev veya
yeni kullanıcı revision'ı eski snapshot'ı kullanamaz. Normal token yenileme
ve restart aynı görünümü korur. Güncel snapshot ile eksik ve görünmeyen
cursor aynı 404 yanıtını verir. `133786e` üzerindeki tekrar inceleme bu
bulgunun kapandığını doğruladı.

## Kalıcılık ve sınırlar

Yeni [home_resources](../server/larenor_server/home_resources/) paketi yedi
modülden oluşur: `__init__.py`, `models.py`, `authorization.py`, `api_models.py`,
`schema.py`, `service.py`, `api.py`. Mevcut `app.py` ve `core.py` için toplam
yedi satırlık kayıt/migration bağlantısı eklendi. Auth, kasa, mevcut bağlam
ve temel database modüllerinin üretim sözleşmeleri değiştirilmedi.

Başlangıç kilidi ve işlemi altında ayrı `home_resources_schema=1` işareti ve
üç tablo kurulur: `home_resource_records`, `home_resource_state`,
`home_resource_audit`. Etiket, sıra ve grant haritası mevcut özel kasa anahtarı
ile AES-GCM şifrelenir; ayrı AAD, şema/Core/ev/kayıt ID/tür/metadata revision/ACL
revision bağlarını içerir. Genel bütünlük revision'ı ve kayıt/grant sayıları
ayrı HMAC ile korunur; bu sayılar public yanıtta yoktur. Bilinmeyen migration,
tablo şekli, eksik kayıt veya bozuk şifreli içerik sessizce yeniden yaratılmaz.

En fazla **512 kayıt**, kayıt başına **128 grant**, toplam **4.096 grant** ve
**10.000 audit satırı** tutulur. Başlangıç ve liste doğrulaması satırları
biriktirmeden en fazla 513 kayıt tarar; sayfalama en fazla 101 public kayıt
tutar. Şifreli kayıt 32 KiB ile sınırlıdır. Güncel auth/kullanıcı revision'ı,
rol, yetkili bağlam, hedef ve ACL aynı `BEGIN IMMEDIATE` işlemi içinde
tekrar okunur. Yarışan ACL yazmalarından yalnız doğru revision sahibi kazanır.

Hatalar sabit API kodlarıdır; şifreli içerik, etiket veya dış hata yanıtı
mesaja eklenmez. Depolama bozulması başlangıçta
`home_resource_storage_invalid`, HTTP'de `server_unavailable` olarak kapanır.
İçerideki bozuk kimliğin Client'ın `invalid_request` hatası gibi sunulması da
ayrı RED→GREEN regresyonuyla düzeltildi.

## TDD ve gerçek test kanıtı

| Checkpoint | Gerçek sonuç |
| --- | --- |
| RED `b366c39` → GREEN `2ad9126` | Eksik model/policy modülleriyle **46 fail**, ardından **46 PASS**. İlk RED commit açıklamasındaki 47 sayısı yazım hatasıdır; log 46'dır. |
| RED `412e5b2` → GREEN `f29f5f9` | Gerçek HTTP/auth/SQLite akışında eksik route nedeniyle **35 fail**, ardından ilk toplam **81 PASS**. |
| RED `7f45518` → GREEN `9f888bc` | Bozuk iç kimlik/state revision için **2 fail, 28 PASS**; düzeltmeyle toplam **111 PASS**. |
| Fixture düzeltmesi `e7cccd6` | Eski şema fixture'larında **5 fail, 26 PASS** → **31 PASS**; üretim bütünlük kontrolü gevşetilmedi. |
| RED `b5ebf5f` → GREEN `133786e` | Gizlilik/snapshot için **6 fail** → ilk toplam **116 PASS**; ek refresh/restart/ACL/token/cursor vakalarıyla son toplam **124 PASS**. |

İlk geniş koşu **2.888 PASS, 5 fail, 10 skip** verdi. Beş hata, yeni Server
üzerinden şema 1/2 taklidi yapan testlerin yeni kayıt tablolarını eski Core
kimliğine bağlı halde bırakmasından geliyordu. Gerçek şema 1/2 bu tabloları
hiç içermediğinden yalnız test fixture'ları üç kayıt tablosunu ve kendi
migration işaretini kaldıracak biçimde düzeltildi. Hesap, oturum, kasa ve
anahtar koruma/rollback kontrolleri devam eder. Başarısız koşu başarı sayılmaz.

Son kaynak `133786e` üzerinde toplanıp çalıştırılan odaklı dosyalar:

| Dosya | Test sayısı |
| --- | ---: |
| [test_home_resource_models.py](../server/tests/test_home_resource_models.py) | 30 |
| [test_home_resource_authorization.py](../server/tests/test_home_resource_authorization.py) | 16 |
| [test_home_resource_registry.py](../server/tests/test_home_resource_registry.py) | 35 |
| [test_home_resource_registry_safety.py](../server/tests/test_home_resource_registry_safety.py) | 30 |
| [test_home_resource_snapshots.py](../server/tests/test_home_resource_snapshots.py) | 13 |
| **Toplam** | **124** |

Bu 124 test **42,03 saniyede geçti**. Dal dahil coverage **%95**
(423/437 statement, 108/122 dal; birleşik %94,991). API/model/policy/schema
modülleri %100'dür. Gerçek HTTP oturumları, geç gelen ACL iptali/admin
demotion, logout/disable/password reset, revision yarışı, restart, bağlam
değişimi, şifreli satır nakli, kota ve yerel silme sınırları kapsanır.

Gizlilik düzeltmesi **sonrasında yeniden çalıştırılan tam Server**:
**2.906 PASS, 10 Linux'a özgü Mac skip, 2 mevcut Starlette deprecation uyarısı**,
251,36 saniye, exit 0. Python 3.12.14'ün gerçek izole worktree import yolu
doğrulandı; Java 17.0.20.1 ve SHA-256 değeri
`562cd0a88890960d2ece48e116c61f12872222f1dcc306890799382bc019b201`
olan apksig 9.1.0 kullanıldı. 124 odaklı test ve 31 migration/bağlam testi bu
genel toplamın içindedir; toplamlar birbirine eklenmez. `git diff --check`
temiz ve bağımsız kaynak/snapshot incelemesinde açık bulgu kalmadı.

Yerel kanıtlar:

- `/private/tmp/larenor-home-resource-delivery-evidence.json`
- `/private/tmp/larenor-home-resource-all-server-green.log`
- `/private/tmp/larenor-home-resource-final-coverage.log`
- `/private/tmp/larenor-home-resource-coverage.json`
- `/private/tmp/larenor-home-resource-migration-green.log`
- `/private/tmp/larenor-home-resource-snapshot-red.log`

Bu sonuçlar uzak CI, iki mimarili yeni imaj, yeni imzalı APK veya fiziksel
ev/tablet kabulü yerine geçmez. Bu dilimde push, deploy, gerçek HA/cihaz veya
medya servisi işlemi yapılmadı. Client kayıt/ACL arayüzü, hane kişi profilleri,
HA importu, değişmez upstream binding ve gerçek komut uygulaması sonraki
işlerdir; otomatik olarak tamamlanmış sayılmaz.
