# Core oda arşivi — ayrı şifreli codec

6 Eylül 2026. Taban `80996cdf`, [kapalı model sözleşmesi](core-layout-archive-contract-2026-09-06.md).
Bu dilim yalnız `CoreLayoutArchiveCodec` ve testlerini ekler. Eski
`BackupCodec`, dış backup v1/v2, private journal, `ConfigurationScope`,
dashboard repository ve model biçimi değiştirilmedi. Dosya okuyucusu,
secret store, ekran, restore veya S08.5 kabulü değildir.

Kaynak: [core_layout_archive_codec.dart](../lib/features/home_scope/data/core_layout_archive_codec.dart).
Test: [core_layout_archive_codec_test.dart](../test/features/home_scope/core_layout_archive_codec_test.dart).

## API ve format

`encrypt(CoreLayoutArchiveV1, passphrase)` şifreli `Uint8List` üretir;
`decrypt(Uint8List, passphrase)` yalnız doğrulanmış `CoreLayoutArchiveV1`
döndürür. Decode kapsam/oturum veya restore yetkisi vermez. Yeni format
ayırt edicisi tam `larenor-core-layout-archive`, zarf sürümü tamsayı `1`dir.
Eski `larenor-vault` için fallback yoktur; iki codec karşılıklı olarak diğer
biçimi reddeder. Dosya uzantısı veya dosya seçici bu API'de tanımlanmaz.

Repo içinde kullanılan `cryptography` 2.9.0 primitive'leri ve mevcut
BackupCodec yaklaşımı korunur: PBKDF2-HMAC-SHA256, sabit 600000 iterasyon,
256 bit anahtar; AES-256-GCM, 16 bayt salt, 12 bayt nonce, 16 bayt tag.
Salt `Random.secure`, nonce cipher'ın varsayılan güvenli RNG'si ile her
encryption'da yeniden üretilir. Üretim API'sinde anahtar, salt, nonce,
algoritma veya iterasyon injection parametresi yoktur.

Header tam `format/version/kdf/cipher` alanlarından oluşur. KDF yalnız
`name/iterations/salt`, cipher yalnız `name/nonce` içerir. Canonical header
JSON'unun UTF-8 baytları AAD'dir; format ayrımı da böylece doğrulanır. Zarf
ayrıca yalnız `ciphertext/tag` içerir. Bilinmeyen alanlar, yanlış tipler,
algoritma/maliyet değişimleri ve standart padded Base64 dışındaki gösterimler
KDF başlamadan reddedilir. JSON anahtar sırası ve whitespace aynı anlamsal
header'ı değiştirmez; Base64URL, eksik padding, yüzde kaçışları ve canonical
olmayan pad bitleri kabul edilmez. Ciphertext boyu plaintext sınırını aşamaz.

Şifreli giriş ve çıkış **3 MiB**, plaintext **2 MiB** ile sınırlıdır. Tam
sınırlar olumlu, sınır aşımı olumsuz testlerle doğrulanır. Bu limitler tüm
codec işleminin toplam bellek bütçesi veya henüz olmayan streaming file IO
garantisi değildir. Girdi baytları asynchronous KDF öncesinde parse edilip
kopyalanır; çağıranın daha sonraki buffer değişimi kabul edilen zarfı değiştirmez.

KDF ve AEAD worker isolate içinde çalışır. Anahtar için `destroy()` ve elde
tutulan plaintext byte buffer için `finally` içinde sıfırlama çağrılır.
Immutable Dart String, runtime/crypto iç kopyaları veya caller passphrase
belleğinin tamamen silindiği iddia edilmez.

Parola en az 12 Unicode rune ve en fazla 1024 UTF-8 bayttır; eşleşmemiş UTF-16
surrogate kod birimleri reddedilir. Geçerli Unicode, boşluk veya birleştirilmiş karakterler
normalize edilmez. `validatePassphrase(..., settingsPin: ...)` sağlanan PIN
ile birebir aynı parolayı reddeder; codec cihaz PIN'ini kendisi okumaz.
Gelecekteki UI bu kontrolü kendi güncel PIN sınırında çağırmalıdır.

Statik kodlar `invalid_passphrase`, `invalid_archive`, `archive_too_large`,
`decrypt_failed`, `encrypt_failed` şeklindedir. Yanlış parola ve AEAD bozulması
aynı `decrypt_failed` sonucudur. Header doğrulansa ve AEAD geçse bile içerideki
yanlış kind/version/unknown field/UTF-8 veya model hâlâ reddedilir. Hata metni
dosya içeriğini, oda adını veya parolayı yansıtmaz.

## TDD ve doğrulama

- RED `0b74ac8`: derlenen reject-only stub, **40 PASS / 15 FAIL**. Fixture,
  üretim codec'i dışında test-only sabit primitive/anahtar/nonce ile oluşturuldu.
- GREEN `7baf3ea`: aynı **55 PASS / 48 saniye**. Son değişiklikler yalnız
  format ve iki `if` bloğunun brace düzenidir.
- Birleşik **168 PASS**: yeni 55 codec + 98 model + 15 eski BackupCodec testi.
  Kümeler üst üste eklenmez; tek birleşik koşudur.
- Yeni codec satır kapsaması **87/89 = %97,75**; dal kapsaması ölçülmedi.
  İki hedefte analiz temiz, iki dosyada son format kontrolü değişikliksiz.
- Root `7baf3ea` bağımsız kaynak incelemesi CLEAR; yeni P1/P2 yok.

Olumlu testler gerçek bağımsız kriptografik fixture, Unicode roundtrip,
taze salt/nonce, caller-isolate timer ilerleyişi, mutable girdi izolasyonu,
2 MiB doğrulanmış plaintext ve 3 MiB dosya sınırını kapsar. Olumsuz testler
yanlış parola, görsel olarak benzer farklı Unicode, salt/nonce/ciphertext/tag
bozulması, eski formatı yeniden etiketleme AAD saldırısı, kırpılmış/bozuk
dosya, exact header/cost/Base64 ve doğrulanmış fakat geçersiz model içerir.

SDK komutları ortak `python3 /private/tmp/larenor-flutter-check.py` kilidiyle
çalıştırıldı. Odak komutu `flutter test --no-pub test/features/home_scope/core_layout_archive_codec_test.dart --reporter expanded`;
coverage koşusu `--coverage` ile aynı teste `test/features/home_scope/core_layout_archive_test.dart`
ve `test/features/backup/backup_codec_test.dart` ekledi. Özel loglar
`/private/tmp/larenor-core-codec-{red,green,related-final,analyze,format-check}.log`.

Sonraki teslim ayrı sınırlı dosya IO, canlı capture/preview/confirmation,
aynı Core/ev/kullanıcı + hedef revision/fingerprint bağı ve typed handoff /
durable scoped kayıt adapter'ıdır. Bu codec kaynaklararası eşleme, otomatik
retry, kalıcı yazı veya journal recovery yapmaz. Gerçek ev/cihaz/Server,
Android yolculuğu, CI veya imzalı APK bu yerel codec testlerinden çıkarılmaz.
