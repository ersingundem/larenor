# S07.1 birleşik medya paketi — ilk üç kriter

Bu dilim eski Music Assistant-only kurulumunun yerine geçecek birleşik paketin
tek, makinece okunur Compose tanımını ekler. Tanım henüz varsayılan
`compose.yaml` olarak etkinleştirilmedi; kurulum yöneticisi, sahiplik hazırlığı
ve gerçek amd64/arm64 CI kabulü tamamlanmadan kullanıcının mevcut CasaOS veya
Docker verisine dokunmaz.

Tam üç yerel kabul kriteri vardır:

1. `unified.compose.yaml`, Larenor Core ile katalogdaki Jellyfin, Seerr,
   Sonarr, Radarr, qBittorrent ve Music Assistant bileşenlerini tek proje içinde
   taşır. Altı upstream image hareketli tag yerine katalogdaki OCI index
   digest'ine bağlıdır; sürüm, dağıtım lisansı ve kaynak revision etiketi ile
   iki katalog mimarisi sözleşmede doğrulanır. Core build'i exact 40 haneli
   source revision ister.
2. Container/DNS adları, `larenor-server-control-v1` ağı ve
   `/var/lib/larenor-server` altındaki bütün bind source/target eşlemeleri
   sabittir. Bind mount'lar host dizini kendiliğinden oluşturmaz. Music
   Assistant'ın alıcı keşfi için gerekli host-network istisnası açıkça ayrılır;
   Core host gateway'i sabit adla görür.
3. Paket servisler arası URL, API tokenı, parola veya kimlik bilgisi environment
   değişkeni istemez. `env_file`, Compose secret girdisi ve serileştirilmiş URL
   yoktur; private kimlik üretimi ve eşleştirme S06.5'teki Core işlerine ait
   kalır.

`tool.tests.unified_media_stack_deployment_test` bu üç kriteri doğrudan paket
tanımı ve packaged catalog ile karşılaştırır. Yerel makinede Docker CLI olmadığı
için gerçek `docker compose config`, image pull ve iki mimarili süreç kabulü
çalıştırılmadı. B1 bağımlılığı da tamamlanmadığı için S07.1 `pending` kalır;
sayaç artmaz.

Bir sonraki dilim, Larenor'a ait boş dizinleri/izinleri atomik hazırlayan paket
yöneticisini, installation worker socket yaşam döngüsünü ve mevcut yabancı
container/ağ/veriyi sahiplenmeme kontrolünü eklemelidir. Ancak bundan sonra bu
tanım varsayılan tek kurulum girişi olabilir.
