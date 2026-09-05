# S06.3d — Salt okunur native kimlik gözlemi

2026-09-05 · İzole dal `codex/native-identity-observation`, başlangıç `8678982fa19352fafb104489665d704692aaebaf`. Üretim GREEN `474f6de`, son test checkpoint `b757118`. Aşağıdaki yerel checkpoint kanıtına ek olarak `3dde2f8` Linux CI geçti; bu S06.3d kurulum kabulü değildir.

## Uygulanan dar sözleşme

Yeni `server/larenor_server/plugins/linux_identity_observation.py` içindeki `capture_process_identity(proc_fd, *, pid, deadline, cancelled=None)` kendi proc FD kopyasını ve target/opener user namespace FD’lerini tutan `HeldProcessIdentity` döndürür. `snapshot` salt veri içerir: PID/starttime, proc ve namespace inode kimlikleri, okuyan process/native thread, dört UID ve GID, uid/gid map aralıkları. `.check(deadline)` aynı native thread’de kimlikleri yeniden okur; `.close()` tekrar çağrılabilir. Reentry yalnız sabit `identity_observation_busy`, diğer sıradan hatalar `identity_observation_unavailable` verir; kesinti temizliği ardından özgün kesinti korunur. Public repr’lerde yol, credential veya proc içeriği bulunmaz.

Map okuması başına en fazla 16 KiB, en fazla 340 aralık ve 4096 baytlık read parçaları vardır. Negatif/taşan/sıfır uzunluklu/çakışan/yarım kayıtlar reddedilir. UID/GID 4294967295 özel unmapped değeri normal kimlik veya kapsamlı aralık sonu olarak kabul edilmez. Aralık sırası mapping yetkisi sayılmaz. Her capture/check çağrısı caller deadline ile en fazla iki saniyelik ortak bütçeyi kullanır; read öncesi/sonrası iptal ve süre kontrol edilir. Takılan bir kernel filesystem syscall’ını zorla sonlandırma garantisi verilmez.

Opener namespace, uid_map/gid_map ikinci alanının anlamını etkiler. Bu yüzden target ve opener namespace FD’leri tutulur; map okumasından sonra namespace, starttime ve credential tekrarları yapılır, ayrıca sabit current native-thread proc yolu yeniden açılıp ilk kimliğiyle eşleştirilir. Kernel uid/gid map’leri namespace içinde bir defa yazılır; namespace kimliğini tutmak bu yorumu sabitler. [Linux user namespace ve map sözleşmesi](https://man7.org/linux/man-pages/man7/user_namespaces.7.html), [proc uid_map](https://man7.org/linux/man-pages/man5/proc_pid_uid_map.5.html)

## Kanıtın kaynağı ve açık kalan sınır

Standalone fonksiyonun girdisi **özel, caller-owned bir FD’dir**. Rastgele dizindeki `status`/`uid_map` dosyalarını okumak gerçek kernel process kimliği kanıtı değildir. Sentetik testler de böyle bir iddia taşımaz. Yeni veri modelinde supervisor, initial namespace, remap-disabled veya write-authority alanı yoktur.

Mevcut özel `_ContextLease.capture_identities(deadline, cancelled=None)` opsiyonu, yalnız hâlihazırda socket peer/pidfd üzerinden tutulan peer ve worker proc FD’lerini verir. `HeldContextIdentities` edinimde ve yeniden kontrolde parent context’i önce/sonra doğrular; parent caller-owned kalır. Eski üç `DaemonContext` boolean’ı ve Docker/API/IPC/DTO davranışları değişmedi. Eski gözlem çağrıları otomatik olarak yeni kimlik okumasını çağırmaz.

Bu birleşim aynı doğrulanmış peer incarnation’ına ilişkin gözlemdir; rootful, remap-disabled native supervisor başlangıcını kanıtlamaz. UID 0, tam identity map veya eşit namespace tek başına initial host namespace kanıtı değildir. `NS_GET_PARENT` EPERM de bu kanıtı vermez. [Namespace ioctl sınırı](https://man7.org/linux/man-pages/man2/NS_GET_PARENT.2const.html)

Proc/map okuması Linux 6.1 sözleşmesini kullanır. Optional daemon birleşimi mevcut `SO_PEERPIDFD` desteğini gerektirir; bu seçenek Linux 6.5’te eklendi. Destek veya erişim yoksa mevcut context yakalama unavailable kalır; PID numarasından `pidfd_open` fallback eklenmedi. Bütün CasaOS/Debian 12/Proxmox guest ortamları için hazır destek iddiası yoktur. [Linux SO_PEERPIDFD değişikliği](https://github.com/torvalds/linux/commit/7b26952a91cf65ff1cc867a2382a8964d8c0ee7d)

Native supervisor/host-root anchor, remap-disabled başlangıç kanıtı, katalog UID/GID→host eşlemesi, `AppdataIdMapping`, write lease, mkdir/chown/publish ve gerçek medya kaynak kabulü sonraki dilimlerdir. DockerProbe callback’i mutator yapılmadı; hiçbir Docker bağlantısı veya ev servisi kullanılmadı.

## Test ve checkpoint kanıtı

- Runtime RED `f77b46c` → minimal GREEN `a534fe6`; optional context RED `fa8648e` → GREEN `565195f`.
- Kesinti FD sızıntısı ve opener path replacement RED `972ab7a` → GREEN `b0b1b60`.
- Parent close sonrası IndexError RED `4870e5f` → statik hata GREEN `474f6de`.
- Son test checkpoint `b757118`: yeni dosyada 114 test, genişletilen daemon dosyasında 83 test. Yerelde toplam **194 PASS / 3 Linux skip**; yeni modül **%98 branch-inclusive coverage** (282 statement, 42 branch).
- Kimlik + daemon context + mount observer + appdata + Docker probe + host/stack preflight birleşimi: **577 PASS / 4 Linux skip**, 4,60 saniye. Bu sonuç tam Server suite sonucu değildir.
- Yeni gerçek Linux testleri kernel verisi mock etmeden native thread’in proc/ns/UID/GID/map kayıtlarını okur ve biten kendi thread’inin held proc FD’sinin reddini sınar. Mevcut gerçek socket testine optional pidfd→proc→map birleşimi eklendi; bu testte executable trust-policy seam sentetiktir, kernel socket/proc/ns/map verisi gerçektir. Bu üç test Mac’te atlandı; birleşik koşudaki dördüncü skip mevcut gerçek Linux mount testidir. Yeni Linux CI sonucu henüz alınmadı.
- Sentetik testler ayrıca UID/GID-only değişim, namespace değişimi, max map/byte sınırı, symlink/FIFO/dizin reddi, borrowed/closed/reused FD, snapshot alias mutation, yanlış thread/process, cancel/deadline, reentry, parent close/restart, son revalidation ve kesinti temizliğini doğrular.

İzole import doğrulandı: `/private/tmp/larenor-native-identity-observation/server/larenor_server/__init__.py`. Python 3.12 runtime: `/private/tmp/larenor-server-project-env/bin/python`, cwd izole `server`, `PYTHONPATH=.`. Kanıt logları yerel geçici dosyalardır: `/private/tmp/larenor-native-identity-final-coverage.log` ve `/private/tmp/larenor-native-identity-combined-final.log`; coverage dosyası diğer agentlardan ayrıdır.

## Linux CI doğrulaması — 3dde2f8

[Server CI](https://github.com/ersingundem/larenor/actions/runs/33988283387)
**2.704 testi atlamasız** geçti (325,184 saniye). Üç gerçek kernel kanıtı da
geçti: socket-pidfd→proc→kimlik birleşimi, native-thread UID/GID/map gözlemi ve
bitmiş thread'in tutulan proc FD'sinin reddi. amd64/arm64 Core restart,
medya hazırlığı/iptal smoke'u ve anonim sourceRevision yayını doğrulandı.
[207 araç testi ve güvenlik](https://github.com/ersingundem/larenor/actions/runs/33988283178)
başarılı. Gerçek medya kurulumu, supervisor/remap grant ve appdata yazma açık kalır.
