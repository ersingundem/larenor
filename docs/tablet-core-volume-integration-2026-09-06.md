# Tablet arayüzü, geçişler ve Core volume birleşimi

Test edilen sabit kaynak `643cbddf6c89085b3a10de7933a59dbe0b394739`. Eklenti kataloğu/iş geçmişi, yedekleme/kasa/arşiv diyalogları, iki Android yolculuğunun geçiş beklemesi ve özel kalıcı volume create protokolü non-squash birleşimlerle aynı pakete alındı.

## Kullanıcıya yansıyan değişiklikler

- Core bileşen kataloğu ve iş geçmişinde başlıklar ile eylem adları ekran okuyucuda ayrılır. Klavye odağı görünür kalır; dokunma alanları en az48px'tir.
- Yedekleme, kasa ve oda arşivi onaylarında normal boyuttaki yazı küçülmez; iki kat metin boyutu ve klavye kullanımı korunur. Gerçek onay/iptal yetkileri, PIN ve güncel oturum kontrolleri değişmedi.
- Android arşiv iptali ve kişi ekranından geri dönüş senaryoları, tek dokunmadan sonra ilgili pencerenin gerçekten kaldırılmasını bekler. Üretim davranışı ve ortak tap yardımcısı değişmedi.
- Core'daki özel volume protokolü kalıcı niyet, tek gated POST, ayrı taze GET ve belirsiz işlem sonrası tekrar yaratmama davranışını sağlar. Bu protokol henüz kurulum düğmesine bağlanmadı; `installAvailable=false` korunur.

## Birleşik yerel doğrulama

| Kapı | Sonuç |
| --- | --- |
| Tam Android Client unit/widget/regresyon paketi | **5150 PASS / 0 hata**, coverage açık, test başına90s sınırı;458s test günlüğü,464,69s süreç |
| Tam Flutter analiz | **0 sorun**,8,4s analiz |
| Tüm Dart biçim kontrolü | **971 dosya / 0 değişiklik** |
| Tam Core | **3435 PASS / 12 Linux-only skip / 0 hata**; toplam3447 JUnit vakası,431,65s |
| Güvenlik/CI politikaları | **207 PASS**,59,707s; ek güvenlik ve kuyruk doğrulaması geçti |
| Yeni commitlerin gizli bilgi taraması | **0 bulgu**,51 commit tarandı |
| Android senaryo koruması | **13 uygulama +4 platform**,133 fazın bütün başlıkları ve sırası aynı |

CI106'nın5056 Client testine bu pakette94 test eklendi: katalog32, Jobs34, üç diyalog24 ve iki geçiş için4. Parça koşumlarının sayıları yeni toplamın üzerine eklenmez. Önceki katalog birleşimindeki5088 sonucu da bu yeni kaynağın kanıtı olarak kullanılmadı; yeni5150 koşumu baştan tek kez çalıştırıldı.

Client testi izole `codex/package107-client-integration` dalında çalıştı. Kaynak temiz kaldı; pub kilidi, codegen, tam test, analiz ve format süreçleri başarıyla toplandı. Ana dalın `lib`, `test`, `integration_test`, `server`, `contracts`, `android`, `.github`, `tool`, `pubspec.yaml` ve `pubspec.lock` Git nesneleri test edilen kaynakla aynıydı. Bu doğrulamadan sonraki ilerleme/kanıt belgeleri çalışma kodunu değiştirmez.

Core'un tek tam koşumu `72af399` üzerinde yapıldı; Server, contracts, Android ve Java verifier ağaçları birleşimde aynı olduğundan ikinci bir tam Core testi tekrarlanmadı. [Core JUnit, kaynak eşitliği ve Linux sınırları](managed-volume-full-core-verification-2026-09-06.md) ayrı kayıttadır. Java17/pinli apksig ile dört gerçek verifier vakası da geçti.

## İnceleme ve kanıtlar

[Katalog](core-plugins-tablet-accessibility-2026-09-06.md), [Jobs](core-plugin-jobs-tablet-accessibility-2026-09-06.md), [üç onay diyalogu](restore-dialog-targets-2026-09-06.md), [arşiv geçişi](core-archive-cancel-transition-2026-09-06.md), [People geçişi](core-people-back-transition-2026-09-06.md) ve [volume protokolü](managed-volume-create-implementation-2026-09-06.md) kendi RED/GREEN, kaynak incelemesi ve sınırlarını içerir. Root birleşen farkları ve gerçek fontla üretilen tablet görsellerini ayrıca inceledi. İlk ölçüm/fixture/cleanup hataları ürün kusuru veya başarılı test diye sunulmadı.

Yerel birleşim makbuzu `/private/tmp/larenor-package107-integration-evidence.json`; beş Client aşamasının tam komutları, süreleri ve hash'leri `/private/tmp/larenor-package107-client-execution.json` içindedir. Günlükler `/private/tmp/larenor-package107-client-{pub,codegen,full-client,analyze,format}.log`; coverage çıktısı izole worktree'nin `coverage/lcov.info` dosyasıdır. Ayrı politika makbuzu `/private/tmp/larenor-package107-policy-evidence.json`, senaryo koruma kaydı `/private/tmp/larenor-package107-preservation.json`. Koordinatörler18861/1276/41588 toplandı.

Bu belge yerel birleşim kontrolüdür. Yeni GitHub Linux/Android/güvenlik CI,17 gerçek emulator senaryosu ve imzalı APK'nın kaynak/sürüm/sertifika doğrulaması kendi yayın kaydında izlenir. S08.5/S08.6 bu kanıtla tek başına kapanmaz; fiziksel tablet/DeX ve gerçek ev kurulumu ayrıdır. Sonraki Services tablet dalı bu pakete dahil değildir. Gerçek ev servislerinde işlem yapılmadı.
