# S08.9 Proxmox salt okunur Core adaptörü pilotu

Bu paket S08.9'un yalnız Proxmox başlangıç dilimidir. Proxmox node, QEMU/LXC
guest ve storage özetlerini bir Home Resources kaydına bağlar. S08.9'u veya
seçilen özelliklerden birini tamamlanmış saymaz; Keenetic, diğer altyapı
adaptörleri, uzak CI ve fiziksel ev kabulü açık kalır.

## Yetki ve bağlama

Yönetici önce
`POST /api/v1/admin/proxmox/{coreId}/{homeId}/resources/{resourceId}/binding-preview`
ile exact servis ID/revizyonunu, kaynak revizyonunu, ACL revizyonunu ve mevcut
binding ID'sini sunar. Core güncel yönetici oturumunu ve kaynağı aynı SQLite
okumasında doğrular, sentetik veya paketli transport üzerinden salt okunur
özeti alır ve yetkiyi tekrar kontrol eder. Önizleme 60 saniye yaşar, kullanıcı
başına 4 ve süreçte 32 kayıtla sınırlıdır. `binding-confirm` tek kullanımlı
önizlemeyi şifreli ve HMAC ile doğrulanan binding envanterine yazar;
`DELETE .../binding-preview/{previewId}` önizlemeyi iptal eder.

Üye yalnız Home Resources ACL'sinde `read` izni bulunan kaynağın
`GET /api/v1/proxmox/{coreId}/{homeId}/resources/{resourceId}/snapshot`
ucunu kullanabilir. Yanıt yalnız kapalı tipli node, guest ve storage alanlarını
içerir. Sağlayıcı gövdeleri, URL, kimlik bilgileri, header veya ham hata
yayınlanmaz. Bu pilotta güç, guest yapılandırması, snapshot, backup, migration,
terminal ve console komutu yoktur.

## Cache ve geç yanıt sınırı

Cache anahtarı Core, ev, kaynak, binding ID/revizyonu, servis ID/revizyonu,
kullanıcı, access-token ve session-family tuple'ıdır. Fingerprint ayrıca güncel
kaynak/ACL/kullanıcı facts ile şifreli endpoint ve credential kaydını kapsar.
TTL en çok 5 saniye, kullanıcı kotası 32, süreç kotası 256 ve tek kayıt boyutu
64 KiB'dir. Endpoint, credential, servis revizyonu, binding, kaynak, ACL,
kullanıcı rolü veya oturum değiştiğinde önceki sonuç yayınlanamaz. Ağ dönüşünde
aynı facts ikinci kez doğrulanır. İstek iptali, auth kaybı, adapter kapanışı,
Core yeniden açılışı, monotonic saat geri kayması, bilinmeyen durum ve bozuk
provider verisi kapalı hata üretir; eski değer yeni başarı olarak gösterilmez.

Paketli transport yalnız sabit `GET /api2/json/cluster/resources` çağrısını
kullanır. API tokenı doğrudan header'a eklenir. Kullanıcı/parola kaydı için
yalnız ticket alma çağrısı yapılabilir; ikinci faktör isteyen veya beklenmeyen
ticket reddedilir. Redirect, proxy, retry, ortam cookie'si ve genel Proxmox
route'u yoktur. Testler yalnız owned loopback HTTP fixture kullanır; gerçek bir
Proxmox sunucusuna bağlanılmadı.

## Geçici Direct yolu

Android uygulamasındaki mevcut Direct Proxmox bağlantısı bu pilot boyunca açık
kalır. Core ekranı ve dashboard widget'ı Direct sağlayıcıya geri dönmez, Direct
credential'ı devralmaz ve Direct oturumu Core yetkisi sayılmaz. Direct yol ancak
geri dönüş ve fiziksel tablet kabulü tamamlandığında kaldırılabilir.

## Android tablet ve DeX istemcisi

Home Resources ekranı üyeye salt okunur Proxmox özetini, PIN korumalı yönetici
ekranı ise Proxmox servis seçimi ile açık önizleme/onay/iptal akışını sunar.
Dashboard düzenleyicisi önce Core kaynağını seçtirir ve widget yalnız bu kaynak
kimliğini çözdükten sonra anlık görüntüyü okur. Node, QEMU VM, LXC konteyner ve
storage kartlarında durum metinle birlikte CPU, RAM, disk ve çalışma süresi
gösterilir. Bilinmeyen, yetkisiz, çevrimdışı ve eski sonuçlar ayrı görünür;
TTL dolunca eski metrik kaldırılır.

Ekran 880 dp içerik sınırı ve geniş görünümde iki sütun kullanır. Metin 2 kat
büyüdüğünde tek sütuna döner. Tüm seçimler en az 48 dp Cupertino düğmeleri,
klavye focus halkası ve TalkBack için durum ile metrikleri birleştiren Semantics
etiketleri kullanır. App lifecycle, pencere odağı, hesap nesli, ev kimliği,
kaynak/ACL revizyonu veya oturum değişirse owner kalıcı kapanır; geç yanıt ve
önceki anlık görüntü yayımlanmaz.

## Yerel kanıt

Odaklı testler `test_proxmox_resource_adapter.py` ve
`test_proxmox_resource_transport.py` dosyalarındadır. İlişkili Server kapısı
Home Resources, Home Assistant, servis kayıtları ve ağ probe regresyonlarını
birlikte çalıştırır. Server RED `e2e3baa`, GREEN `67bee0c`; **15 odaklı** ve
odaklıları da içeren **335 ilişkili Server testi** geçti. Client sözleşme,
lifecycle/controller ve tablet/dashboard diliminde **12 odaklı Flutter testi**
ile seçili dosyaların analizi geçti. Gerçek Proxmox ACL davranışı, self-signed
TLS tercihi, fiziksel tablet/DeX ve GitHub CI bu yerel pilotun kanıtı değildir.
