# F17 gerçek silmeye kapalı uzak hedef — 30 Eylül 2026

Core'un önceki HTTPS `/v1/append` istemcisinin karşısında çalışan servis yoktu. Ayrı hedef servisi artık `larenor-append-backup-target` veya `python -m larenor_server.core_backups.append_target` ile çalışır. SQLite üzerinde atomik append, HMAC korumalı byte/kayıt kotası, aynı object/digest/payload için kalıcı idempotency ve backend minimum saklama süresi uygular. Yazma tokenı okuyamaz; recovery tokenı yazamaz. HTTP delete/overwrite/prune yeteneği yoktur; saklama süresinin geçmesi silme yetkisi vermez. Hedef yöneticisinin erişimi ayrı fiziksel/yönetim sınırıdır, mutlak WORM iddiası değildir.

## Protokol ve ürün yolu

Bu **Larenor append-only v1** protokolüdür, restic REST değildir. [Resmî restic REST sözleşmesi](https://github.com/restic/restic/blob/master/doc/REST_backend.rst) farklı endpoint ve içerik türü kullanır; [rest-server append-only seçeneği](https://github.com/restic/rest-server) bağımsız restic deposu içindir. Core mevcut şifreli Larenor arşiv formatını saklar.

Günlük scheduler gerçek HTTPS POST yapar. Tam SHA-256/uzunluk/object/retention/kota makbuzu doğrulanır; kayıp cevap aynı object id ile tekrar okunabilir append işlemidir, overwrite yapılmaz. Hedef daha uzun saklama uygularsa kabul edilir. Nesne başına sınır **64 MiB**, hedefte en fazla **10.000 nesne**; kota dolarsa yeni append reddedilir. Boyut hatası açık kalır, sahte başarılı yedek üretilmez.

Admin Client uzak restore point listesinde **Bu şifreli kurtarma noktasını kaydet** ile OS dosya hedefi seçer. Core güncel admin/oturum ve hedef revizyonunu doğrular, ayrı recovery kimliğiyle gerçek TLS GET yapar, makbuz SHA/byte-length ile şifreli bundle bütünlüğünü/açılabilirliğini kontrol eder, yetkiyi tekrar doğrular. Flutter sınırlı stream, format/SHA/uzunluk ve iptal kontrolleri sonrasında dosyayı commit eder. Canlı Core üzerine restore yapılmaz; indirilen dosya mevcut `larenor-server --restore BUNDLE --restore-passphrase-file FILE` boş-Core kurtarma yolunun girdisidir. Hedef revizyonu değişen eski point indirme için reddedilir; eski hedef kurtarma bilgisi ayrı saklanmalıdır.

## Ayrı hedef kurulumu

`deploy/larenor-server/append-target.compose.yaml` aynı exact kaynak revizyonlu Server image içinden TLS hedefini başlatır. Core ev sunucusundan ayrı NAS/uzak sistem üzerinde kullanılır. Image/root filesystem salt okunur; uid 10001, capabilities kapalı, 512 MiB/1 CPU/32 pid sınırı vardır. Varsayılan Core healthcheck bu ayrı servise uygulanmaz; deployment doğrulaması authenticated append + recovery readback ile yapılır.

Operator `/var/lib/larenor-backup-target/data` ve `secrets` dizinlerini uid 10001'e ait 0700 olarak hazırlamalı; bütün policy/key/TLS dosyaları aynı kullanıcıya ait 0600 normal dosya olmalıdır. Tokenlar komut satırına/environment'e konmaz. `/secrets/target.json` strict yapı:

```json
{
  "contractVersion": 1,
  "targetId": "home-backup",
  "dataDirectory": "/target-data",
  "sealKeyFile": "/secrets/target.key",
  "writeToken": "<separate random printable token, 32-512 characters>",
  "recoveryToken": "<different random printable token, 32-512 characters>",
  "quotaBytes": 10737418240,
  "minimumRetentionDays": 30
}
```

Bu şablon aktif yapılandırma değildir. `target.key` 32 rastgele byte olmalı; kayıp anahtar sessizce yenilenmez. `tls.pem` güvenilir CA tarafından hedef host adına imzalanmış sertifika, `tls.key` özel anahtardır. Core'un TLS trust store'u bu CA'yı güvenmelidir; insecure TLS modu yoktur. Core ekranındaki hedef kimliği, quota ve tokenlar policy ile aynı olmalı. `--check-config` private policy/anahtar/TLS eşleşmesini doğrular, yeni depo oluşturmaz. Gerçek başlangıç mevcut deponun sealed ledger ve object hashlerini doğrular; bozuk depo sessizce reset edilmez.

## Kanıt

`PYTHONPATH=server server/.venv/bin/python -m pytest -q server/tests/test_f17_append_target.py`: **7 passed**. Gerçek localhost TLS/HTTP append+recovery, kalıcı restart, değişik içerik reddi, ayrı token yetkisi, ledger/payload bozulması ve normal Core günlük export→TLS hedef→authenticated download→gerçek boş Core restore/start sınanır. Core hedef rotasyonu/member indirmesi reddedilir; hazırlanmış bir yedeğin retry gönderimi de kuran admin revizyonunu yeniden doğrular, erişim iptalinden sonra uzak I/O yapılmaz.

`flutter test test/features/server/server_core_backups_test.dart test/features/server/server_core_backups_screen_test.dart`: **38 passed**; sınırlı indirme destination commit'i öncesi exact receipt/digest ve iptal regresyonları dahil. Scoped analyze temiz. SafeBoundary güvenlik başlıklarının iki kez eklenmesi giderildi; 12 boundary regresyonu geçti. Tam current-HEAD CI, bağımsız geniş kabul ve gerçek ayrı hedef/cihaz kurulumu açık kalır; bu dilim kabul sayacını artırmaz.
