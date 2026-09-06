# CI108 — Client ve Core teslim takibi

**Durum: Core ve güvenlik geçti; Android çalışıyor, Client teslimi henüz kabul edilmedi.** Yayın kaynağı `960691c113b10e08ebddf75d464b99e74bdd4cb1`. Bu commit public ana dala gönderildi; önceki CI106 tamamlandıktan sonra yeni paket başlatıldı. Yeniden çalıştırma yapılmadı.

| Kapı | Güncel bağlantı |
| --- | --- |
| Android108 | [34019042417](https://github.com/ersingundem/larenor/actions/runs/34019042417) — sonucu bekleniyor |
| Core34 | [34019042355](https://github.com/ersingundem/larenor/actions/runs/34019042355) — başarılı; 3.447 Linux testi, 0 skip |
| Security108 | [34019042181](https://github.com/ersingundem/larenor/actions/runs/34019042181) — başarılı; 207 politika testi |

Üç koşunun `headSha` değeri yukarıdaki yayın kaynağıdır. Yerel hazırlık worktree/dosya adlarındaki `package107` dahili hazırlık adıdır; GitHub çalışmasının numarası olarak kullanılmaz. Gerçek Android/Security çalışması108'dir.

## Yayın öncesi doğrulama

[Birleşim kontrolü](tablet-core-volume-integration-2026-09-06.md) `643cbdd` üzerinde **5150 Client PASS**, coverage açık, analiz0 ve971dosya biçim farkı0 verdi. Aynı Server ağacında tek tam Core **3435 PASS/12 Linux-only skip**;207 politika testi ve gizli bilgi taraması temiz. Yayın öncesinde10 çalışma kodu/test/CI/lockfile Git nesnesinin `960691c` ile test edilen kaynak arasında aynı olduğu tekrar doğrulandı. Sonraki farklar kanıt ve ilerleme belgeleridir; yeni tam test sayısı uydurulmadı.

Yeni paket, Core eklenti kataloğu ve iş geçmişi tablet kontrollerini, Backup/Vault/Archive modal hedef ve metin boyutlarını, arşiv iptali/People dönüşü için iki dar Android test beklemesini ve kalıcı özel volume create protokolünü içerir. Services ekranının sonraki dalı dahil değildir. `installAvailable=false` ve gerçek ev servislerinin salt okunur sınırı korunur.

## GitHub’dan doğrulanan sonuçlar

Core34 ilk denemede **3.447 PASS / 0 skip** verdi; JUnit raporu bağımsız okundu. Android işindeki aynı Server suite de geçti; iki koşudaki testler toplanmaz. Native Android/JVM raporunda **98 PASS / 0 skip** var. Güvenlik, gizli bilgi ve bağımlılık kontrolleri başarılı.

İki mimarili Core smoke kontrolleri ve anonim kaynak/lisans erişimi doğrulandı. Immutable ve stable OCI index aynı: `sha256:5e60fd827fe7549192a35924da6b0e5c6d53743398c0f17aa5c5ecaeafa8ffc5`. amd64/arm64 config kayıtları kaynak `960691c` ve `AGPL-3.0-only` taşıyor. İnceleme için imaj katmanı indirilmedi; ev kurulumu yapılmadı.

## Kalan kabul

Tam Client testleri ve **4 platform + 13 uygulama / 133 sıralı faz** Android E2E sonucu bekleniyor. Üç zorunlu koşu başarılı olursa imzalı APK bir kez indirilerek kaynak, sürüm, paket, sertifika, minSdk ve debug bayrağı ayrıca doğrulanır. Core'un iki mimarili yayını ve anonim source/license/manifest erişimi de ayrıca denetlenir.

Şu anda bu yeni kaynağın başarılı imzalı APK teslimi veya fiziksel tablet kabulü ileri sürülmez. Son tam doğrulanmış önceki yayın [APK104](client-delivery-104-2026-09-06.md); [CI105](client-delivery-105-2026-09-06.md) ve [CI106](client-delivery-106-2026-09-06.md) hata/ara sonuçları değiştirilmeden korunur. Yeni kanıtlar ayrı `/private/tmp/larenor-960691c-*` dosyalarında tutulur. Çalışan CI sırasında başka paket gönderilmez; bağımsız geliştirme ayrı dallarda devam eder.
