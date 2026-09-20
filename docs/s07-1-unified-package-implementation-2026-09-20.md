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

Yeni `Unified Media Stack Native Acceptance` workflow'u ilgili pull request
değişikliklerinde ve manuel exact `main` çalıştırmalarında GitHub-hosted Linux
amd64 ve arm64 runner'larında çalışır. İlgisiz değişikliklerde aynı required
check adları hızlı native-scope sonucu üretir. Üç ek kabul şunlardır:

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

Gerçek GitHub-hosted amd64/arm64 workflow sonucu henüz yoktur. Policy ve
fake-engine testleri otomatik PR tetikleyicisini, fail-open scope kararını,
yürütücü sırasını, receipt doğrulamasını, belirsiz servis reddini ve sahiplikli
cleanup'ı kanıtlar; S07.1 bu yüzden `pending` ve sayaçlar değişmeden kalır.

## Saldırgan paket incelemesi

Native kabul kodu ilk incelemede iki gerçek sınır kusuru taşıyordu:

- **P1 — rendered config bağı kopuktu.** Docker Compose'un normalize ettiği
  `config --format json` yalnız hashleniyor, planner ise ham dosyadan manifest
  üretiyordu. `validate_rendered_config` artık exact servis kümesi, image/user,
  capability/security option, environment/label, bind, port, control ağı,
  host-network istisnası, Core build context/Dockerfile ve private-field
  yokluğunu gerçek rendered config üzerinde doğrulamadan prepare/pull yapmaz.
- **P2 — cleanup proje sahipliği yeterince dar değildi.** Sabit Compose proje
  adıyla `down`, foreign veya yarışta oluşmuş aynı adlı projeyi hedefleyebilirdi.
  Her native çalıştırma artık CSPRNG operation kimliğinden özel bir Compose
  project adı üretir; private ownership receipt bu adı revision ve root marker
  ile bağlar. Bütün Compose mutasyonları ve cleanup aynı özel proje adıyla
  çalışır. Eşleşmeyen receipt/marker hiçbir Docker veya dizin silme işlemi
  başlatmaz.

## Dördüncü üç kriter — CasaOS ve genel Compose kurulum bundle'ı

`deployment_bundle.py`, mevcut `unified.compose.yaml` tanımını tek canonical
kaynak olarak doğrular ve aynı kaynaktan CasaOS import çıktısı ile genel Docker
Compose/Proxmox VM çıktısı üretir. Her iki çıktı da yalnız `larenor-core`
servisinin 8098 girişini yayınlar. Jellyfin, Seerr, Sonarr, Radarr ve
qBittorrent yalnız control ağında kalır; Music Assistant'ın LAN discovery için
gerekli host-network istisnası açıkça korunur. Altı upstream image katalogdaki
exact OCI index digest'leriyle bağlıdır.

Kullanıcının değiştirebildiği yüzey yalnız `.env.example` içindeki dört alandır:
data root, timezone, locale ve Core host portu. Bu dosyada veya üretilen
manifestte servisler arası URL, API tokenı, parola ya da credential bulunmaz.
CasaOS `main`, mimari, port ve giriş yolu metadata'sı aynı plan içinde üretilir;
generic ve CasaOS çıktı digest'leri ortak manifest digest'ine bağlanır.
CasaOS metadata'sı stable reverse-domain `id`, string `port_map`, source
revision'a bağlı icon URL'si, yerelleştirilmiş başlık ve semver Core sürümünü
CasaOS AppStore'un güncel `x-casaos` sözleşmesine göre taşır:
<https://github.com/IceWhaleTech/CasaOS-AppStore/blob/main/docs/specs/compose-and-x-casaos.md>.

Varsayılan komut salt okunur JSON üretir:

```sh
python3 deploy/larenor-server/deployment_bundle.py \
  --source-revision 0123456789abcdef0123456789abcdef01234567 \
  --format manifest
```

`--format docker-compose` genel Linux/Proxmox VM, `--format casaos` CasaOS
Custom Install çıktısını verir. Planlayıcı Docker socketine bağlanmaz, subprocess
başlatmaz, dizin yaratmaz, image çekmez ve daemon durumunu değiştirmez.

Install ve upgrade preflight aynı digest'e bağlı bundle'ı yeniden üretip karşılaştırır;
amd64/arm64 mimarisini, bütün owned dizinlerin tür/sahip/izin bilgisini, aynı
dosya sistemindeki birleşik kapasiteyi ve özel backup/rollback hedeflerini
raporlar. Eksik veya bozuk gözlem, symlink, beklenmeyen mimari, yanlış sahip ya
da yetersiz kapasite `ready=false` üretir. Bu salt okunur sonuç ayrıca bir apply
yetkisi veya mutation değildir. Gerçek GitHub-hosted iki mimari sonucu ve B1
bağımlılığı açık olduğundan S07.1 `pending` kalır.

### Bundle saldırgan incelemesi

Dar inceleme iki P2 sınırını kapattı:

- Data root'un yalnız bind leaf'lerini incelemek, root veya `components/core`
  gibi ara dizin symlink'lerini kaçırabiliyordu. Manifest artık data root ile
  bütün owned ara dizinleri ayrı private gereksinimler olarak üretir
  (`deployment_bundle.py:168-199`); preflight her birinin final bileşenini
  `directory`, exact owner ve kapalı izin olarak doğrular
  (`deployment_bundle.py:318-352`). Root ve ara symlink RED regresyonları
  `unified_media_stack_bundle_test.py:155-170` içindedir.
- Core portu önce `int()` ile normalize edildiği için baş/son boşluk, `+` ve
  leading-zero biçimleri farklı ayar metinleriyle aynı portu üretebiliyordu.
  Ayar sınırı artık yalnız canonical decimal metni ve 1024-65535 aralığını
  kabul eder (`deployment_bundle.py:114-132`); RED örnekleri
  `unified_media_stack_bundle_test.py:135-138` ile sabittir.

CasaOS ve generic Compose ayrışması bütün bundle'ın canonical yeniden üretimiyle
reddedilir (`deployment_bundle.py:287-298`). Backup ve rollback hedefleri data
root'un sibling'idir ve owned preflight'a dahildir (`deployment_bundle.py:178-218`).
Python'ın sınırsız tamsayıları ile bounded canonical belge birlikte disk
toplamasında taşmayı önler; negatif veya type-confused host değerleri fail-closed
olur. Non-Core `ports` ve Music Assistant dışındaki host-network tanımları
üretilmeden reddedilir (`deployment_bundle.py:146-166`). Compose/CasaOS digest'leri
manifestte, manifest dahil bütün çıktı da bundle digest'inde bağlıdır; değiştirilmiş
manifest ve public port regresyonları `unified_media_stack_bundle_test.py:105-115`
ve `:176-179` tarafından reddedilir.

Ek denetimde CasaOS/Proxmox için Linux bind/bridge/host-network sözleşmesinin
Compose kaynağında taşınabilir kaldığı; public receipt'te host path, environment,
URL, log, raw container kimliği veya authority bulunmadığı; symlink/owner/mode ve
birleşik kapasite gözlemlerinin mutation öncesi kapandığı; OCI index digest ile
native platformun birlikte doğrulandığı; bootstrap authority verilmediğinde
readiness'nin `verified` yapılmadığı doğrulandı. Bu alanlarda yeni P1/P2
bulunmadı. Gerçek runner sonucu hâlâ zorunlu dış kanıttır.

Son güven sınırı incelemesinde Compose kaynağındaki bind yollarının yalnız metin
önekine göre doğrulandığı görüldü. Planlayıcı artık kaynak ve hedef yollarında
`..`, gereksiz ayraç, göreli veya kök hedef biçimlerini reddeder; owned kaynak
gerçek bir `/var/lib/larenor-server` alt yolu olmak zorundadır. Container
kimliğinde hem UID hem GID signed 32-bit aralığında doğrulanır. Böylece inceleme
altındaki trusted Compose değişikliği owned root dışına bind veya taşan GID ile
preflight üretmeden fail-closed olur.

Paket, S06.6 kapanışını içeren `67261f69` main tabanına yeniden bağlandı.
Kabul edilen taban **17/125 (%13,6)** ve **0/63**'tür; S07.1 gerçek PR
amd64/arm64 yürütmesi tamamlanana kadar bu dilim sayaç yükseltmez.

İlk gerçek PR native çalışması, güncel Docker Compose'un image varsayılanını
temsil etmek için `command: null` ve `entrypoint: null` alanlarını eklediğini
gösterdi. Validator bu güvenli normalizasyonu kabul eder; iki alanın herhangi
bir gerçek override değeri taşıması hâlâ mutation öncesi fail-closed olur.
