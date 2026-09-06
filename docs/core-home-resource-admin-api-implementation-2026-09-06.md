# S08.6 — Client kayıt metadata mutasyon API'si

6 Eylül 2026. İzole `codex/home-resource-admin-api` dalı,
`1b260ce03194b4a74b98e0cdb9988e7843e0830e` birleşik kaynağından açıldı.
Üretim checkpoint'i `117b34f47fa5b2dfaa46efa3d3ebffa050c941f6`.

Bu dilim **henüz ekrana/controller'a bağlanmamış bir Client transport
sözleşmesidir**. Yönetici ekranı, PIN/lifecycle eylem yetkisi veya bütün S08.6
kabulü değildir. Mevcut Core/ev registry'sindeki oda/kaynak metadata'sını
kullanır; cihaz komutu, HA import, kullanıcı profili, kişisel vault veya
credential yönetimi eklemez. Server üretim kodu ve mevcut salt okunur liste
modeli/controller'ı/ekranı değiştirilmedi.

## Public Dart arayüzü

`lib/features/home_resources/data/home_resource_admin_api.dart`:

```dart
HomeResourceAdminApi(LarenorServerApi api, String token, ServerContext context)
Future<HomeResourceRecord> create({
  required HomeResourceKind kind,
  required String label,
  required int order,
})
Future<HomeResourceRecord> update(HomeResourceRecord target, {
  required String label,
  required int order,
})
Future<void> delete(HomeResourceRecord target)
```

Endpoint, token ve bağlı context private alanlardır; `toString` yalnız statik
sınıf adı verir. `HomeResourceMetadata(label:, order:)` immutable yerel istek
değeridir; herhangi bir auth yetkisi taşımaz. Kind yalnız mevcut `room` veya
`resource` enum'udur. Güncelleme/silme hedefi mevcut strict immutable
`HomeResourceRecord` olduğundan id, kind ve pozitif 64-bit revision alanları
serbest string/map olarak alınmaz. Farklı Core/ev hedefi HTTP'den önce reddedilir.

Label Server ile aynı şekilde 1–80 Unicode codepoint; C0/DEL/surrogate
değerleri yasak, Python `str.strip` ile uyumlu kenar whitespace normalizasyonu
uygulanır. Uzunluk kontrolü strip öncesidir. BOM sıradan label içeriğidir.
Order `0..10000` tamsayısıdır. Geçersiz yerel metadata statik
`invalid_request` verir ve HTTP başlatmaz. `toJson()` yeni bir map döndürür;
çağıranın map değişikliği saklanan immutable metadata'yı değiştirmez.

## HTTP ve yanıt bağlama

| İşlem | Yol (`/api/v1` altında) | İstek |
|---|---|---|
| Oluştur | `POST /admin/home-resources/{core}/{home}` | `kind`, normalize `label`, `order` |
| Düzenle | `PATCH /admin/home-resources/{core}/{home}/{id}` | `expectedRevision`, `expectedAclRevision`, `label`, `order` |
| Sil | `DELETE /admin/home-resources/{core}/{home}/{id}` | İki expected revision query alanı; body yok |

Yeni UUID'yi Server üretir; Client oluşturma isteği id/owner/ACL göndermez.
RecordResponse yalnız `record` alanını kabul eder. Mevcut strict read parser
Core/ev/id/kind/label/order/permission/revision şekillerini doğrular. Yeni
wrapper ayrıca gönderilen kind, normalize metadata ve update hedef id'sini
bağlar. Oluşturmada record/ACL revision ikisi de 1 ve admin response permission
read/write olmalıdır. Değişen metadata record revision'ı tam bir artırır;
no-op aynı revision'ı tutar. İkisinde de ACL revision aynı kalmalıdır.

Shared `LarenorServerApi` değişikliği yalnız exact home-resource DELETE
yolunun iki query alanıdır. Her iki değer kanonik `1..9223372036854775807`
ondalık metnidir; eksik/null/boş query, ek alan, farklı yol, bozuk id, son
newline, işaret/boşluk/sıfır/leading-zero/ondalıklı/taşan değerler HTTP'den önce
reddedilir. Mevcut services DELETE tek-revision sözleşmesi değişmedi.

Silme yalnız shared decoder'ın **gerçek 204 + boş body** sonucu null ise
başarılıdır. 200 null, 200 boş veya obje, 202 boş, 204 body ve hata yanıtı başarı
sayılmaz. POST/PATCH için mevcut shared decoder'ın 2xx JSON davranışı korunur;
bu paket genel HTTP status API'sini değiştirmez, exact payload'ı bağlar.

Server her çağrıda current admin/session/context/revision denetimini yapar.
Client'taki write ACL admin rolünün kanıtı değildir. API UI yetkisi üretmez;
sonraki controller onu account/session ve güncel Core/PIN/route/lifecycle
kapsamına bağlamalıdır. Otomatik tekrar yoktur: timeout veya kapatılmış
transport sonrası geç yanıt, yazının gerçekleşmediği anlamına gelmez. Yeni
create isteğini otomatik tekrarlamak veya silmeyi varsayımsal başarılı saymak
bu sözleşmenin parçası değildir. Registry silme hiçbir upstream/disk/konteyner
silme işlemi yapmaz.

## Gerçek Server fixture ve doğrulama

Yeni `contracts/home-resource-admin.v1.json`, production FastAPI/auth/SQLite
üzerinden oluşturma → gerçek member ACL → ad değişikliği → no-op → stale409 →
member403 → silme204 → bulunamayan404 sırasını içerir. Yalnız context/kayıt UUID
üretimi sentetik sabitlenir; auth/encryption/ACL/service kodu gerçektir. Token,
parola, private key, ciphertext, subject/grant listesi export edilmez.
Server fixture test'i çıktının aynı dosyayla eşleştiğini tekrar üretir.
Client testi aynı fixture'ın gerçek istek body/query/path ve response'larını
beş adımlı MockClient dizisinde kullanır. Önceki read-only v1 fixture'ı
değiştirilmedi.

| Checkpoint | Kanıt |
|---|---|
| `1662c8e` RED | Gerçek Server akışı 1 PASS; eksik fixture nedeniyle 1 FAIL |
| `2dc7140` GREEN | Versioned metadata fixture; iki Server testi PASS |
| `67c0349` RED | Derlenmiş Client runtime: 42 PASS / 44 FAIL; güvenli stub yalnız statik hata veriyordu |
| `117b34f` GREEN | 87 odaklı Client testi PASS; API/model ve dar shared query uygulaması |

İlk minimal GREEN denemesinde 85 PASS / 1 FAIL, MockClient fixture'ının close
sonrasında henüz verilmemiş response'u beklemesinden kaynaklandı. MockClient
AbortableRequest iptalini uygulamaz: fixture geç response'u açıkça serbest
bırakıp gerçek decoder'ın cancelled sonucunu doğrulayacak şekilde düzeltildi.
Ayrı timeout testi, tek POST sonrası geç response geldiğinde otomatik tekrar
olmadığını doğrular; shared transport cancellation davranışı değiştirilmedi.

Odaklı LCOV, yeni API/modelde **64/64 = %100 satır** (48/48 + 16/16) verir;
branch coverage iddiası değildir. Ortak API'nin eski tüm endpoint satırları
yeni modül coverage oranına dahil edilmez.

- **87 odaklı Client testi PASS.**
- **656 ilişkili Client testi PASS**, 29 saniye: bütün home_resources ve
  Server Client testleri; yeni odaklı küme dahildir, sayılar toplanmaz.
  Bu koşuda shared API coverage 206/214 satırdır.
- **40 Server testi PASS**: yeni admin fixture, mevcut read-only fixture ve
  gerçek registry HTTP/auth/SQLite regresyonları; yeni iki fixture testi bu
  sayıya dahildir. Ayrı tam Server/Client veya yeni CI geçişi iddiası yoktur.
- **5 dosya analyze: 0 bulgu; formatter: 0 değişiklik.** `git diff --check`
  temizdir. Server üretimi ve önceki read-only fixture/model/UI değişmedi.

Kanıt öneki `/private/tmp/larenor-home-resource-admin-`: `red.log`,
`green.log` (ilk fixture hatası), `final-green.log`, `contract-red.log`,
`contract-green.log`, `server-related.log`, `related.log`, `analyze.log`,
`format-final.log`, `related-coverage.info`, `delivery-evidence.json`.

Canlı ev/HA/Core/Proxmox bağlantısı, cihaz komutu, gerçek kullanıcı verisi,
kurulum veya publish yapılmadı. Bu izole dal push edilmedi; yeni API'nin
uygulama UI'sine bağlanması ve birleşik exact CI ayrı sonraki adımlardır.
