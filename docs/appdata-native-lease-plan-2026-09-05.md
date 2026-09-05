# S06.3d — Native appdata lease için sonraki dar karar

2026-09-05 · İncelenen kod: `1ef08fb` · Tasarım/kanıt araştırması; repo değişikliği, host/Docker işlemi veya yeni kabul iddiası yok.

**5 Eylül uygulama güncellemesi:** Aşağıdaki ilk araştırma daha sonra iki
salt okunur parçaya uygulandı. `linux_mount_observation.py` gerçek Linux CI
ile doğrulandı. `linux_identity_observation.py` ve özel ContextLease birleşimi
`33cf1d9` → main `81caaf2` içinde; `3dde2f8` Linux CI'sı 2.704 testi
atlamasız geçti. Gerçek socket/pidfd/kimlik ve thread yaşam döngüsü doğrulandı.
Yerel tam Server 2.695 geçti, dokuz Linux testi Mac'te atlandı.
[Kimlik gözleminin kanıtı ve sınırları](native-identity-observation-implementation-2026-09-05.md).
Bu iki modül `NativeAppdataLeaseIssuer` veya yazma yetkisi değildir.

**Kalan sıra:** (1) Onaylı tam köke `/` descriptor'ından ulaşan, tüm
parent→name→child bağlarını ve gerçek mount gözlemini tutan resolver;
eksik kökte en yakın parent'a düşmemeli. (2) Operatörün hostta kurduğu native
supervisor'ın tuttuğu kök/user/mount bağları ve aynı daemon incarnation'ına
ait remap-disabled başlangıç kanıtı. (3) Bu kanıtları, plan/journal/host-policy
eşlemesini ve UID/GID mapping'i birleştiren özel issuer. (4) Ancak sonra
durable journal öncesi/sonrası yenilenerek staging/marker/publish işlemi.
Birbirine eşit namespace veya UID 0 bu adımları atlatan bir başarı alanına
çevrilmeyecek. Gerçek ev kurulumu son manuel aşamada kalır.

**Karar:** Önce gerçek kanıt üreticisini salt okunur uygula; mevcut `AppdataRootLease` test callback’lerini üretim yetkisi sayma. Sonraki mkdir/publish ayrı dilimdir. Hedef, hostta çalışan özel native worker ve ayrı, UID 10001 API container’dır. API’ye Docker socket, host yolları veya lease FD’leri verilmez. `DockerProbe.during` kesinlikle mutator olmaz: mevcut gözlem callback’i başarısız/eksik daemon kanıtında da çağrılabilir ve son kontrolü callback’ten sonradır.

**Dar API:** `NativeAppdataLeaseIssuer(host_policy, policy_binding, native_anchor).acquire(binding, intent, *, deadline) -> ContextManager[AppdataRootLease]`. Başarısızlık yalnız sabit `context_unavailable`, `mapping_unavailable`, `root_conflict`, `lease_expired`; hiçbir yol/raw `/info`/config çıktısı dışarı çıkmaz. `native_anchor`, native supervisor’ın tuttuğu host root/user/mount namespace FD’leri ile aynı daemon incarnation’ına bağlı pidfd/start-time/executable ve remap-disabled başlangıç kanıtıdır; JSON boolean veya Client girdisi değildir. Bu gerçek üretici henüz yoktur: sıradan policy digest’i böyle bir kanıtın yerine geçmez. Kaynak plan, journal intent/nonce/spec ve opaque policy kimliği edinimde yeniden türetilir; policy kimliği yüklenmiş gerçek host ayarlarına ayrıca bağlanır.

**Tutulan bağlar:** Socket ancestor/inode kimliği → aynı Unix peer/pidfd → daemon ve iş yapan native thread’in proc FD’leri → `exe`, `root`, `ns/mnt`, `ns/user` FD’leri. Worker/daemon/host çıpasının user ve mount namespace’leri ile process-root kimliği eşleşir; dört UID **ve GID**, bounded uid_map/gid_map ve başlangıç kimliği kontrol edilir. `NS_GET_PARENT` için EPERM, ilk user namespace’i kanıtlamaz. [Linux namespace ioctl sözleşmesi](https://man7.org/linux/man-pages/man2/NS_GET_PARENT.2const.html)

Root yolu native worker’da `/` FD’sinden descriptor-relative açılır; **bütün parent FD’leri ve parent→name→child bağları** tutulur. Root amacı `data`, root sahibi worker/root, foreign-writable olmayan ancestry gerekir; ilk yazma kapsamı sticky-temp istisnasını kullanmaz. Root öncesi ayrı onaylı disk mount’u mümkündür; root altındaki bind mount dahil mount geçişi reddedilir. Mevcut `HostInspector._managed_descriptor` ENOENT’te en yakın parent’ı döndürdüğünden yazma resolver’ı olarak kullanılamaz.

**UID/GID ve kernel yolları:** Yalnız kanıtlı rootful, remap-disabled çalıştırmada katalog `0:0` ve `1000:1000` identity mapping kabul edilir. Aynı doğrulanmış peer üzerinde sabit `/version` + `/v1.47/info`, sınırlı JSON ve toplam deadline kullanılır; rootless/userns görülürse reddedilir. Bayrağın yokluğu tek başına yeterli değildir: Moby `userns` bayrağını yalnız `RootPair()` üzerinden üretir, bütün ID aralıklarını vermez. Native başlangıç kanıtı yoksa sonuç `mapping_unavailable` kalır. [Moby kaynak kodu](https://github.com/moby/moby/blob/v27.5.1/daemon/info.go#L166-L193), [resmî API alanı](https://github.com/moby/moby/blob/v27.5.1/api/swagger.yaml#L5519-L5535)

- **Linux 6.1 için mount kanıtı:** Tutulan FD’nin fdinfo `mnt_id` değeri aynı thread’in taze, tam ve bounded mountinfo kaydıyla eşleşir; aynı namespace/root altında before/after tekrar ölçülür. Eksik/çift kayıt, bozuk escape, truncate, readonly veya `idmapped` reddedilir. Kernel 6.1 `show_mnt_opts` gerçekten `idmapped` üretir; yalnız `st_dev` veya yol eşitliği kullanılmaz. [Linux 6.1 kaynak kodu](https://github.com/torvalds/linux/blob/v6.1/fs/proc_namespace.c#L64-L85)
- **İsteğe bağlı 6.8+ yolu:** `statx(AT_EMPTY_PATH, STATX_MNT_ID_UNIQUE)` → `statmount(STATMOUNT_MNT_BASIC)`; dönen maskeler zorunlu, `MOUNT_ATTR_IDMAP` reddedilir. Eski fdinfo ID’si statmount’a verilmez; 7.0’daki BY_FD’ye bağımlılık kurulmaz. [statx](https://man7.org/linux/man-pages/man2/statx.2.html), [Linux 6.8 IDMAP uygulaması](https://github.com/torvalds/linux/blob/v6.8/fs/namespace.c#L4489-L4529)

**6.1 sınırı ayrı:** Mevcut daemon capture `SO_PEERPIDFD` nedeniyle 6.5+ ister. 6.1 mount kanıtı bunu çözmez. Supervisor’ın aynı socket peer incarnation’ına bağladığı pidfd yolu ayrıca gerçek Linux testiyle doğrulanmadan fallback yok; sırf PID numarasına dayalı yeniden `pidfd_open` eklenmez. Bu, bütün CasaOS/Debian 12/Proxmox guest ortamları için hazır destek iddiası değildir.

**Yazma öncesi yenileme:** Journal process lock eldeyken authority/cancel ve kaynak bağları → deadline → socket/peer/start/executable/user-map/namespace/root → her parent linki/mount/UID/GID → hedefin hâlâ beklenen durumdaki kimliği kontrol edilir. İlk etki öncesi durable `begin`; her sonraki syscall öncesi yeni kontrol, ardından post-check. Değişiklik/timeout sonrası otomatik tekrar yok, `uncertain` ve yalnız okuma uzlaştırması. Lease kaynak rezervasyonu veya root yetkili dış değişikliklere karşı kernel kilidi değildir. Bounded proc/HTTP okuması ve deadline dolunca yetki vermeme sağlanır; takılan filesystem syscall’ının kesin süre sınırı ayrı süreç izolasyonu olmadan vaat edilmez.

**Sonraki dosyalar ve RED hedefleri:** Yeni `plugins/linux_mount_observation.py`, `plugins/appdata_lease.py` ve karşılık gelen iki test dosyası; `daemon_context.py` içinde yalnız özel user/GID snapshot ve yaşam döngüsü genişletmesi. API/DTO/journal formatı/DockerProbe değişmez.

1. Linux 6.1 mountinfo: normal mount olumlu; idmapped, aynı st_dev farklı mount, duplicate/truncated kayıt ve eksik kanıt lease üretmez. 6.8 maskesi/ID türü karışıklığı da reddedilir.
2. UID 0 görünümlü rootless, userns-remap, yalnız GID kayması, boş/yanlış map ve `/info` bayrağı yokken eksik native başlangıç kanıtı reddedilir.
3. Açık root sabitken parent rename/replacement, mount örtme ve ardından ENOENT; hem edinim hem yenileme durur, hiçbir effect çağrılmaz.
4. Peer proxy, daemon restart/PID reuse, executable replacement, native thread namespace/root değişimi ve host çıpası uyuşmazlığında lease kapanır; bütün FD’ler bırakılır.
5. Deadline/cancel/policy değişimi durable begin çevresinde: effect öncesi engelleme, effect sonrası belirsizliğin korunması, fork/thread/closed lease’in kullanılamaması ve static error sınırı.

Mac’te gerçek temp-directory yarışları ve sentetik Unix/proc sağlayıcıları; Linux CI’da gerçek kernel FD/ns/pidfd/mountinfo okumaları. İzole throwaway VM’nin özel test mount namespace’i, idmapped/bind mount kabulü için sonraki fiziksel kernel fixture’ıdır; bu araştırmada çalıştırılmadı. İlk increment yalnız lease kanıtıdır, S06.3d’nin tamamlanması değildir.
