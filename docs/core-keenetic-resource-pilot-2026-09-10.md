# Core Keenetic Home Resource pilotu — 10 Eylül 2026

Bu S08.9 pilotu, kayıtlı bir Keenetic servisinden **yalnız salt okunur** durum,
arayüz, trafik ve istemci anlık görüntüsünü Home Resources yetki zinciri
üzerinden sunar. S08.9 tamamlanmış sayılmaz. Üretim ağ istemcisi bu dilimde
bilerek kapalıdır; bütün kabul testleri paket içi sentetik reader seam'iyle
çalışır. Gerçek routera, `192.168.1.150` adresine veya başka bir ev cihazına
istek gönderilmedi.

## Yetki ve bağlama sınırı

- Yönetici, exact `serviceId`, servis revizyonu, kaynak revizyonu, ACL revizyonu
  ve mevcut binding kimliğiyle önizleme ister. Önizleme yalnız servis kaydı
  `authenticated` ise ve kimlik bilgisi alanları exact `username/password` ise
  üretilir.
- Önizleme, bağlama ve tipli telemetriyi birlikte gösterir. Onay tek kullanımlık
  preview kimliğiyle yapılır; kaynak, ACL, kullanıcı, oturum, servis, endpoint,
  kimlik bilgileri veya doğrulama durumu değişmişse kayıt yapılmaz.
- Binding AES-GCM ile şifrelenir ve keyed envanter etiketiyle doğrulanır.
  Credential değerleri binding, response, receipt veya log içine yazılmaz.
- Her snapshot öncesinde ve sentetik upstream dönüşünden sonra aynı yetki
  gerçekleri yeniden okunur. İptal, 10 saniyelik deadline, geç sonuç, saat geri
  sarımı, kapatılmış adapter, geçersiz oturum ve stale revizyon fail closed olur.
- Cache anahtarı Core, home, resource, binding, service ve kullanıcı/oturum
  kimliklerinin exact bileşimidir. TTL 5 saniye, toplam 128 ve kullanıcı başına
  16 kayıtla sınırlıdır. Servis endpoint/credential/revizyon değişimi eski
  binding veya cache yetkisini devralmaz.

## Tipli readback

Snapshot yalnız şu sınırlı alanları içerir: router online/uptime/firmware;
arayüz kimliği, türü, durumu, adresi ve byte sayaçları; toplam trafik ve ölçülmüş
hız; host kimliği, adı, IP/MAC, arayüzü, online ve kayıtlı durumu. Bilinmeyen
alanlar, yinelenen kimlikler, var olmayan arayüz referansları, negatif/aşırı
sayaçlar, unsupported shape ve upstream denied/unauthorized cevapları başarı
sayılmaz.

## Direct Keenetic yolu

Android uygulamasındaki mevcut Direct Keenetic kayıt, PIN kurtarma ve yerel
telemetri yolu açıktır ve bu pilot tarafından değiştirilmez. Kullanıcı Core
bağlantısı kurmadan Direct profili kullanmaya devam edebilir. Merkezi yol için
gerçek Keenetic transport, cihaz/firmware matrisi ve fiziksel tablet-router
kabulü sonraki S08.9 dilimleridir.
