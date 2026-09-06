# Core oda arşivi — iptal geçişinin doğrulanması

CI106'da arşiv onayı iptal edildikten sonra görülen widget yokluğu hatası, gerçek `ArchiveHarness`, şifreli arşiv, PIN, repository ve Navigator ile yeniden üretildi. Bu düzeltme testin pencerenin kaldırılmasını gözlemesini sağlar; uygulamadaki iptal ve restore davranışını değiştirmez.

Taban `e7c15ad6f62352f77379e369f3e8524028c42aab`; RED `0177e7aa7f8075478c9ce41105d954141eb6714d`; kaynak/test GREEN `36e5451c2d16a96bb990410746301d4d0a46118d`.

## Hata ve düzeltme

Paylaşılan `tapVisible` tek dokunmadan sonra 350 ms frame ilerletir. Normal ve dört kat yavaşlatılmış animasyonda iptal edilen route artık current olmadığı halde onay eylemleri hâlâ widget ağacındadır. İki gerçek runtime vakası da eski anlık yokluk kontrolünde başarısız oldu. Böylece bu kontrollü ortamda iptalin işlenmesi ile route'un tamamen kaldırılması arasındaki fark kanıtlandı. CI106 hatasının kendisi ayrı ve değişmeyen teslim kaydında korunur.

Yeni yardımcı, mevcut sınırlı `waitUntil` içinde iki onay eyleminin kaldırılmasını bekler. Tek iptal dokunması, mevcut 30 saniyelik bekleme sınırı, onay widget'ının yokluğu, preview ve değişmeyen kayıt fingerprint kontrolleri korunur. Global harness, üretim callback'leri, PIN ve sahiplik kontrolleri değişmedi. Tekrar dokunma, sabit ek uyku veya test süresi artırımı eklenmedi.

Regresyon testleri ayrıca eski iptal callback'inin etkisizliğini, sıfır dosya kaydı ve sıfır Home Assistant bağlantı okumasını doğrular. Animasyon hızı her test gövdesindeki `finally` ile eski değerine döner. İlk GREEN denemesinde ürün kontrolü geçen ikinci testin temizliği binding kontrolünden sonra çalıştığı için 1 PASS/1 FAIL oluştu; bu test temizliği hatasının günlüğü saklandı, son 2 PASS sonucuyla karıştırılmadı.

## Yerel kanıt

| Kontrol | Sonuç |
| --- | --- |
| Kontrollü RED, 1× ve 4× animasyon | 0 PASS / 2 FAIL; ikisi de beklenen route kaldırılma farkı |
| Son odaklı regresyon | 2 PASS, 6 saniye |
| İlgili 9 test dosyası | 57 PASS, 41 saniye |
| Analiz / biçim | 2 dosya, 0 sorun / 0 değişiklik |
| Bağımsız kaynak ve test incelemesi | CLEAR; mevcut davranış ve yetki kontrolleri korundu |
| Android senaryo koruması | 13 uygulama + 4 platform; 133 fazın sırası ve başlıkları aynı |

Yeni yardımcı çağrısı ve tanımı kaldırıldığında arşiv yolculuğu taban sürümüyle birebir aynıdır. Uygulama kütüphanesi, Server, contracts, Android, CI, tool, ortak harness, ana senaryo kaydı ve diğer iki yeni yolculuk değişmedi.

Yerel makbuz `/private/tmp/larenor-archive-cancel-delivery-evidence.json`, koruma kaydı `/private/tmp/larenor-archive-cancel-preservation.json`; günlükler `/private/tmp/larenor-archive-cancel-{red-verified,green-final,related,analyze,format-final}.log` konumundadır. Makbuz günlük boyutlarını ve SHA256 değerlerini içerir. Son koordinatör 84236 çıkış 0 ile toplandı.

Yeni Android emulator koşusu ve bu kaynak için imzalı APK kabulü henüz yoktur. Yerel regresyon başarısı S08.5'i kapatmaz; fiziksel tablet kabulü de ayrı kalır. Gerçek ev servislerinde işlem yapılmadı.
