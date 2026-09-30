# F59 OctoPrint ve Moonraker gerçek HTTP sağlayıcısı

Normal Core bileşimi artık `WorkshopHttpProvider` kurar. Credential-bound
`ServiceTransport`, sabit API yolları, sınırlı cevap/süre ve gerçek upstream
job kimliği kullanır. Redirect, proxy, cookie, retry veya genel G-code yüzeyi
yoktur. Komut öncesi upstream job/provider snapshot tekrar okunur; POST
makbuzu tek başına applied sayılmaz. Sonraki GET, kalıcı server job revision'ına
bağlanır. Progress/ETA hareketi job kimliği veya komut yetkisi değildir.

- OctoPrint: [Job API](https://docs.octoprint.org/en/main/api/job.html),
  [data model](https://docs.octoprint.org/en/main/api/datamodel.html).
  Pause açıkça `action: pause` kullanır; toggle kullanmaz.
- Moonraker: [printer API](https://moonraker.readthedocs.io/en/latest/external_api/printer/),
  [status/polling](https://moonraker.readthedocs.io/en/latest/external_api/introduction/),
  [job metadata](https://moonraker.readthedocs.io/en/latest/external_api/file_manager/),
  [authorization](https://moonraker.readthedocs.io/en/latest/external_api/authorization/).

Genel resmî API kapı/filament güvenliğini kanıtlamadığında bu alanlar `unknown`
kalır. Böyle bir bağlantı otomatik write capability ilan etmez. OctoPrint REST
unique run ID yayımlamadığından dosyanın origin/path/size/date kimliği ile
current state CAS kullanılır; aynı dosyanın farklı koşuları tam run-ID kabulü
olarak gösterilmez. Fiziksel cihaz ve özel güvenlik sensörü kabulü açık kalır.

## Kanıt

- HTTP provider + Core odaklı fixture paketi: **13 passed**.
- Ajanın ilgili adapter/Core/probe paketi: **234 passed**.
- Fixture'lar gerçek HTTP sözleşmesini ve CAS/readback reddini kapsar; gerçek
  ev yazıcısına istek veya mutation yapılmadı.
- F59'un tüm kabul kriterleri ve fiziksel güvenlik doğrulaması tamamlanmadığı
  için bu commit F59'u done yapmaz.
