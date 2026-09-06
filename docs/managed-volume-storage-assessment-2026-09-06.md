# S06.3d — Docker tarafından yönetilen kalıcı depolama değerlendirmesi

6 Eylül 2026. Durum: salt okunur mimari inceleme. Bu belge kurulum desteği,
çalışan volume uygulaması veya S06.3d kabulü değildir. `installAvailable=false`
korunur. Ev Docker/CasaOS/Proxmox hizmetine erişilmedi.

## Amaç ve mevcut engel

Kullanıcı Larenor Core'un medya bileşenlerini kurmasını ve birbirine otomatik
bağlamasını istiyor. Appdata için Docker'ın yönettiği named volume seçeneği,
Core'un host üzerinde dizin oluşturup sahipliğini değiştirmesi gereğini
azaltabilir. Mevcut host bind-mount yolu ise doğrulanmış daemon başlangıcı,
UID/GID eşlemesi ve güvenilir host kökü gözlemini gerektiriyor. Bunlar farklı
depolama yollarıdır; birinin kanıtı diğerini tamamlanmış yapmaz.

Bugünkü `plugins/models.py:StorageMount`, `resource_plan.py` ve
`resource_journal.py:AppdataIdentity` host dizini kimliğine dayanır. Volume
adını inode/UID/GID kaydının yerine koymak, eski planı veya journal'ı yeni
anlamda okumak uygun değildir. Ayrı sürümlü plan ve kayıt sözleşmesi gerekir.

## Doğrulanan teknik sınırlar

- Docker volume verisi container kaldırıldığında kalır; boş volume bir image
  dizinine bağlanınca varsayılan copy-up davranışı olabilir. Bu davranış
  kontrol edilmeden izin veya başlangıç verisi garantisi sayılamaz.
  [Docker volume yaşam döngüsü](https://docs.docker.com/engine/storage/volumes/).
- Moby 27.5.1 aynı adla mevcut volume'u döndürebilir; create endpoint'inin
  HTTP 201 yanıtı yeni kaynak oluşturulduğunu tek başına kanıtlamaz. Ad, driver,
  scope, seçenekler ve Larenor kimlik etiketleri yeniden incelenmelidir.
  [Volume store](https://github.com/moby/moby/blob/v27.5.1/volume/service/store.go),
  [create router](https://github.com/moby/moby/blob/v27.5.1/api/server/router/volume/volume_routes.go).
- Local driver veri kökünü 0755 ve daemon'un root eşlemesiyle oluşturur.
  Katalogdaki `1000:1000` kullanıcıları için yazılabilirlik ayrıca gerekir.
  `NoCopy=true` izinleri düzeltmez; `NoCopy=false` da sabit image dizininin
  sahibi, modu ve başlangıç davranışı test edilmeden çözüm değildir.
  [Local driver](https://github.com/moby/moby/blob/v27.5.1/volume/local/local.go).
- `local` driver'ın seçenekleri bind/NFS/CIFS gibi başka mount yolları
  oluşturabilir. İlk destek yalnız seçenekleri tamamen boş local volume
  olmalıdır; harici driver/plugin ve `DriverOpts` kabul edilmemelidir.
  [Docker volume mount seçenekleri](https://docs.docker.com/engine/storage/volumes/#how-mounting-block-devices-works).
- Music Assistant'ın host ağı ve alıcı keşfi, volume desteğinden bağımsızdır.
  User namespace remap ile host network kısıtları devam eder.
  [Docker user namespace sınırları](https://docs.docker.com/engine/security/userns-remap/#user-namespace-known-limitations).

Ad ve etiketler dış Docker yöneticisine karşı değiştirilemez kimlik değildir.
API sürümü yükseltilmeden mevcut 1.47 sınırı korunmalı; Moby kaynak incelemesi
gerçek hedef Engine üzerinde test yapılmasının yerini tutmaz.

## Bağımlılık sırası

1. Mevcut sabit stack/catalog/policy'den türetilen ayrı volume önerisi ve katı
   response okuyucusu. Her managed target ayrı isim alır; mevcut katalogda
   yedi hedef vardır. `Mountpoint` hostta açılmaz veya Client'a taşınmaz.
2. Volume'a özel kalıcı intent ve reconcile kimliği. Eski inode journal'ı
   yeniden kullanılmaz. Yabancı mevcut kaynak otomatik sahiplenilmez;
   belirsiz create yanıtında yeniden create, silme veya geri alma yapılmaz.
3. Gerçek Engine üzerinde iki mimaride UID/başlangıç verisi doğrulaması.
   Güvenilir, dar kapsamlı bootstrap gerekirse bunun yetkisi ve sabit image
   sözleşmesi ayrıca tanımlanır. Yalnız test stub'ı yazılabilirlik kanıtı olamaz.
4. Güncel Core yönetici izni, durable begin, taze inspection, tek create ve
   yeniden inspection ile effect köprüsü. Başarılı response, tek başına kurulum
   veya o kaynağın sürekli münhasır sahibi olma yetkisi değildir.
5. Container mount bağlama, gerçek servis sağlık kontrolü, yeniden başlatma
   ve otomatik API bağlantıları. Bunlar geçmeden kurulum düğmesi açılmaz.

İlk negatif testler: aynı isimde yabancı volume; yanlış driver/scope; dolu
Options; yinelenen veya kesilmiş JSON; yanlış policy/nonce; yedi hedefin isim
çakışması; host Mountpoint sızıntısı. Olumlu kabul, gerçek Docker'da hizmet
kullanıcısının yazması ve Core/container yeniden başladıktan sonra verinin
korunmasıdır.

## Kullanıcı verisi ve kapsam

Kullanıcının mevcut medya arşivi/NAS dizini otomatik volume'a dönüşmez veya
kopyalanmaz. `approved_library` doğrulaması korunur; gelecekte Core'un kendi
medya arşivi ile dış kütüphanesi ayrı açık seçenekler olmalıdır. Host appdata
kökü için ölçülen boş alan Docker veri alanının boş alanı diye gösterilmez.
Yedekleme, geri yükleme ve kullanıcı tarafından açık kaldırma politikası da
volume verisinin yaşam döngüsüne göre tamamlanmalıdır.

Bu alternatif sonraki S06.3d uygulama kararı için kaydedildi. Native yolun
güvenlik denetimleri gevşetilmedi, yeni volume API'si bağlanmadı ve hiçbir
tamamlanma sayacı artırılmadı.
