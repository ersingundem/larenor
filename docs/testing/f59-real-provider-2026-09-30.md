# F59 OctoPrint ve Moonraker gerçek HTTP sağlayıcısı

Normal Core bileşimi `WorkshopHttpProvider` kullanır. Credential-bound
`ServiceTransport` yalnızca sabit API yollarına, sınırlı süre ve cevap boyutuyla
gider; redirect, proxy, cookie, retry ve genel G-code yüzeyi yoktur. Bu kanıt
çalışmasında gerçek ev yazıcısına istek ya da mutation yapılmadı.

Yeni kurulum yolu admin'in güncel, doğrulanmış OctoPrint/Moonraker hizmet
kataloğundan seçim yapmasını ister. Client yalnız `registrationId`, yazıcı adı,
`serviceId` ve beklenen service revision gönderir. Job, material, sıcaklık ve
stop yetkisi taze sağlayıcı GET'lerinden türetilir; base URL ve API anahtarı
Client'a dönmez. OctoPrint/Moonraker'ın genel API'leri kalan filament miktarı
sunmadığı için ilk kayıt `material.kind=unknown` ve `remainingGrams=null`
olarak saklanır; sahte sıfır gram üretilmez.

Normal Client bir service'in tek yazıcısını aynı doğrulanmış service kimliğiyle
kaydeder. Böylece HTTP acknowledgement kaybolsa veya Client yeniden başlasa da
aynı ad/service birleşimi aynı registration kimliğiyle replay edilir; rastgele
yeni kayıt ve çift yazıcı üretilmez.

Aynı registration kimliğiyle kayıp ACK tekrarı, ad ve service authority aynıysa
saklanmış kaydı döndürür. Bu replay upstream iş ilerlemesine bağlı değildir ve
yeniden GET/POST üretmez. Yeni kimlik ise I/O öncesi ve sonrası aynı admin,
home ve service revision'ını tekrar doğrular; SQLite transaction ağ I/O'su
boyunca açık tutulmaz.

## Gözlem sözleşmesi

OctoPrint gözlemi hem `GET /api/job` hem `GET /api/printer?exclude=sd`
kullanır. Printer cevabındaki durum bayrakları ve her aracın sınırlı
`actual`/`target` değerleri ayrı ayrı doğrulanır; resmî sözleşmedeki `null`
hedef kabul edilir. [OctoPrint Printer operations](https://docs.octoprint.org/en/main/api/printer.html)
bu alanları ve GET için `STATUS` iznini tanımlar. Job durumu, ilerleme ve
kalan süre [OctoPrint Job operations](https://docs.octoprint.org/en/main/api/job.html)
sözleşmesinden gelir.

Moonraker önce `GET /printer/objects/query` ile `heaters.available_heaters`
ve iş durumunu okur. Ardından yalnızca taşıyıcının güvenli sorgu anahtarı
sınırına uyan standart `extruder[0-9]*` ve `heater_bed` nesnelerinin
`temperature,target` alanlarını okur. Moonraker'ın
[printer object endpoints](https://moonraker.readthedocs.io/en/latest/external_api/printer/)
nesne listesi/sorgusunu ve bulunmayan alanların hata vermeden atlanabildiğini;
Klipper'ın [status reference](https://www.klipper3d.org/Status_Reference.html)
ise heater `temperature`, `target` ve `available_heaters` alanlarını tanımlar.
Özel adlı heater nesneleri keşfedilir ancak dinamik, sınırsız sorgu yoluna
çevrilmez.

Moonraker aktif iş kimliği `filename`, nullable history `job_id` ve
`print_start_time` alanlarının gerçek upstream birleşimidir; bu alanlar
[GCode metadata](https://moonraker.readthedocs.io/en/latest/external_api/file_manager/)
sözleşmesinde tanımlıdır. Bunlardan biri yoksa mutation yetkisi üretilmez.
OctoPrint benzersiz run ID yayımlamadığı için kimlik yalnızca gerçek
`origin/path/size/date` dosya birleşimidir. Aynı dosyanın iki ayrı koşusunu
ayırt etme garantisi yoktur; bu API sınırı fiziksel kabulde açıkça sınanmalıdır.

Sıcaklık telemetrisi API erişiminin ve cevap şeklinin kanıtıdır; fiziksel
termal güvenliği kanıtlamaz. Bu nedenle `thermal`, `filament`, `door` ve
fiziksel `emergency` genel sağlayıcıda `unknown` kalır ve istemci bu
bilinmezleri açık uyarı olarak gösterir. Generic API'den sağlıklı sensör,
fiziksel E-stop veya başlatma yeteneği uydurulmaz.

Doğrulanan heater adı, gerçek sıcaklık ve nullable hedef sıcaklık ayrıca
bounded `temperature.heaters` DTO'suna yazılır, HMAC-sealed printer kaydında
kalıcı tutulur ve kartta °C olarak gösterilir. Sıcaklık için ayrı revision
ilerler; yalnız heater ölçümü değiştiğinde job revision ilerlemez. Böylece
ölçüm izlenebilir, ancak `thermal: unknown` değeri yanlış bir güvenlik
çıkarımına çevrilmez.

## Durdurma yetkisi ve readback

Pause/cancel mevcut işi durduran eylemlerdir. Sunucu bunları yalnızca güncel,
online, tam iş kimliği bulunan bir gözlemde ve sağlayıcının o durumda açıkça
bildirdiği alt küme için sunar. Bilinmeyen kapı/filament/termal sensör stop
butonunu saklamaz; bilinen tehlike de uyarı olarak kalır. Offline, stale,
kimliksiz veya sağlayıcının desteklemediği eylem için buton üretilmez.

Komut öncesi upstream iş kimliği, durum, provider snapshot, service revision,
sunucu satır revizyonu ve admin actor yeniden kontrol edilir. Progress/ETA
hareketi iş kimliği değildir. Efekt dispatch öncesi kalıcı olarak ayrılır;
kayıp ACK `unknown` sonucuna gider ve aynı confirmation yeniden gönderilmez.
POST cevabı applied kanıtı sayılmaz: sonraki gerçek GET yeni durumu göstermeli
ve kalıcı server job revision'a bağlanmalıdır. OctoPrint pause açık
`action: pause` kullanır; toggle, start/resume, keyfî G-code ve fiziksel E-stop
komutu yoktur.

## Kanıt

- Python provider/Core fixture paketi: **21 passed**. Buna gerçek loopback HTTP,
  ilerleyen progress/azalan ETA, tek dispatch, kayıp ACK sonrası yeniden
  göndermeme, gerçek GET readback, sıcaklık persistence/ayrı revision,
  exact-job drift, katalogdan provider-derived kayıt, I/O sırasında admin
  iptali, restart replay ve v2->v4 veri/FK/seal koruyan şema geçişi dahildir.
- Flutter workshop paketi: **21 passed**, normal-runner gerektiren test tek
  başına **1 skipped**. Strict katalog/kayıt body, inline EN/TR kayıt ekranı,
  sayısal sıcaklık, bilinmeyen material/sensör uyarıları ve session/route
  kapıları kapsanır.
- `server/tests/support/f59_flutter_acceptance.py`: prepare ve restart
  aşamalarının ikisi de **1 passed**. Gerçek Flutter production API'si iki ayrı
  normal Core ömründe authenticated katalog→kayıt→preview→confirm→receipt
  readback çalıştırdı; owned loopback OctoPrint TCP'de pause POST sayısı tam
  **1** kaldı ve restart sonrası paused durum okundu.
- Workshop domain/data/screen ve üç odaklı test dosyasında dar
  `flutter analyze`: **No issues found**.
- `git diff --check` (F59 allowlist): temiz.

Fiziksel cihaz ve özel sensör kabulü ayrı saha kapısı olarak açık kalır.
