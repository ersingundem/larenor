# Core web arayüzü teslim sırası — 30 Eylül 2026

Kullanıcının güncel kapsamı, eski yalnız Client sunumu kararını genişletir:
`FINAL.FUNCTION → FINAL.UI → FINAL.AUDIT → FINAL.CI → FINAL.GALLERY →
FINAL.README → CORE.WEB`. Aynı anda iki FINAL maddesi alınmaz. Mevcut
`codex/project-completion-100` dalında her tutarlı iş commit ve push edilir;
ara PR açılmaz. Son teslimde zorunlu CI yeşil olmadan merge yapılmaz.

Core web UI gerçek Core kimlik doğrulaması ve desteklenen API/sağlayıcılarla
çalışacaktır. Apple tasarım ilkeleri, EN/TR, responsive düzen, klavye ve ekran
okuyucu, açık rol/yetki ayrımı, hata ve geri kazanma davranışları kabul
kapsamındadır. Mock/demo veriler üretim yolu sayılmaz. Bütün işlevler normal
Core karşısında tarayıcıdan sınanır; gerçek ev cihazlarında yazma yapılmaz.

Bu ek teslim işi kuyruk paydasına dahildir: 37/127 (%29,1) kabul edilmiş iş;
3/63 (%4,8) seçili özellik. Uygulanmış veya test bekleyen işler `done` değildir.
