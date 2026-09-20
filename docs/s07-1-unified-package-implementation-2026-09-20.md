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

Bu tanımın varsayılan tek kurulum girişi olabilmesi için Larenor'a ait boş
dizinleri/izinleri atomik hazırlayan paket yöneticisi, installation worker socket
yaşam döngüsü ve mevcut yabancı container/ağ/veriyi sahiplenmeme kontrolü hâlâ
tamamlanmalıdır.

## İkinci üç kriter — plan, host kapısı ve ayrık kabul

`unified_package.py` ilk tanımı değiştirmeden aşağıdaki üç ek yerel kabulü
uygular:

1. Yalnız 40 haneli kaynak revision'ı ve `config` adaptörünün çözdüğü tanımı
   kabul eder. Core ve altı bileşenin kimliği, image'ı, ağı ve bind'leri güvenilir
   katalog/tanımla eşleşirse kanonik, tekrar üretilebilir bir kurulum manifesti
   ve SHA-256 manifest digest'i üretir. Environment ve gizli anahtar alanları
   önizlemeye taşınmaz.
2. Manifestteki her Larenor-owned dizin salt okunur gözlem adaptörüyle
   doğrulanır. Symlink/eksik veya bozuk gözlem, yanlış sahip, gevşek izin ve aynı
   dosya sistemindeki toplam bütçeye yetmeyen kapasite fail-closed olur. Bütün
   kontroller geçmeden pull/up adaptörüne hiçbir çağrı yapılamaz.
3. Geçen preflight sonrasında altı sabit bileşen için exact image pull receipt'i
   ve çalışan container receipt'i doğrulanır. Bunlar her servisin bir kez yapılan
   authenticated readback sonucundan ayrı tutulur; container'ı çalışan ama
   authenticated readback'i başarısız servis `needs_attention` olur. Otomatik
   retry yoktur ve çıktı yalnız bounded, secret-free durum alanları taşır.

`tool.tests.unified_media_stack_runtime_test` Docker gerektirmeyen fake
`config`, host facts, pull/up ve authenticated-readback adaptörleriyle başarılı
akışı ve fail-closed sınırları kanıtlar. Gerçek Docker adaptörü, dizinleri atomik
hazırlayan sahiplik işlemi ve iki mimarili kurulum/restart kabulü hâlâ açık
olduğundan S07.1 `pending` ve sayaçlar değişmeden kalır.

## Üçüncü üç kriter — iki mimarili native paket kabulü

Yeni manuel `Unified Media Stack Native Acceptance` workflow'u yalnız exact
`main` revision'ında, Larenor'a ayrılmış self-hosted Linux amd64 ve arm64
runner'larında çalışır. Üç ek kabul şunlardır:

1. Exact Compose tanımı her mimaride `config --quiet` ve canonical config digest
   kontrolünden sonra pinned upstream image'ları pull eder, aynı revision'dan
   Core image'ını build eder ve `create → start → restart` zincirini tamamlar.
   Hareketli action/tool yoktur; checkout ve artifact action'ları commit SHA'ya,
   uv/Python ise exact sürüme bağlıdır.
2. Altı bileşenin exact image ve container kimliği, bind target/read-only
   eşlemesi, control ağı/host-network istisnası ve gerçek Docker DNS alias'ı hem
   ilk start hem restart sonrasında doğrulanır. Raw container kimliği yalnız
   digest olarak yayınlanır. Paket kabulü S06.5 bootstrap authority'sini
   üretmediği için authenticated readiness ayrı ve dürüst biçimde
   `not_verified` raporlanır; çalışan container servis doğrulaması sayılmaz.
3. Public receipt yalnız allowlist alanları taşır; environment, host path, log,
   URL veya gizli değer içermez. Native yürütücü sabit root/container/network'te
   önceden var olan kaynağı sahiplenmez. Her sonuç yolunda cleanup çalışır ve
   yalnız private ownership receipt ile root marker aynıysa oluşturulan
   container, ağ ve dizinler kaldırılır. Eksik/çift/belirsiz servis, değişmiş
   topoloji veya cleanup sahiplik kaybı fail-closed olur.

Yerel ortamda Docker ve bu iki self-hosted runner bulunmadığından gerçek native
workflow sonucu henüz yoktur. Policy ve fake-engine testleri yürütücü sırasını,
receipt doğrulamasını, belirsiz servis reddini ve sahiplikli cleanup'ı kanıtlar;
S07.1 bu yüzden `pending` ve sayaçlar değişmeden kalır.
