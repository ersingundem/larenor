# Sonarr/Radarr kalıcı yapılandırma işleri

Exact uygulama commit'i: `935f70658bef6a5d20af2a9356b4ce3a9a7a31a4`.

Larenor Server, Sonarr ve Radarr yapılandırmasını servis başına tekil, yönetici oturumuna bağlı ve otomatik tekrar yapmayan kalıcı işlerde tutar. API anahtarı Server içinde üretilir ve AES-GCM ile şifrelenir; public API, kayıt özeti ve hata yüzeyleri sırrı göstermez. Aynı hazırlık iki servisi ayrı ayrı yapılandırabilir, fakat aynı servis için ikinci belirsiz etki oluşturulamaz.

Dispatcher işi UID doğrulamalı installation worker kanalına gönderir. Yetki, plan, inspection ve catalog hem dispatch öncesi hem sonuç kaydından önce doğrulanır. Kesilen ya da sonucu belirsiz kalan işler `needs_attention` olur ve otomatik yeniden çalıştırılmaz. `installAvailable=false`; bu dilim container create/start veya gerçek servis readback kabulü iddia etmez.

## Doğrulama

- Yeni iş/API senaryoları: 5 test.
- İlgili binding, effect, runtime, IPC ve job paketleri: 107 PASS.
- `compileall`, security policy, queue validation, diff check ve Gitleaks: PASS.
