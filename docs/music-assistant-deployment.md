# Eski Music Assistant dağıtım dilimi — geçiş referansı

**Güncel karar:** Music Assistant ve medya bileşenleri tek Larenor Server kurulumuna dahil edilecek; ayrı MA kurulumu, hesabı ve elle Client tokenı hedef akış değildir. [Bütünleşik medya planını](integrated-media-stack.md) izleyin. Aşağıdaki adımlar önceki MA-only paketin geçiş referansıdır; yeni Larenor kurulum yönergesi olarak kullanılmaz.

Eski dilimin durumu: **paket hazır; canlı kurulum yapılmadı.** Kullanıcının tercihiyle kurulum diğer uygulama işleri tamamlandıktan sonra elle yapılacak. Proxmox üzerindeki ayrı Linux VM ve mevcut CasaOS sunucusu aynı Compose paketini kullanabilir. Bu belge belirli bir VM, ağ köprüsü, sağlayıcı hesabı veya hoparlör üzerinde doğrulanmış kurulum iddiası taşımaz.

**Geçiş notu:** Kullanıcının son kapsamıyla **Larenor Server**, kendi login/veritabanı, şifreli entegrasyon tokenı saklama ve Client güncelleme akışı olan gerçek backend ürünü olacak. Bu belgede tamamlanan mevcut Compose **yalnız Music Assistant dağıtım dilimidir**; söz konusu backend özelliklerini henüz sağlamaz. Birleşik paket hazırlanırken MA opsiyonel `music-assistant` iç servisine ayrılacak; aşağıdaki geçici `larenor-server` servis adı/path'leri o paketle birlikte güncellenecek. Bu ara paket tüm Larenor Server ürünü olarak kurulmuş veya tamamlanmış sayılmamalıdır.

Android uygulama **Larenor Client** adını kullanır. Bu dilimde açılan müzik web arayüzü ve motor resmi **Music Assistant** projesine aittir; yeniden markalanmış upstream yazılım sunulmaz. Upstream Apache-2.0 lisansı ve proje atfı korunur. [Music Assistant projesi](https://github.com/music-assistant/server).

## Sabit sürüm ve paket

5 Eylül 2026'da resmi GitHub release API'sindeki son kararlı sürüm **2.10.2**, yayın zamanı **4 Eylül 2026 08:40:43 UTC** olarak doğrulandı. İmaj etiketi yanında GHCR manifest özeti de sabitlendi; Linux `amd64` ve `arm64` platformları manifestte mevcut. [2.10.2 sürümü](https://github.com/music-assistant/server/releases/tag/2.10.2), [resmi paket](https://github.com/music-assistant/server/pkgs/container/server).

```text
ghcr.io/music-assistant/server:2.10.2@sha256:09c02b4ee491976efa6d698265f72571f064031bb1a2c9a1c32e104392209690
```

| Dosya | İşlev |
| --- | --- |
| [compose.yaml](../deploy/larenor-server/compose.yaml) | Proxmox VM / CasaOS için aynı servis; `larenor-server` proje ve konteyner adı |
| [local-music.compose.yaml](../deploy/larenor-server/local-music.compose.yaml) | İsteğe bağlı, salt okunur `/srv/music` → `/media` bağı |
| [manage.py](../deploy/larenor-server/manage.py) | Salt okunur ön kontrol, çalışma yapılandırması kontrolü, sınırlı HTTP probe ve açıkça istenen yedekleme |
| [icon.png](../deploy/larenor-server/icon.png) | Mevcut Larenor uygulama ikonunun değişmeden alınmış kopyası |

Compose dosyaları YAML 1.2'nin kabul ettiği JSON yazımındadır. Böylece testler ilave Python YAML bağımlılığı olmadan gerçek dağıtım dosyasını denetler. Sunucu anahtarı, sağlayıcı çerezi veya HA tokenı içermezler. İmajın ve tüm verilerin indirilmesi bu hazırlık sırasında yapılmadı.

## Hedef makine ve ağ

Music Assistant'ın belgelenmiş alt sınırı güncel, 64 bit işlemci ve 2 GB RAM'dir; Smart Fades için en az 4 GB gerekir. Aşağıdaki VM tahsisi **Larenor başlangıç önerisidir**, performans garantisi değildir. Kütüphane ve analiz yüküne göre ölçülerek artırılır. [Kurulum gereksinimleri](https://www.music-assistant.io/installation/).

| Kaynak | Başlangıç önerisi |
| --- | --- |
| CPU | 2 vCPU; aynı anda çoklu analiz / DSP için yük ölçümünden sonra 4 vCPU |
| RAM | 4 GB; CasaOS'taki diğer uygulamalara ayrılan RAM'in üzerinde boş kapasite |
| Disk | 32 GB sanal disk + kütüphane ve önbellek büyümesine uygun boş alan; müzik arşivi ayrıca |
| Konuk OS | 64 bit Debian 13 veya Ubuntu Server 24.04 LTS; Docker'ın resmi destek matrisini kurulum günü tekrar kontrol et |
| Ağ | Kablolu ana makine, ayrılmış IP/DHCP rezervasyonu; HA ve alıcılarla aynı güvenilir LAN |

Proxmox'ta yeni VM'nin VirtIO ağ kartı, ev LAN'ına bağlı **mevcut** Linux köprüsüne bağlanır. Köprünün adını `vmbr0` varsaymayın; seçimi PVE arayüzünde doğrulayın. Bu paket PVE hostunun köprü, VLAN veya yönlendirme ayarlarını değiştirmez. Linux bridge, sanal makinenin fiziksel ağa kendi MAC adresiyle çıkmasını sağlar. [PVE ağ belgesi](https://pve.proxmox.com/pve-docs/chapter-sysadmin.html#sysadmin_network_configuration).

VM için VirtIO disk/ağ aygıtları uygun başlangıçtır. QEMU Guest Agent seçeneği ancak konukta agent kuruluysa etkinleştirilir. GPU, ses kartı, USB passthrough veya iç içe sanallaştırma gerekmez; bu profil ağ hoparlörlerine sunucu üzerinden yayın içindir. [PVE VM / agent belgesi](https://pve.proxmox.com/pve-docs/chapter-qm.html).

MA, HA ve alıcılar arasında farklı VLAN, misafir Wi-Fi veya AP isolation bırakılması keşfi bozabilir. mDNS yayınının görünmesi tek başına ses akışının ulaşabildiğini kanıtlamaz. Mevcut ağı değiştirmeden önce yerleşimi kontrol edin; yardımcı betik güvenlik duvarını kapatmaz. [MA ağ açıklaması](https://www.music-assistant.io/faq/networking/).

Paket `network_mode: host` kullanır; `ports:` eklemeyin. Host modu ayrı Docker ağ alanı sağlamaz ve port eşlemeleri uygulanmaz. Bu nedenle CasaOS üzerindeki port çakışmaları doğrudan hosttaki servislerle ilgilidir. [Docker host networking](https://docs.docker.com/engine/network/drivers/host/).

Web arayüzü varsayılan olarak `8095`, HTTP akış sunucusu `8097` kullanır; ikinci port doluysa MA başka port seçebilir. Alıcı protokolleri ek/dinamik TCP ve UDP bağlantıları kullanabilir: sadece bu iki portu açmak eksiksiz ağ desteği anlamına gelmez. Paket internete port yönlendirme, ters proxy veya otomatik firewall kuralı eklemez. [MA kurulum / ağ sınırları](https://www.music-assistant.io/installation/).

## Elle hazırlık ve başlatma

Aşağıdaki komutlar **gelecekte seçilen Linux VM veya CasaOS hostunda**, dosyalar incelendikten sonra çalıştırılacak örneklerdir. Burada çalıştırılmadılar. Yeni VM'de Docker Engine ve Compose eklentisini dağıtımın resmi depo yönergesiyle kurun; indirilmiş shell betiğini `sudo`ya borulayan yol kullanılmaz. [Docker Debian](https://docs.docker.com/engine/install/debian/), [Docker Ubuntu](https://docs.docker.com/engine/install/ubuntu/).

**CasaOS zaten Docker yönetiyorsa Docker'ı bu belge üzerinden yeniden kurmayın veya daemon ayarlarını değiştirmeyin.** Önce mevcut `docker compose version` sonucunu ve Custom Install desteğini kontrol edin. Aynı servisi hem CLI hem CasaOS ile ikinci kez oluşturmamak için tek yönetim yolu seçin.

Paket konteyner içinde `0:0` kullanır; ayrıcalıklı mod açmaz. Resmi imajın giriş noktası ve kalıcı dizini korunur. Hostta veri dizini root sahibi ve `0700` olmalı; parent dizinler de güvenilir olmalıdır. Docker yönetebilen hesapların host üzerinde root düzeyinde etkisi vardır; yalnız dosya izinleri Docker yöneticisinden gizlilik sağlamaz. [Resmi imaj tanımı](https://github.com/music-assistant/server/blob/2.10.2/Dockerfile), [Docker yetki modeli](https://docs.docker.com/engine/install/linux-postinstall/).

Repo kökünden, yeni kurulum için:

```sh
sudo install -d -m 0755 -o root -g root /opt/larenor-server
sudo install -m 0644 deploy/larenor-server/compose.yaml /opt/larenor-server/compose.yaml
sudo install -m 0644 deploy/larenor-server/local-music.compose.yaml /opt/larenor-server/local-music.compose.yaml
sudo install -m 0644 deploy/larenor-server/manage.py /opt/larenor-server/manage.py
sudo install -m 0644 deploy/larenor-server/icon.png /opt/larenor-server/icon.png
sudo install -d -m 0700 -o root -g root /var/lib/larenor-server /var/lib/larenor-server/data
sudo python3 /opt/larenor-server/manage.py preflight
sudo docker compose -f /opt/larenor-server/compose.yaml config --quiet
```

Var olan kurulumun dosyalarını bu bootstrap adımlarıyla üzerine yazmayın; güncelleme bölümünü izleyin. `preflight` sistem, özel veri dizini, Compose sözdizimi ve iki yerel TCP portu hakkında sınırlı kontrol yapar. Bir kontrol uygun değilse çıkış kodu `1` olur. Başarısı boş disk, gerçek multicast, tüm firewall kuralları veya alıcı uyumluluğu kanıtı değildir. Port doluysa mevcut servisi kendiliğinden durdurmaz. Çalışan Larenor Server için `preflight` yerine `verify-runtime` kullanın.

CLI yolu seçildiyse, kontrollerden sonra kullanıcının elle başlatacağı iki komut:

```sh
sudo docker compose -f /opt/larenor-server/compose.yaml pull
sudo docker compose -f /opt/larenor-server/compose.yaml up -d
sudo python3 /opt/larenor-server/manage.py verify-runtime
```

`unless-stopped` ilk kurulumdan sonra Docker yeniden açıldığında servisi geri getirebilir; kullanıcı `stop` ile durdurduysa otomatik yeniden başlatmaz. Bu VM/servis davranışıdır; Android Client için bootta otomatik ses başlatma eklemez. [Docker restart politikaları](https://docs.docker.com/engine/containers/start-containers-automatically/).

`verify-runtime`, imaj+digest, gerçek konteyner kimliği, host ağ, root kullanıcı, `/data` bağı, kapatılmış yetenekler ve log sınırlarını Docker'dan küçük bir şablonla okur. Environment, erişim tokenı veya container log dökümü yapmaz. `privileged`, aşağıdaki tek izin dışındaki capability'ler, cihaz bağı, Docker socket, `SYS_ADMIN` ve `unconfined` bu profile dahil değildir. JSON logları dosya başına `10m`, en fazla `3` dosya olarak döner; MA'nın veri dizinindeki diğer dosyalarının büyümesini ayrıca izleyin. [Docker log rotation](https://docs.docker.com/engine/logging/drivers/json-file/).

Music Assistant 2.10.2 AirPlay sağlayıcısı, ortak PTP saat servisi için UDP **319/320** portlarına bağlanır. `cap_drop: ALL` tek başına bu işlevi bozacağından yalnız **`NET_BIND_SERVICE`** geri verilir; `SYS_ADMIN`, `NET_ADMIN` veya `NET_RAW` eklenmez. Aynı hostta bu portları kullanan başka servis varsa HomePod/AirPlay 2 senkronizasyonu etkilenebilir; bu iki UDP portu preflight'ın TCP kontrolünde ölçülmez. Mevcut servisi durdurmadan çakışmayı inceleyin. Bu karar sabitlenen sürümün uygulama belgesine dayanır. [MA 2.10.2 AirPlay PTP gereksinimi](https://github.com/music-assistant/server/blob/2.10.2/music_assistant/providers/airplay/README.md).

### CasaOS Custom Install

CasaOS'un resmi anlatımı Docker Compose import ile özel uygulama kurulumunu gösteriyor. Menü adı ve aktarılan alanların eksiksizliği sürüme bağlı olduğundan kurulum ön izlemesini kontrol edin. [CasaOS resmi Custom Install anlatımı](https://www.youtube.com/watch?v=ToV6vRIl3Nk).

1. Veri dizinini yukarıdaki gibi hazırlayın; CasaOS'ta **Custom Install / Import Docker Compose** yoluna `compose.yaml` içeriğini verin.
2. Görünen ad `Larenor Server`, ana servis ve container adı `larenor-server` kalsın. İmaj alanında **etiket ve `@sha256:…` birlikte**, ağ modu `host`, veri hedefi `/data`, kaynak `/var/lib/larenor-server/data` olmalı. Port yönlendirmesi eklenmemeli.
3. `cap_drop: ALL`, yalnız `cap_add: NET_BIND_SERVICE`, `no-new-privileges:true`, root kullanıcı, bounded log ayarları ve bind `create_host_path:false` korunmalı. Importer bir alanı silebilir; ayarın UI'de görünmemesi doğru uygulandığı kanıtı değildir.
4. Kurulumdan sonra aynı hostta `verify-runtime` çalıştırın. Uyuşmazlıkta sağlayıcı hesabı eklemeyin; oluşturulan tanımı karşılaştırıp elle düzeltin. CasaOS sürümü gereken Compose alanlarını koruyamıyorsa imajı gevşetmeyin; aynı hostta doğrudan Compose yönetimini veya ayrı VM yolunu seçin. CasaOS dashboard görünürlüğü bu alternatifte ayrıca doğrulanır.

`x-casaos` alanlarında `main`, çok dilli `title`, `port_map`, `scheme`, `index`, mimariler ve kurulum notları resmi AppManagement şemasına göre kullanılıyor. `icon` şu an boş; paket `icon.png` içerir. Şema URL alanını tanımlar, yerel dosya yüklemenin her sürümde bulunduğu doğrulanmadı. İkonu göstermek için mevcut güvenilir statik dosya servisinizde bu dosyaya erişilebilir bir URL sağlayıp CasaOS ikon alanına elle girin. Paket bunun için yeni web servisi açmaz; özel GitHub reposuna anonim ikon erişimi varsayılmaz. [CasaOS AppManagement şeması](https://github.com/IceWhaleTech/CasaOS-AppManagement/blob/main/api/app_management/openapi.yaml), [Compose import uygulaması](https://github.com/IceWhaleTech/CasaOS-AppManagement/blob/main/service/compose_app.go).

CasaOS için başka veri konumu seçilecekse önce root/`0700` izinli dizini hazırlayın, Compose `source` değerini değiştirin ve helper komutlarına aynı `--data-dir /tam/yol` değerini verin. `/DATA/AppData` altında sıradan dosya paylaşımı gibi açık izinli bir klasör kullanmayın. Import ve yedekleme helper'ının yönettiği container adını değiştirmeyin.

### İsteğe bağlı yerel müzik klasörü

Hosttaki gerçek arşiv `/srv/music` altında okunabilir olduğunda ikinci Compose dosyası eklenebilir. Boş klasör yaratıp mevcut arşiv varmış gibi kabul etmeyin. MA ayarlarında **Local Files** kaynağı `/media` olarak seçilir. Dosyaları konteynerden değiştirmek bu profile dahil değildir; SMB/NFS gerekirse hostta ayrıca yetkilendirilmiş mount hazırlanır. MA'nın konteyner içinden ağ diski bağlaması için ek ayrıcalık verilmez. [MA Docker bind örneği](https://www.music-assistant.io/installation/).

```sh
sudo docker compose -f /opt/larenor-server/compose.yaml -f /opt/larenor-server/local-music.compose.yaml config --quiet
sudo docker compose -f /opt/larenor-server/compose.yaml -f /opt/larenor-server/local-music.compose.yaml up -d
```

CasaOS'ta `/media` bind'ını aynı import tanımına salt okunur ekleyin; helper hedefin salt okunur gerçek bir dizin olmasını kontrol eder. Bir deployment seçildikten sonra güncellemelerde aynı dosya/override kümesini kullanın.

## İlk açılış, hesaplar ve Larenor Client

Tarayıcıdan `http://SUNUCU_IP:8095` adresi açılır. Standalone ilk açılışta Music Assistant kendi yönetici hesabını kurdurur; güvenilir LAN içinde bu kurulum tamamlanır. Hesap bilgilerini Compose, shell komutu, Git veya Larenor yardımcısına yazmayın. [MA ilk oturum kurulumu](https://www.music-assistant.io/first-run/).

İsteğe bağlı salt okunur erişim kontrolü:

```sh
python3 /opt/larenor-server/manage.py probe --url http://SUNUCU_IP:8095
```

Bu komut yalnız `GET /info` yapar; token/çerez kabul etmez, sistem proxy'sini kullanmaz, redirect izlemez, TLS doğrulamasını kapatmaz. Yanıt en fazla 64 KiB, socket bekleme süresi 5 saniyedir; gövde okurken süre bütçesi de kontrol edilir. DNS çözüm süresi OS'ye bağlıdır. `401`, `403`, redirect, timeout, bozuk/HTML yanıtı ve sürüm uyuşmazlığı ayrı sonuçlardır. `server_reachable`, login veya playback başarısı değildir. Bu sürümün `/info` yolu public server-info döndürür. [HTTP handler](https://github.com/music-assistant/server/blob/2.10.2/music_assistant/controllers/webserver/controller.py), [server-info alanları](https://github.com/music-assistant/server/blob/2.10.2/music_assistant/mass.py).

| Kaynak / hedef | Manuel kurulum sınırı |
| --- | --- |
| Spotify | Premium gerekir. OAuth ve seçilen playback motorunun onayı MA'nın kendi akışında yapılır. Soloist ve topluluk librespot seçeneklerinin koşulları/hesap desteği farklıdır; paket motor seçmez veya erişim garantisi vermez. [MA Spotify](https://www.music-assistant.io/music-providers/spotify/) |
| Apple Music | MA'nın güncel sağlayıcı akışı ve hesabın abonelik/bölge koşulları izlenir. Apple oturumu Larenor Client'a veya kurulum betiğine aktarılmaz; DRM/aile hesabı/tüm kalite seçenekleri destekleniyormuş gibi sunulmaz. [MA Apple Music](https://www.music-assistant.io/music-providers/apple-music/) |
| YouTube Music | Sağlayıcının mevcut kimlik doğrulama gereksinimleri kendi MA ekranında tamamlanır. Bu paket çerez toplamaz, PO token servisi açmaz; upstream değişikliklerinde erişimin sürmesi garanti edilmez. [MA YouTube Music](https://www.music-assistant.io/music-providers/youtube-music/) |
| AirPlay / HomePod / Apple TV | MA Player Providers içindeki AirPlay hedefleri seçilir. Setup/PIN veya parola istenirse cihaz sahibinin onayıyla tamamlanır. Apple TV ek eşleştirme gerektirebilir; Home/HomePod güvenlik ayarları otomatik gevşetilmez. [MA AirPlay](https://www.music-assistant.io/player-support/airplay/) |
| Google Cast | MA'nın Cast sağlayıcısı ve gerçek alıcı ile denenir. UI'de hedef görünmesi ses duyulduğu anlamına gelmez; VM'den alıcıya akış erişimi ayrıca test edilir. [MA Cast](https://www.music-assistant.io/player-support/google-cast/) |

HA entegrasyonu **ayrı, kullanıcının yapacağı bir adımdır**: HA'nın Music Assistant entegrasyonunda bu sunucu seçilip MA kullanıcı yetkisi bağlanır. Sunucuyu ayağa kaldırmak HA entegrasyonunu kendiliğinden kurmaz. Larenor Client'ın mevcut müzik ekranı HA üzerinden kaynak/kütüphane/kuyruk ve hedef eylemlerini kullanır; sunucu sağlayıcı şifrelerini kendi içinde toplamaya başlamaz. [HA Music Assistant entegrasyonu](https://www.home-assistant.io/integrations/music_assistant/), [Larenor müzik API sınırı](../lib/features/media/music/data/music_api.dart).

## Yedekleme, güncelleme ve geri dönüş

Proxmox VM yolu için ilk seçenek, bakım zamanında PVE'nin **stop** modunda VM yedeğidir. Snapshot daha az kesinti sağlar fakat aynı uygulama tutarlılığı iddiasını taşımaz; Guest Agent tek başına veritabanı yedeği değildir. Yedeğin saklandığı diski VM'den bağımsız tutun, erişimini kısıtlayın ve geri yüklemeyi test VM'de doğrulayın. [PVE yedekleme modları](https://pve.proxmox.com/pve-docs/chapter-vzdump.html).

VM ve CasaOS için paket ayrıca durdurulmuş `/data` arşivi hazırlayabilir:

```sh
sudo install -d -m 0700 -o root -g root /var/backups/larenor-server
python3 /opt/larenor-server/manage.py backup
sudo python3 /opt/larenor-server/manage.py backup --execute
```

İlk komutun ardından `backup` yalnız plan döndürür. **Sadece `--execute` kesinti yaratır**: private dizinleri ve mevcut container kimliğini doğrular; kilit alır; servis çalışıyorsa aynı ID'yi durdurur; durduğunu ve normal çıkışını tekrar kontrol eder; arşivi `0600` olarak yazar; dosya ile dizini diske senkronlar. Servis başlangıçta çalışıyorsa `finally` içinde yeniden başlatır. Başlangıçta durmuş servisi başlatmaz. Arşivde sürüm/format metadatası ve `/data` vardır; dış müzik klasörü ve Compose ayrı saklanır. Symlink/özel dosya bulursa sessizce atlamak yerine yedeklemeyi reddeder.

Yedek penceresinde CasaOS'tan yeniden kurma, otomatik image güncelleme veya başka bir yedekleme çalıştırmayın. Helper kendi paralel çalışmasını kilitler; başka yöneticinin Docker işlemlerini küresel olarak kilitleyemez. Disk dolması veya arşiv hatasında restart denenir. Temizlik/restart başarısızlığı ayrı hata döndürür; tamamlanmış özel arşiv varsa korunur. Zorla öldürme, elektrik kesilmesi veya erişilemeyen Docker daemon'u sonrası `finally` garantisi yoktur: servis durumunu ve özel yedek dizinini elle kontrol edin. `backup_complete` uygulamanın alıcılarda çaldığını değil, arşiv ve servis geri başlatma kontrolünü belirtir.

Arşiv sağlayıcı oturumları içerebilir. `0600` **şifreleme değildir**; dış kopyayı güvendiğiniz şifreli yedek deposuna taşıyın. Bu dosyaları repo, sohbet eki veya issue olarak paylaşmayın. Önceki yedek otomatik silinmez. Paket `.gitignore` ek koruma sağlar; asıl veri/yedek yolları repo dışında kalır.

Geri yükleme otomatik değildir. Ayrı, boş, özel izinli veri dizininde ve aynı sabit imajla prova yapılır; arşiv içeriği ve relative `data/` yapısı incelenir, path traversal/harici link kabul edilmez. Canlı dizinin üzerine otomatik `tar -x` uygulanmaz. Eski ve kopya sunucuyu aynı LAN'da aynı anda yayınlamayın. Prova sonunda hesap, kütüphane, bir hedefte gerçek playback ve HA bağlantısı doğrulanır; ancak sonra elle geçiş yapılır. Geçiş başarısızsa eski durdurulmuş kurulum ve veri korunarak geri dönülür.

Sürüm yükseltirken önce özel yedek alın, yeni kararlı release notlarını inceleyin ve tag+digest'i birlikte güncelleyin; helper/testteki pin de aynı olmalı. Deneme instance'ında ayrı `/data` kullanın; çalışan veritabanında beta/kararlı arasında rastgele geçiş yapmayın. Otomatik image updater eklenmedi. MA yalnız güncel kararlı sürüm için güvenlik desteği verdiğinden sabitleme periyodik güncelleme incelemesinin yerine geçmez. [MA güvenlik politikası](https://github.com/music-assistant/server/security).

## Son manuel kabul

- Proxmox seçilirse node, kullanılacak mevcut bridge, storage, boş VMID, disk bütçesi ve bakım/yedek hedefi kurulum anında seçilir; şu an bilgi bekleyen canlı işlem yoktur. CasaOS seçilirse sürüm, Docker/Compose sürümü, mimari ve mevcut port/veri durumu kaydedilir.
- `config --quiet` ve `verify-runtime` geçer; doğru sürüm görünür; ilk kullanıcı güvenilir LAN'da kurulur. WAN portu açılmamıştır.
- Bir sağlayıcı bağlanır; bir gerçek alıcıda seçilen parça duyulur. Duraklat/devam/ses/seçilen kuyruk davranışı kontrol edilir; 30 dakikalık dinlemede kesilmeler ve VM yükü not edilir.
- HomePod/AirPlay ile Cast ayrı denenir. Huawei tabletin GMS durumundan bağımsız olarak sunucu üzerinden hedef kontrolü değerlendirilir; yerel telefondan Cast SDK varmış gibi gösterilmez.
- Kullanıcı isterse HA entegrasyonunu ekler; ardından Larenor Client'ta aynı hedef ve kuyruk kontrol edilir. Kurulum sırasında otomasyon, kapı veya başka HA varlığı değiştirilmez.
- Servis/VM yeniden başlatma, ağ kopması, hesap yetkisi reddi ve yedekten izole prova sonucu kaydedilir. Bu donanım testleri henüz yapılmadı.

Paketin CI'ye uygun testleri [music_assistant_deployment_test.py](../tool/tests/music_assistant_deployment_test.py) içindedir; fake Docker ve loopback HTTP sunucusu kullanır. Compose temel dosyası ve readonly müzik override'ı, checksum'u doğrulanmış resmi Docker Compose **v5.5.1** ile daemon'a bağlanmadan `config --quiet` üzerinden denetlendi. Bu kontroller CasaOS importer sürümü, gerçek Docker runtime veya fiziksel hoparlör için uçtan uca test yerine geçmez.
