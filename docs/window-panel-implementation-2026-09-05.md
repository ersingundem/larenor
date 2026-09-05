# Tablet, DeX ve duvar paneli uygulaması

2026-09-05. Bu dilim uygulama kodu ve otomatik testleri içerir. Üretim Home
Assistant'a komut gönderilmedi; fiziksel cihaz, launcher veya DPC ayarı değiştirilmedi.

## Pencere davranışı

Varsayılan **Uyarlanabilir** profil sistem kontrollerini korur. Ayarlar → Ekran
ve Parlaklık → Pencere ve panel bölümünden **Duvar paneli** seçilebilir. Tercih
yerel olarak saklanır ve şifreli yedeğe dahildir. İçe aktarılan ayar cihaz sahibi
yetkisi, yönetilen kilit veya launcher rolü kazandırmaz.

Android köprüsü `WindowInsetsControllerCompat` üzerinden yalnız durum/gezinme
çubuklarını gizlemeyi ister. İstek; ön plan, odak, IME, caption bar, çoklu pencere,
PiP, masaüstü yapılandırması ve gerçek harici ekran durumuna bağlıdır. Klavye
kapandıktan sonra bekleyen yeniden uygulama, o sıradaki profil/odakla yeniden
kontrol edilir. Kullanıcının geçici sistem çubuğunu açması anında gizleme döngüsü
başlatmaz. Flutter'ın mevcut inset aktarımı değiştirilmez.

Ekran, istenen profil ile gözlenen çubuk görünürlüğünü ayrı gösterir. Ölçüm
yoksa **Bilinmiyor** der. DPC izin listesi ve mevcut lock-task durumu salt okunur
gösterilir; uygulama bu dilimde `startLockTask`, sahiplik kurulumu veya reset
çalıştırmaz. Android hedef 36 için önceki koşulsuz Flutter `immersiveSticky`
çağrısı kaldırıldı. [Flutter sistem UI sözleşmesi](https://api.flutter.dev/flutter/services/SystemChrome/setEnabledSystemUIMode.html),
[Android immersive API](https://developer.android.com/develop/ui/views/layout/immersive),
[Android lock task](https://developer.android.com/work/dpc/dedicated-devices/lock-task-mode).

## Gezinme ve boşta kalma

- Ctrl+K ortak aramayı açıp odaklar; Ctrl+1–4 dört ana ekrana gider. Oda seçimi
  korunur. Escape aramadan geri döner; açık bir onayı kabul etmez.
- Yan sütunun tamamı kaydırılabilir; 1000×360 gibi kısa pencerelerde Arama ve
  Ayarlar erişilebilir kalır. Sabit yön zorlaması ve Samsung'a özgü reflection yok.
- Dokunma, klavye, tekerlek ve pan-zoom boşta zamanlayıcısını yeniler. İlk uyanma
  hareketi, tuş tekrarı ve Ctrl+K gibi bir uyanma kombinasyonu alttaki ekrana geçmez.
- Boştaki ekranın altında odak, pointer, semantik ve ticker erişimi kapanır.
  Ayarlar, kişisel sağlık, medya, günlük görev ve kapı onayları eski oturumla
  devam edemez. Yerel Android ses servisi kapanmaz.
- Özel onay pencereleri kendi Navigator alanında tutulur. Kilitlenme yalnız o
  alanı kaldırır; uygulamanın başka bir kök penceresini kapatmaz.

## Kanıt ve kalan cihaz kabulü

Widget testleri 320px telefon, 600px kısa pencere, 999/1000px gezinme kırılımı,
1366px tablet ve %200 metin ölçeğini kapsar. Pencere sözleşmesi testleri;
uyumsuz/eksik platform cevabı, seri ayar yazma, hata, geç yanıt, IME ve yaşam
döngüsünü sınar. Native testler Android CI'da `:app:testDebugUnitTest` ile çalışır.
İlgili testler `test/core/window`, `test/features/navigation/desktop_navigation_test.dart`,
`test/features/settings/window_*` ve `test/features/settings/idle_gate_test.dart` içindedir.

| Hedef | Otomatik kapsam | Fiziksel kabul |
| --- | --- | --- |
| Huawei MatePad 11.5 S 2026 | Uyarlanabilir düzen, küçük/büyük metin, GMS'siz pencere API'si | APK çalışma ortamı, WebView, ekran/uyku/pil, klavye ve launcher bekliyor |
| Samsung DeX | Kısa/geniş pencere, klavye odağı, sistem caption ve çoklu pencere politikası | Dock tak/çıkar, dokunmatik monitör, fare ve gerçek sistem insets bekliyor |
| Android duvar paneli | Açık profil, ölçülen durum, IME/odak yaşam döngüsü | Gerçek çubuk görünürlüğü, gece davranışı ve uzun süreli pil testi bekliyor |
| Yönetilen kiosk | İzin/durum okuma | Ayrılmış cihazda DPC kurulumu ve kurtarma provası uygulanmadı |

Huawei Türkiye teknik sayfası HarmonyOS 4.3, 2800×1840 panel ve USB 3.0/OTG
belirtir; bunlar Android API seviyesi veya DisplayPort video çıkışı kanıtı
değildir. [Huawei teknik özellikler](https://consumer.huawei.com/tr/tablets/matepad-11-5-s-2026/specs/).
Samsung, DeX ile lock-task/kiosk kısıtını ayrıca belgeler; iki modu aynı anda
garanti etmiyoruz. [Samsung DeX ve Knox](https://docs.samsungknox.com/dev/knox-sdk/features/mdm-providers/device-management/samsung-dex-and-knox/).
