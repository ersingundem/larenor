# S06 dilim 2 — birleşik medya gereksinim kontrolü

5 Eylül 2026. Yazılım uygulandı; tam yerel ve GitHub doğrulaması sürüyor.
Güncel teslim kanıtı [PROGRESS.md](PROGRESS.md) üzerinden izlenir.

## Kullanıcının göreceği değişiklik

Larenor Client'ta Server → birleşik medya hazırlığı üzerinden güncel hazırlığın
**gereksinimlerini kontrol et** akışı açılır. Kontrol açıkça başlatılır; sonucu,
kalıcı geçmişi ve iptali aynı tablet düzeninde gösterilir. İşçinin yapılandırılmış
olması ulaşılabilir olduğunu veya bütün kontrollerin geçeceğini söylemez.
Belirsiz POST cevabı aynı istek kimliğiyle kurtarılır; otomatik yeni iş yaratılmaz.
PIN, hesap/rota değişimi ve arka plan sınırları geç kalmış cevapları geçersiz kılar.

Yeni `/api/v1/admin/media/inspections` yönetici API'si oluşturma, en fazla on
kayıtlık sayfalama, kayıt detayı, revision ile iptal ve `/capabilities` sağlar.
Swagger/OpenAPI sözleşmesine dahildir. Tek hazırlık için bir etkin kontrol,
toplam 16 etkin iş ve 256 kalıcı kayıt sınırı vardır. Geçmiş otomatik silinmez;
limit dolunca yeni kayıt açık hata verir. Saklama/arşivleme daha sonraki teslimdir.

Kontrol kaydı AES-GCM ile şifrelenir ve işlem metadata'sına bağlanır. Sunucu
restart'ında sıradaki işlem ve bitmiş sonuç korunur. Salt okunur ölçüm sırasında
veritabanı kilitli kalmaz; çağrı öncesi ve sonrası özgün yönetici/oturum,
hazırlık revision/hash, katalog ve Core/ev kimliği yeniden doğrulanır. İptal
veya değişen yetki eski sonucu kabul ettirmez. Başka yönetici geçmişi görebilir
ve iptal edebilir; önceki aktörün yürütme yetkisini devralmış sayılmaz.

## Her sonuç neyi kanıtlar?

| Kontrol | Anlamı ve sınırı |
| --- | --- |
| `platform` | İşçinin Linux mimarisi seçili planla eşleşiyor |
| `storage_root` / `storage_capacity` | Yalnız işçinin gördüğü, politika ile onaylı dosya sistemi; daemon bağlamından ayrı yerel gözlem |
| `docker_engine` | Açık politikadaki Unix endpoint üzerinde tek salt okunur GET `/version` ile API/platform uyumluluğu |
| `daemon_mount_context` | İşçi ve doğrulanmış socket peer'inin mount namespace kimliği karşılaştırması |
| `daemon_network_context` | İşçi ve doğrulanmış socket peer'inin network namespace kimliği karşılaştırması |
| `daemon_root_context` | Process root inode/aygıt ve mount kimliği karşılaştırması |
| `port_availability` / `receiver_network` | Bağımsız kanıt henüz yok: `unknown` |

Aynı dosya sistemini paylaşan altı bileşenin önerilen bütçesi **49.152 MiB**
olarak birlikte hesaplanır; altı ayrı 8 GiB geçişi yeterli sayılmaz. Her bileşenin
bütçesi her ayrı yazılabilir dosya sistemine bir kez eklenir. Kök alias'ları ve
config/cache dizinleri boş alanı çoğaltmaz; salt okunur Jellyfin kütüphanesi ve
Music Assistant müzik görünümü ek yazma bütçesi getirmez. Dizinler ölçümden
önce ve sonra güvenli descriptor yürüyüşüyle doğrulanır; aynı yoldaki dizin
başkasıyla değiştirilmişse önceki kapasite o yola atanmaz. Bunlar katalog
bütçeleridir, upstream uygulamalarının ölçülmüş asgari ihtiyaçları değildir.

Daemon kanıtı özel **v3 işçi politikası** ile seçilmiş canonical
`docker.daemonExecutable` yolunu gerektirir; v1/v2 politikalarının yetkisi
sessizce artırılmaz. Root'a ait, başkalarınca yazılamayan executable'ın kimliği
socket peer'iyle karşılaştırılır. Linux 6.8'in socket'e bağlı `SO_PEERPIDFD`
tanıtıcısı, tutulmuş proc/namespace/root descriptor'ları ve süreç başlangıcı
ölçüm öncesi/sonrası kontrol edilir. İşçinin ölçüm yapan thread'i esas alınır.
Sadece süreç adı, PID sayısı veya socket yolunun metni kimlik kanıtı sayılmaz.

Kernel desteği, proc erişimi veya güvenilir executable kanıtı yoksa; peer proxy
ise ya da kimlik ölçüm sırasında değişirse bağlam sonucu `unknown` kalır.
API kontrolü bu durumda yine geçebilir. Kimliği doğrulanmış iki farklı bağlam
`failed` olarak ayrılır. Ham PID, executable/host yolu ve OS hata metni
Client'a veya loglara çıkmaz. Ayrı mount namespace'lerinin güvenli bir bind
mapping ile eşleşmesi bu dilimde desteklenmez; ileride ayrıca kanıtlanmalıdır.

Tek IPC çağrısının beş saniyelik bütçesi alt gözlemlerde yeniden başlamaz;
Docker alt kontrolü ayrıca iki saniyeyle sınırlıdır. Bloke olmuş kernel dosya
sistemi çağrısı Python içinde zorla kesilmez: geç cevap kabul edilmez, işçi
çağrı bitene kadar kendi kilidini bırakmaz. Bu gözlem bir disk/port rezervasyonu
veya kalıcı host uygunluk sertifikası değildir; kurulum her yan etkide yeniden
kanıt ve yetki isteyecektir.

## Doğrulama yolu

- [Server HTTP → Unix işçisi → restart sözleşmesi](../server/tests/test_media_inspections_contract.py)
  gerçek API ve şifreli kayıttan [ortak JSON örneğini](../contracts/media-inspections.v1.json)
  üretir; Android sözleşme testleri aynı örneği tüketir. Disk miktarı sentetiktir;
  ev Docker/medya servislerine bağlanılmaz.
- [Kalıcı iş testleri](../server/tests/test_media_inspections.py) yetki/iptal/katalog
  yarışlarını, şifreli metadata bozulmasını, limitleri ve migration'ı denetler.
  [API testleri](../server/tests/test_media_inspections_api.py) yönetici sınırını
  ve gerçek uygulama yaşam döngüsünü kapsar.
- [Host testleri](../server/tests/test_media_host_preflight.py),
  [daemon kimliği](../server/tests/test_daemon_context.py),
  [socket gözlemi](../server/tests/test_docker_observation.py) ve
  [birleşik IPC](../server/tests/test_media_preflight_ipc.py) ayrı kanıtları sınar.
  Linux proc/socket kontrolü macOS'ta gerçek Linux kanıtı sayılmaz.
- [Android testleri](../test/features/server/server_media_inspections_test.dart) ve
  [tablet ekran testleri](../test/features/server/server_media_inspections_screen_test.dart)
  aynı kimlikle kurtarma, bağlam, yaşam döngüsü, sayfalama ve EN/TR büyük yazıyı kapsar.
- İki mimarili [imaj CI kontrolü](../tool/server_media_smoke.py) paketlenmiş API'nin
  anonim erişimi reddettiğini ve işçi yapılandırılmadığında kontrol/kurulum
  yeteneğini kapalı tuttuğunu restart öncesi ve sonrası doğrular. Bu test gerçek
  medya motorlarını kurup oynatma kanıtı değildir.

**`succeeded` incelemenin tamamlandığını söyler; içindeki kontroller başarısız
veya bilinmiyor olabilir. `installAvailable=false` korunur.** İmaj indirme,
dizin oluşturma, ağ ayırma, container başlatma, medya bootstrap, HomePod keşfi
ve gerçek oynatma bu dilime dahil değildir. Sonraki teslim
[sahiplikli kaynak hazırlığıdır](remaining-core-integration-slices.md).

Teknik kaynaklar: [Linux procfs](https://docs.kernel.org/filesystems/proc.html),
[namespace tanıtıcıları](https://man7.org/linux/man-pages/man7/namespaces.7.html),
[process root](https://man7.org/linux/man-pages/man5/proc_pid_root.5.html),
[thread bağlamı](https://man7.org/linux/man-pages/man5/proc_pid_task.5.html),
[fdinfo mount kimliği](https://man7.org/linux/man-pages/man5/proc_pid_fdinfo.5.html),
[Linux 6.8 socket uygulaması](https://github.com/torvalds/linux/blob/v6.8/net/core/sock.c),
[descriptor ile kapasite ölçümü](https://docs.python.org/3/library/os.html#os.fstatvfs).
