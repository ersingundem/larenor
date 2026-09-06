# Tablet penceresinde işlem ömrü

6 Eylül 2026. B5.1 ve S08.4 için dar bir ortak pencere düzeltmesi.

DeX penceresi odağı kaybettiğinde Android uygulaması `resumed` kalabilir.
IdleGate yalnız uygulama yaşam döngüsünü izlediği için açık Home Assistant
onayı geçerli kalıyordu. Gerçek `ViewFocusEvent` gönderen widget testleri
bu açığı üretir; uygulama yaşam döngüsü olayıyla taklit etmez.

IdleGate artık kendi view kimliğinin odak durumunu yaşam döngüsüyle birlikte
izler. Odak kaybı mevcut işlem epoch'unu aynı anda geçersizleştirir; onaylar,
pointer, klavye, ticker ve ambient zamanlayıcısı buna uyar. Başka bir view'in
olayları bu pencereyi etkilemez. Geri dönmek eski callback'i yeniden yetkili
yapmaz. Widget ağacı ve native ses servisi yaşamaya devam eder.

## Kanıt

- RED `904142f`: aynı idle test hedefinde **24 PASS / 2 FAIL**. Odak kaybında
  interaction hâlâ aktifti ve HA root onayı görünüyordu.
- GREEN `729d96d`: aynı hedef **26 PASS**. Eski onay callback'i odak dönüşünde
  **sıfır HTTP isteği** üretir. Gerçek ev bağlantısı kullanılmaz.
- `b86d605`: native yerel sesin idle, odak ve arka plan geçişlerinde oynadığı,
  stop/play komutu gönderilmediği ek olarak doğrulandı.
- İlgili geniş koşu **252 PASS / 16 saniye**; iki dosya analizi temiz.
- IdleGate satır kapsamı **102/106 (%96,23)**; tüm uygulamanın kapsamı değildir.

Çalıştırılan hedefler:

```text
flutter test test/features/settings test/features/media/hub/media_session_state_test.dart test/features/media/jellyfin/jellyfin_player_interaction_test.dart test/features/home_scope test/core/direct_home_routines_test.dart test/features/navigation/routines_screen_test.dart --coverage --reporter expanded
flutter analyze lib/features/settings/presentation/idle_gate.dart test/features/settings/idle_gate_test.dart
```

Flutter/Dart komutları ortak SDK kilidi üzerinden seri çalıştırıldı.
Bağımsız inceleme, birleşik tam Client koşusu ve bu değişikliği içeren Android
CI henüz ayrı kabul kapılarıdır. Huawei/DeX fiziksel testinin yerine geçmez.
