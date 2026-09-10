# S08.9 Proxmox güç komutu otoritesi — yazılım pilotu

Bu dilim, QEMU ve LXC güç komutları için Larenor Core üzerinde paketlenmiş ve
kapalı bir komut otoritesi kurar. `start`, `shutdown`, `stop`, `reboot`,
`suspend` ve `resume` eylemleri sunucu allowlist'i dışına çıkamaz. Preview,
kullanıcı/kaynak/ACL/binding/servis/konuk durum sürümlerinin tamamına bağlanır;
confirm sırasında aynı bilgiler yeniden okunur. `stop` ve `reboot` yüksek risk
olarak ikinci açık onay ister. Preview tek kullanımlıdır ve iptal edilen ya da
başarısız onaylanan bir preview yeniden yürütülemez.

Kalıcı request ID kaydı tekrar yürütmeyi kapatır. Receipt gövdesi AES-GCM ile
şifrelenir ve yalnız sınırlı, typed durum içerir: `accepted`, `executing`,
`succeeded`, `failed`, `cancelled` veya `unknown`. Süre aşımı, geç sonuç,
revision değişimi, bağlantı kopması, süreç yeniden açılışı ve doğrulanamayan
sonuç `unknown` olur; Client bunu başarı
gibi göstermez ve otomatik retry/replay yapmaz. Typed receipt özeti S08.10 olay
envelope'una bağlanabilecek küçük bir adaptör sınırı sağlar.

Android Client temeli, tek açık kullanıcı eylemiyle preview, confirm ve cancel
çağrısı yapar. Hesap, yaşam döngüsü veya ekran otoritesi değişince geç cevapları
atar. Üye hesabında panel görünmez; admin hesabının kaynak write yetkisi yoksa
48 dp denetimler pasif kalır. İngilizce ve Türkçe etiketler, 2x metin,
klavye uyumlu Cupertino düğmeleri ve canlı durum semantiği tablet/DeX yüzeyi
için kapsanır.

## Bilerek açık kalan kabul

- Varsayılan Core provider ve effect uygulaması kapalıdır. DNS, socket, LAN veya
  Proxmox isteği yapmaz; yalnız testte sentetik packaged seam enjekte edilir.
- Gerçek Proxmox API token/realm/guest keşfi, node/task UPID nedensellik
  doğrulaması ve paketlenmiş effect worker henüz bağlanmadı.
- Mevcut doğrudan Proxmox Client ekranları bu pilotla merkezi yola taşınmış
  sayılmaz. Güvenli resource/binding/status revision eşlemesi gelmeden yeni
  panel canlı guest satırına bağlanmaz.
- Fiziksel Huawei tablet, Samsung DeX, gerçek Core oturumu ve gerçek QEMU/LXC
  kabulü ile genel CI çalışması yapılmadı. S08.9 bu pilotla tamamlanmış sayılmaz.
- `installAvailable` ve medya kurulum akışları değiştirilmedi.

## Yerel kanıt

- Server: `server/tests/test_proxmox_power_commands.py` — 24 sentetik test.
- Client: `proxmox_power_authority_test.dart` ve
  `proxmox_power_authority_ui_test.dart` — 7 test.
- Odaklı Flutter analyze ve Python compile temizdir.
