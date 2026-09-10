# Sonarr/Radarr kalıcı yapılandırma işleri

Exact uygulama commit'i: `8a342f648bd7dc730d61650f3358998fedb8f4db`.

Larenor Server, Sonarr ve Radarr yapılandırmasını servis başına tekil, yönetici oturumuna bağlı ve otomatik tekrar yapmayan kalıcı işlerde tutar. API anahtarı Server içinde üretilir ve AES-GCM ile şifrelenir; public API, kayıt özeti ve hata yüzeyleri sırrı göstermez. Aynı hazırlık iki servisi ayrı ayrı yapılandırabilir, fakat aynı servis için ikinci belirsiz etki oluşturulamaz.

Dispatcher işi UID doğrulamalı installation worker kanalına gönderir. Yetki, plan, inspection ve catalog hem dispatch öncesi hem sonuç kaydından önce doğrulanır. Kesilen ya da sonucu belirsiz kalan işler `needs_attention` olur ve otomatik yeniden çalıştırılmaz. `installAvailable=false`; bu dilim container create/start veya gerçek servis readback kabulü iddia etmez.

## Doğrulama

- Yeni iş/API senaryoları: 5 test.
- İlgili binding, effect, runtime, IPC ve job paketleri: 253 PASS / 1 mevcut macOS skip.
- `compileall`, security policy, queue validation, diff check ve Gitleaks: PASS.
