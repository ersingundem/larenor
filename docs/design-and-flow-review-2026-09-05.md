# Tasarım ve özellikler arası akış kontrolü

2026-09-05. Mevcut Cupertino/Inter tasarım sistemi korundu. GitHub'daki
[apple-design](https://github.com/dickwu/apple-design-skill),
[Anthropic frontend-design](https://github.com/anthropics/skills/tree/main/skills/frontend-design)
ve [Impeccable](https://github.com/pbakaus/impeccable) yaklaşımı incelendi;
Apple HIG uyarlanabilirlik, okunabilirlik, semantik renk ve erişilebilirlik
ilkeleri native Flutter arayüze uygulandı. Web sitesi için önerilen yeni bir
tipografi veya marka, mevcut uygulama kimliğinin yerine geçirilmedi.

## Tasarım kararları ve kanıt

| Alan | Uygulanan davranış | Kontrol |
| --- | --- | --- |
| Kimlik | Tek Latin motto; uygulama ve launcher aynı ev/koruyucu amblemi, adaptive/monochrome vektörler | Kaynak ve mevcut ikon görseli incelendi; yeni slogan yok |
| Gezinme | Telefon sekmeleri ve geniş ekran yan sütunu aynı dört hedef; kısa yan sütunun tümü kaydırılır | 320–1366px, 360px kısa yükseklik, %200 yazı, Ctrl+K/Ctrl+1–4 |
| Kaynak ile sonuç | Kayıtlı bağlantı, erişim, istek kabulü ve gözlenen veri ayrı | HA, medya, özel sağlık ve pencere snapshot testleri |
| Özel sağlık | Günlük Ölçümler ve Kaynaklar sekmeleri; aynı grouped kartlar ve sayfa yüzeyi | Her iki sekme telefon/tablet ve %200 yazı; kaynak/okuma zamanı ayrı |
| Pencere ve güç | Açık profil seçimi; sistemin gözlenen sonucu ayrıca gösterilir | Desteksiz, bilinmeyen, çoklu pencere ve başarısız kayıt testleri |
| Web paneli | Aynı yükleme/hata/yeniden deneme görünümü, ayrı web oturumu açıklaması | Dar/geniş pencere, ham hata gizleme, origin ve yaşam döngüsü testleri |

Yeni README görselleri gerçek Flutter widgetlarından sentetik verilerle
üretildi ve görsel olarak incelendi. Fiziksel tablet, canlı sağlık verisi veya
Home Assistant ekran görüntüsü değildir. Araç `test/shared/window_wellbeing_design_preview_test.dart`;
çıktı klasörü `docs/previews/`. Kullanıcının cihazında font, ekran ölçeği,
TalkBack ve dokunmatik/klavye kabulü ayrıca yapılmalıdır.

## Akış incelemesinde kapatılan boşluklar

1. Eski Arr sonuçları veya onayı yeni hesaba ekleme gönderemiyor. Aynı istemci
   ve kaynak oturumu taşınıyor; yinelenen gönderim tek işlem, belirsiz sonuç ayrı.
2. Jellyseerr eski sorgusu yeni sorguyu ezemiyor; eski hesap satırı, idle veya
   belirsiz istek aynı ekrandan yeni talep başlatamıyor.
3. Pano oda onayları ve kart sürükleme callback'leri idle sırasında geçersiz.
   Normal kart seçiciden dönüş, rota animasyonu tamamlandıktan sonra kaydedilir.
4. Jellyfin ses/altyazı/kalite seçimleri tek etkileşim oturumuna bağlı. Eski
   kalite yanıtı yeni kaynak açamıyor; bu UI iptali ses servisini durdurmuyor.
5. Yedekte kişisel ölçüm/kişi profili olmadan gizleme politikası taşınıyor.
   Restore mevcut kısıtlamayı zayıflatmıyor; v1 HA/pano yedeği gizlilik kontrolü istiyor.
6. Özel sağlık Navigator'ı sistem geri düğmesinde önce kendi dialogunu kapatıyor.
   Dış dialog, arka plan ve idle eski PIN yetkisini yeniden canlandıramıyor.

İnceleme model/servis sürümlerinin evrensel doğrulaması değildir. Gerçek Algan 7
elektronik köprüsü, OEM ekran/izin davranışı, sağlayıcı yetkilendirmeleri ve ileri
Fully Kiosk işlerindeki durum [uygulama kuyruğunda](product-implementation-plan-2026-09-05.md)
ayrı izlenir. Üretim HA üzerinde bu kontroller için komut çalıştırılmadı.
