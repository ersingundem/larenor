# S06.3f — native image ve control-network kaynak kabulü

Bu dilim Larenor Core’un kuruluma geçmeden önce ihtiyaç duyduğu iki Engine
kaynağını gerçek Linux üzerinde sınamak için dar bir fixture ekler. Çıktı
`resources_ready` durumudur; hizmetin kurulduğunu, çalıştığını veya sağlıklı
olduğunu bildirmez. `installAvailable=false` kalır.

## Etki sınırı

Fixture yalnız katalogda digest ile sabit Jellyfin image’ı için pull ve inspect,
tek `Internal=true`, `Attachable=false` control network için create, tam adla
list ve full-ID inspect çağrılarını yapabilir. Container create/start/exec,
volume API, network attach/delete, image delete ve prune yüzeyi yoktur. Var olan
bir Docker socket’i veya `DOCKER_HOST` kabul edilmez; manual GitHub workflow’u
yalnız kendisinin oluşturduğu geçici rootful Engine ve sahiplikli transient
systemd cgroup’u içinde çalışır. Ortak daemon açılışındaki `docker info` yolu
bu fixture için override edilmiştir: aktif systemd MainPID’nin cmdline değeri,
başlatılan `/usr/bin/dockerd` argv’sinin tamamı ve owned `--data-root` dahil
bayt düzeyinde eşleşir. Fixture’ın `docker()` yüzeyi her çağrıyı reddeder.

İlk mutation öncesinde literal `True` yetki kapısı ve güncel journal revision
kontrol edilir. Pull veya create yanıtı kaybolursa mevcut journal sözleşmesi
yalnız taze gözlemle uzlaştırır; mutation otomatik tekrarlanmaz. Hazır image ve
network makbuzları aynı journal kapatılıp yeniden açıldıktan sonra bütün Engine
bağımlılıkları hata verecek nesnelerle değiştirilerek yeniden okunur. Böylece
restart kanıtı yeni I/O veya gizli bir mutation’a dayanmaz.

Public makbuz sabit, tam alan kümesine sahiptir: kaynak commit’i ve allowlist
dosya SHA-256’ları, platform, katalog ve image config digest’i, iki hazır durum,
iki kaynak türü, bir journal restart, sıfır container işlemi ve
`installAvailable=false`. Dinamik network ID ve preparation ID yayımlanmaz;
network ID yalnız tek yönlü SHA-256 olarak kaydedilir. Verifier 32 KiB sınırı,
yinelenen JSON alanları, non-finite sayılar, alan/tür/değer değişiklikleri ve
değişmiş kaynak hash’lerinde kapalı hata verir.

## Yerel doğrulama

- Eksik modül/workflow başlangıcı: 17 beklenen RED.
- Yeni smoke, CI ve workflow güvenlik sözleşmesi: 44/44 PASS.
- Image, network, journal ve iki native workflow regresyon seçkisi: 674 test,
  yalnız mevcut platform skip’leriyle PASS.
- `tool/check_security_policy.py`, JSON parse, Python compileall,
  `tool/execution_queue.py validate` ve `git diff --check`: PASS.
- Tam Server + araç koleksiyonu 4.284 test içeriyor. Ortam verilmeden yalnız
  dört release-verifier testi zorunlu apksig değişkeninde setup hatası verdi;
  depodaki apksig 9.1.0 dosyası beklenen
  `562cd0a88890960d2ece48e116c61f12872222f1dcc306890799382bc019b201`
  SHA-256 ile doğrulandı ve Homebrew Java 17 ile aynı testler 4/4 PASS oldu.

S06.3d’nin Native18 koşusu managed volume UID/GID, NoCopy, başlangıç verisi,
container restart kalıcılığı ve taze sahiplik uzlaştırmasını amd64/arm64 için
zaten kanıtladı. S06.3f ancak bu commit’in bağımsız Server CI’ı, iki mimarili
native workflow’u ve indirilen iki receipt’in yeniden doğrulaması başarılı
olduktan sonra tamamlanabilir.

## İlk main tekrarında bulunan fixture kararlılığı

Exact `2a550dc` bağımsız Server koşusunda 4.064 test geçti ve aynı commit’in
native resource workflow’u iki mimaride de başarılı oldu. Main Server Container
ve Android reusable Server işleri ise aynı anda, aynı mevcut
`test_volume_preparation` `False-arm64` varyantında 4.063 PASS sonrası tek
`uncertain` sonucu verdi. Başarısız işler kabul kanıtı sayılmaz.

Hedef test 20 seri ve 64 paralel süreç tekrarında geçince ürün operasyonuna
retry eklenmedi. Sentetik AF_UNIX fixture’ının header’ı byte byte okuması
16 KiB sınırını koruyan bloklu okumaya çevrildi; ilk recv içinde gelen body
baytları ayrılıp aynı request’e taşındı, fazla body yine reddedildi. İlgili 307
test ve düzeltme sonrası 64 paralel hedef tekrar geçti. Bu değişiklik production
Engine taşımasını veya iki saniyelik idle sınırını değiştirmez.

İlk düzeltme sonrası aynı volume varyantı yüklü başka bir CI kopyasında tekrar
`uncertain` kaldı. Kök neden response idle süresi değil, sentetik peer'ın
`/version` sonrasında ikinci isteği iki saniyede kapatmasıydı: gerçek Client bu
arada aynı stream üzerinde durable source/revision/yetki kapısını çalıştırır ve
on saniyelik toplam exchange bütçesini kullanabilir. Fixture'ın genel yarım
istek yaşam döngüsü iki saniye olarak korundu; yalnız bu birleşik test peer'ı
toplam bütçeye uygun 11 saniye bekler. 2,1 saniyelik kapı testi eski davranışta
RED, yeni davranışta GREEN oldu. Volume paketi 450 PASS/2 mevcut skip ve hedef
32 paralel tekrar verdi; production taşıma ve limit değişmedi.

Sonraki exact koşulardan biri farklı bir fixture sınırını buldu: ağ hazırlığı
kilidi bırakıldıktan sonra taze kaynak uzlaştırması ve durable fsync, yüklü CI
dosya sisteminde üç saniyelik test join sınırını aştı. İşlem kilidi veya ürün
bütçesi değiştirilmedi; yalnız test teardown'u on saniyelik operasyon bütçesini
bekler. Aynı hedef 64 paralel tekrar, ağ/journal seçkisi 298 PASS/1 mevcut skip
verdi.

## Exact kabul

Kabul kaynağı `40213919254918040e506f3ba7fe8e850e84c1f8`:

- [Native resource koşusu](https://github.com/ersingundem/larenor/actions/runs/34304634133)
  amd64 ve arm64 üzerinde geçti. İki makbuz da 3.109 bayt ve 22 exact-source
  hash'i taşıyor. X64 artefact `10086202575`, receipt SHA-256
  `d1f1b302621127f502db4f38b4623327b063b5315d9dc3d439b4c82b6b7ff7a7`;
  ARM64 artefact `10086196001`, receipt SHA-256
  `2b2ad155d84af7c0baff58f33cfdf9d5dd06a23a5ac3329a5884ac990fbbbb43`.
  İndirilen iki makbuz repo verifier'ıyla yeniden doğrulandı.
- [Bağımsız Server](https://github.com/ersingundem/larenor/actions/runs/34304632484)
  4.065 PASS/2 uyarı verdi.
  [Server Container](https://github.com/ersingundem/larenor/actions/runs/34304624214)
  aynı testleri ve amd64/arm64 image smoke + immutable manifest yayınını geçti.
  [Security](https://github.com/ersingundem/larenor/actions/runs/34304624024)
  yeşil.
- [Android CI140](https://github.com/ersingundem/larenor/actions/runs/34304624138)
  5.438 Flutter testi, 4.065 Server testi ve API 35'te 17/17 E2E verdi.
  İmzalı APK140'ın paket, sertifika, `versionCode=100000140` ve
  `debuggable=false` kapıları geçti. APK 122.207.785 bayt ve SHA-256 değeri
  `d7ea842b2b92cd9a12491720f5b398e1bd809b607a0608ac362c33019dd57fa0`;
  `app-signed-release-apk-140` artefact kimliği `10086812461` ve süresi dolmamış.

S06.3f bu kaynakta kabul edildi. Makbuz hâlâ yalnız `resources_ready`, iki
kaynak, bir journal restart, sıfır container işlemi ve
`installAvailable=false` bildirir. Gerçek ev kurulumu, container create/start
yetkisi ve hizmet sağlığı S06.4 ve sonraki teslimlerin ayrı kapılarıdır.
