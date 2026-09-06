# Kişi Core API'si: ortak sözleşme ve Client taşıma temeli

Bu teslim yalnız gerçek kişi HTTP sözleşmesi, ayrı immutable Dart kişi modelleri ve okuma/admin CRUD/ACL adapter'ıdır. UI, provider, polling, cache veya admin ekranı bağlanmadı; tüm S08.5/S08.6 kabulü ya da Android cihaz kanıtı değildir. Bir kişi profili oluşturmak hesap, HA person/entity bağı veya cihaz komutu oluşturmaz.

İzole dal `codex/home-people-client-contract`, çalışma ağacı `/private/tmp/larenor-home-people-client-contract`, taban `c0d814505227e894bb1eb9e884201517a185170c`. Source/test freeze `8ad72a0d6af41b41ea0c9808eecedb3f9a69b8b3`; global kuyruk/PROGRESS/main üzerinde değişiklik veya push yapılmadı.

## Gerçek Server sözleşmesi

`server/tests/test_home_people_contract.py`, geçici test Core'u, gerçek auth/parola değişimi, SQLite, şifreleme ve ACL kodunu kullanır. Yalnız sentetik vault anahtarı ve üretilen Core/home/hesap/kişi kimlikleri deterministiktir. `contracts/home-people.v1.json` gerçek yanıt ve istekleri byte-değer düzeyinde karşılaştırmak için üretildi; token, parola, ciphertext veya nonce içermez.

Sözleşmede ayrı `person` envelope, `ref.kind='person'`, `scope/entries/snapshot/nextAfter` sayfalaması, admin create/PATCH/DELETE204, read→read-write→no-op→revoke, member red/hidden davranışı, bozulmuş request, farklı Core/home ve gerçek logout sonrası 401 bulunur. İki kayıtla gerçek limit1 sayfaları aynı görünür HMAC snapshot'a bağlıdır. Diğer Core örneği aynı kişi kimlikleriyle farklı scope ve görünür etiketler içerir. 80 Unicode codepoint'lik örnek mevcuttur. Eski room/resource endpoint'i `person` türünü reddetmeye devam eder ve hesap listesi değişmez.

Aynı test dosyası doğrudan çalıştırıldığında yalnız sentetik geçici Core üzerinden fixture'ı yeniden üretir:

```sh
PYTHONPATH=server:server/tests /private/tmp/larenor-server-project-env/bin/python server/tests/test_home_people_contract.py
PYTHONPATH=server /private/tmp/larenor-server-project-env/bin/python -m pytest server/tests/test_home_people_contract.py -q
```

## Client sınırları

`HomePersonRecord`, `HomePeoplePage`, `HomePersonMetadata` ve `HomePersonGrants` ayrı tiplerdir; mevcut room/resource enum ve parser'ları genişletilmedi. Alan kümeleri kapalıdır; Core/home/ref, ID, schema int1, revision1..2^63−1, read/write ilişkisi, etiket ve cursor/snapshot doğrulanır. Kişi kapasitesi128, sayfa en çok100, ACL en çok128, order0..10000. Etiket en çok80 Python Unicode codepoint; C0/DEL/surrogate reddi ve Python strip kenarları mevcut Server ile eşleşir. C1/bidi/BOM için yeni, Server'dan farklı bir kural icat edilmedi. Koleksiyonlar ve metadata immutable kopyalardır; toString sır/etiket/URL taşımaz.

`HomePeopleApi`, mevcut `LarenorServerApi` nesnesini ödünç alır. Yeni HTTP client, kimlik bilgisi deposu veya logging yoktur. Ortak taşımanın başarılı gövde2MiB/hata8KiB, derinlik/anahtar/string sınırları, timeout ve redirect yasağı aynen kullanılır. Tek shared değişim yalnız tam kişi listesi ve DELETE yollarında sorgu allowlist genişlemesidir; grants/get-by-ID üzerinde sorgu kabul edilmez. DELETE iki revision ister. Client devam sayfasında snapshot'ı zorunlu tutar; otomatik sayfa birleştirme yapmaz.

Adapter oluşturulurken `isCurrent` zorunludur. Gelecek sahibi bunu yakalanmış session/generation/Core-home ve kendi görünürlük ömrüne bağlamalıdır; sabit true production yetki denetimi değildir. Adapter her effect öncesi, response/error await sonrası ve dış Future yayınlamadan önce kontrol eder. İlk false/throw veya explicit `retire()` sonrasında yeniden etkinleşmez. Gerçek Server yetkisi her istekte ayrıca gerekir; okunmuş `permissions` alanı admin veya cihaz yetkisi sağlamaz.

Retirement tamamlanmış veya dispatch edilmiş Server yazısını geri alamaz. Gecikmiş başarılı/hatalı cevap yayımlanmaz; mevcut borrowed auth transport'u kapatılmaz ve otomatik retry/replay yapılmaz. Aktif401 normal account rejection'a ulaşır; emekli adapter401 güncel hesabın hata işleyicisine geçirilmez. UI olmadığı için root/PIN/route giriş kapısı burada tamamlanmış sayılmaz.

## TDD ve doğrulama

| Dilim | RED | GREEN |
|---|---|---|
| Ortak gerçek HTTP fixture | `81828b7`:1 PASS/1 missing-fixture FAIL | `a5baa95`:2 PASS |
| Katı kişi modelleri | `883254d`:45 PASS/5 davranış FAIL, derlenen minimal stub | `9018512`:50 PASS |
| CRUD/grants/lifetime/query taşıması | `1f89a31`:7 PASS/10 davranış FAIL, derlenen adapter stub | `ccd7ea0`:17 PASS |
| Son sınırlar ve statik düzenleme | Ayrı üretim davranışı eklenmedi | `8ad72a0`:77 odaklı PASS |

Yeni worktree'nin ilk Flutter yüklemesi eksik ignored TileConfig/Dashboard generated dosyalarında durdu. Bu sonuç RED sayılmadı; ortak SDK kilidi altında `build_runner` tamamlanınca gerçek runtime RED alındı. Son analyzer'daki yerel brace/initializing-formal ve test underscore uyarıları düzeltildi; public `isCurrent` çağrı adı değişmedi.

- Python gerçek HTTP paritesi:2 PASS, `/private/tmp/larenor-people-contract-green.log`.
- Yeni kişi testleri:77 PASS, `/private/tmp/larenor-people-final-focused.log`.
- Önceki ilgili koşu:278 PASS/14 saniye; eski resource read/admin/grants/query ve Server context testleri dahil, `/private/tmp/larenor-people-related-green.log`.
- Son analiz:3 hedefte0 sorun (iki klasör ve shared API dosyası; toplam5 Dart dosyası), `/private/tmp/larenor-people-analyze-final.log`.
- Son format doğrulaması:5 dosya/0 değişiklik, `/private/tmp/larenor-people-format-check.log`.
- Yeni üretim satır kapsamı:model170/170 + adapter112/112 =282/282 (%100), `/private/tmp/larenor-people-final-coverage.info`. Bu satır ölçümüdür; branch veya cihaz kapsamı iddiası değildir.

Testler gerçek `ServerAccountController` ile logout sonrası geç200/401'i ve aktif401'in oturumu reddetmesini doğrular. Ek olarak yabancı scope, unknown fields, oversize yanıt, readonly/member ACL, grant no-op/revoke, tekPOST belirsiz503, dispatch edilmiş PUT sonrası retirement, revision tavanı, ACL128 kapasitesi ve no-retry kanıtı vardır. Client HTTP testleri sentetik MockClient kullanır; gerçek ağ veya ev sistemleri çağrılmadı. Bütün Flutter/Dart komutları `/private/tmp/larenor-flutter-check.py` üzerinden serileştirildi.

Özel makbuz: `/private/tmp/larenor-home-people-client-contract-delivery-evidence.json`. Bağımsız inceleme `8ad72a0` üretim/test/actual Server exporter için CLEAR: yeni P1/P2 yok. İncelemeci testleri yeniden çalıştırmadı; source ve mevcut log kanıtını okudu. Sonuç teslim makbuzunda da kaydedilir.
