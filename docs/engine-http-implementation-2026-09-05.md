# S06.3e temeli — ortak Engine HTTP taşıması

5 Eylül 2026. Mevcut imaj taşımasının doğrulanmış Unix bağlantısı ve sınırlı
HTTP okuması `plugins/engine_http.py` içinde toplandı. Bu adım özel ağ
oluşturmaz; ağ list/inspect adaptörü sonraki ayrı dilimdir.

Her çağrı yeni bir Unix bağlantısı açar. Socket ve parent kimliği, beklenen
peer UID, aynı bağlantıda `/version` ve API 1.47/platform uygunluğu kontrol
edildikten sonra tek sabit istek gönderilir. Yanıttan sonra socket kimliği,
iptal ve süre yeniden denetlenir. Bu kanıt daemon namespace'i, mount/UID
eşlemesi veya kurulum yetkisi yerine geçmez.

Özel istek kaydı şu aşamada yalnız katalog imajlarının canonical digest ile
inspect/pull biçimlerini kabul eder. Serbest yöntem, URL, header, body, TCP,
proxy, redirect, kimlik bilgisi veya otomatik retry eklenmedi. Immutable
kayıtlar yanlışlıkla süreç içinde değiştirilmiş olsalar bile I/O öncesi
yeniden doğrulanır. Katalog/planın tekrar türetilmesi imaj adaptöründe kalır.

Tek toplam süre bağlantı, sürüm kontrolü ve iş yanıtını kapsar. Header için
32 KiB/100 alan, sürüm gövdesi için 64 KiB ve ayrı chunk sınırı korunur.
İmajın önceki toplam/idle/byte/chunk/line/event değerleri değişmez. JSON
content-type, framing, encoding, EOF ve hata kodları aynı sözleşmeyle çalışır.
Okuma sırasındaki iptal en çok 250 ms aralıklarla kontrol edilir; connect/send
aşamaları ayrıca kendi süre sınırlarına tabidir.

Yanıt tüketicisi senkron çağrı kapsamı içinde çalışır. Dışarı çıkarılmış
iterator, bağlantı kapandıktan sonra veri okuyamaz. Transport yanıtın ürün
anlamına karar vermez: 404, progress hata olayı, config/platform doğrulaması
ve çekme sonrası fresh inspect gereği imaj adaptöründe korunur.

## Test ve inceleme

`9a9e44b` RED → `f2431c7` GREEN. `0582837`, toplam süre testinin dış watchdog
payını CI zamanlamasına toleranslı hale getirdi; beklenen timeout ve toplam
sürenin iki HTTP aşamasında yenilenmemesi koşulu değişmedi.

Yeni taşıma testleri **76 geçti, bir gerçek Linux peer testi Mac'te atlandı**.
İmaj, imaj/journal köprüsü ve kaynak regresyonunda **365 geçti, iki Linux peer
testi Mac'te atlandı**. Gerçek geçici Unix listener ve özel SQLite kayıtları
kullanılır; ev Docker daemon'una veya registry'ye bağlanılmaz. Birleşik
statement/dal kapsamı yeni taşıma için **%98**, imaj adaptörü için **%99**.

İki bağımsız incelemede yeni P1/P2 bulgu kalmadı. `0582837` Server kaynaklarıyla
tam yerel regresyon **2.165 geçti, dört Linux testi Mac'te atlandı**;
202 araç testi ve commit aralığı güvenlik taraması da geçti. Uzak Linux
CI sonuçları [PROGRESS](PROGRESS.md) içinde kendi kaynak commit'leriyle
kaydedilir. Önceki `1408e80` CI'ı bu yeni modülü kapsamaz. `installAvailable=false`
korunur; ağ transportu, ağ create/journal köprüsü ve gerçek bileşen kurulumu
[kuyrukta](EXECUTION_QUEUE.md) açık kalır.
