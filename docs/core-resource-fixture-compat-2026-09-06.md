# Mevcut Core test hesabı ve kaynak listesi uyumu

Çalışma dalı `codex/core-resource-fixture-compat`, worktree
`/private/tmp/larenor-core-resource-fixture-compat`, başlangıç kaynağı
`20d92d7144998e40eb465887ef3fcac681dab39e`.

Android 97 koşusunda dört native test ve yedi uygulama yolculuğundan toplam
10 test geçti, bir test başarısız oldu. `scoped_layout` yolculuğu son veri
kontrolüne ulaştı; kapanışta mevcut admin fixture'ın tanımadığı dört kaynak
listesi isteği nedeniyle `rejectedRequests == 0` kontrolü başarısız oldu.
Yeni `core_resources` yolculuğu geçti. APK işi atlandı; bu değişiklik henüz
gerçek emülatörde doğrulanmış sayılmaz.

## Dar değişiklik

`SyntheticCoreAccount` mevcut admin kullanıcı kimliğini ve rolünü korur.
Kaynak kataloğu açıkça verilmemişse yalnız güncel Core/ev yolu için boş bir
liste sağlar. Bearer, GET, tam yol ve kapalı query doğrulaması korunur.
Yanlış ev, bilinmeyen alan, geçersiz limit/cursor/snapshot ve yazma fiilleri
reddedilir. Global kapanış assertion'ları, HA/ağ sayaçları, zaman aşımı ve
uygulama üretim kodu değiştirilmez.

Boş liste snapshot'ı sentetik domain + Core + ev + kullanıcı girdilerine
bağlıdır. Bu değer üretim Server HMAC'i veya yetki kanıtı değildir. Opt-in
üye kataloğu hâlâ gerçek Server HTTP ortak fixture'ını birebir kullanır.

## TDD ve doğrulama

- RED `61bc704`: gerçek loopback host testlerinde 8 PASS / 4 beklenen FAIL.
  Default admin kaynak GET'i 200 yerine 403 döndürdü.
- GREEN `1f7c6b4`: aynı iki test dosyası 12 PASS.
- Son dar regresyon: `test/integration_support` içinde 18 PASS; production
  `HomeResourcePage` parser'ı boş HTTP yanıtını kabul etti. Core A→B→A ve yeni
  fixture hesabında snapshot devamlılığı, actor/scope ayrımı ve çağıranın
  listeyi değiştirmesinin sonraki yanıtı etkilememesi doğrulandı.
- Dört ilgili dosyanın analizi: no issues. Format yalnız bu dört dosyada.

Komutlar ortak SDK kilidiyle çalıştırıldı:

```sh
python3 /private/tmp/larenor-flutter-check.py flutter test test/integration_support --coverage --coverage-path=/private/tmp/larenor-core-resource-fixture-coverage.info --reporter expanded
python3 /private/tmp/larenor-flutter-check.py flutter analyze integration_test/support/synthetic_core_account.dart integration_test/support/synthetic_core_resources.dart test/integration_support/synthetic_core_account_test.dart test/integration_support/synthetic_core_resources_test.dart
```

Yerel kanıtlar `/private/tmp/larenor-core-resource-fixture-{red,green,final,analyze,format}.log`.
Flutter'ın standart coverage çıktısı `integration_test/support` fixture
dosyalarını içermediğinden bunlar için sayısal coverage iddiası yoktur.
Host testleri gerçek loopback HTTP kullanır; Android yolculuğunun yeniden
geçtiği veya fiziksel cihaz kabulünün tamamlandığı iddia edilmez.
