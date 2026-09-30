# F30 dayanıklı arşiv işlem motoru

Tarih: 2026-09-30. F30 aktif geliştirme durumundadır.

İşlem motoru beş saniyelik IPC cevabından bağımsız çalışır. Confirm sonrasında
tam kaynak hashini hesaplar, ayrı orijinal/çalışma kopyalarını kota içinde
korur, durable journal intentini yazar ve Unmanic'e yalnız bir görev gönderir.
Core on beş saniyelik canlı yetkiyi yenilemediğinde yeni yerleştirme yapılmaz.
İptal sinyali IPC v4 üzerinden worker'a ulaşır.

Terminal sonucu yalnız imzalı exact task/work-path callback'i verir. FFprobe
ve FFmpeg gerçek dosyaları decode eder; küçülen çıktı, kopyalanan ses/altyazı,
video profili ve tam dosya hashleri doğrulanır. Atomik replacement öncesinde
install intent kalıcıdır. Kaybolan install makbuzu, korunan orijinal ve gerçek
yerleştirilmiş çıktı hashleri yeniden okunarak kurtarılır. Eski kaynak codec
profilini yeniden istemek yerine mevcut yetki ve yerleştirme kanıtı aranır.

Kaybolan provider acknowledgement yeniden submission üretmez. Belirsiz sonuç
polling sırasında görünür kalır. Cancellation submission sırasında geldiyse,
provider görevinin bulunmadığı kesin olarak bilinmediği için iptal tamamlandı
denmez. Bilinen terminal veya install kanıtı dışında işlem otomatik sürmez.

Engine, action contract ve journal birlikte 33 odaklı testi geçti. Engine
örnekleri gerçek geçici H264/AAC/SRT ve HEVC dosyalarını kullanıyor; Unmanic
HTTP/callback kısmı sabitlenmiş protokol fixture'ıdır. Bunlar gerçek Unmanic
kurulumu veya bütün istemcilerde algısal kalite kabulü yerine geçmez.

Açık teslim işleri: mühürlü kaynak/mount resolver'ı, normal worker CLI/deploy,
gerçek Unmanic transportu, paketli durable callback outbox, duplicate/retention
ve orijinal cleanup işlemleri, gerçek sağlayıcı kabulü.
