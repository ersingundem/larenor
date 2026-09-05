# S06.3d — Onaylı tam appdata kökünün salt okunur gözlemi

5 Eylül 2026. İzole çalışma: `codex/native-appdata-root-observation`, taban
`4ba70241264f400d1ad4248b3adcb8dc0f7e484f`. Bu belge yalnız aşağıdaki yeni
gözlem parçasını kaydeder; S06.3d veya kurulum yetkisinin tamamlandığını söylemez.

`plugins/native_appdata_root_observation.py` içindeki özel
`observe_appdata_root(HostPolicy, root_id, *, deadline, cancelled=None)`, yalnız
`data` amaçlı mevcut operatör kökünü açar. Gerçek `/` descriptor'ından başlayan
`O_NOFOLLOW | O_DIRECTORY` ve `dir_fd` yürüyüşü bütün parent descriptor'larını
tutar. Eksik kökte en yakın üst dizine dönmez. Foreign-writable ancestry için
sticky `/tmp` istisnası yoktur; dizin sahibi root veya gerçek worker UID'si olmalıdır.

`HeldAppdataRoot.check(deadline)` hem tutulan descriptor'ları hem taze tam yolu,
ardından her parent→name bağını yeniden açıp doğrular. Her gerçek
`observe_fd_mount` sonucu mount ID/kayıt, device/inode/UID/GID/mode, native thread
mount namespace ve process-root bağlarıyla eşleşir. Onaylı yol üzerindeki ayrı
disk/bind mount ancak exact geçiş yolu ve parent mount ID ile ölçülür. Readonly
ancestor ayrı writable diske ulaşabilir; seçilen readonly root ve herhangi bir
idmapped ancestor reddedilir. Root altı gezilmez; root altındaki mount'lara dair
kabul veya ret sonucu üretilmez.

`root_identity` ve `mount` özel gözlem verileridir. `borrowed_root(deadline)`
giriş/çıkış kontrolüyle tutulan FD'yi yalnız güvenilir süreç içi okuyucuya verir.
Directory FD, güvenlik açısından salt okunur sandbox değildir; caller bunu
kapatmamalı veya yazma yetkisi saymamalıdır. Bu modül AppdataRootLease,
AppdataIdMapping, supervisor çıpası, daemon/remap kanıtı, kaynak rezervasyonu,
API/IPC veya mutation dispatcher üretmez. Çağıranın tuttuğu policy yeniden
kontrol edilir; başka yerde değiştirilmiş global policy nesnesi keşfedilmez.

Yol UTF-8 olarak en fazla 4.096 byte, 128 bileşen ve bileşen başına 255 byte'tır.
Her işlem mevcut monotonic deadline'ı korur ve iki saniyeyle sınırlar. Cancel,
native thread/process değişimi, kapalı veya değişmiş descriptor, root/link/mount
değişimi gözlemi kapatır; yeniden giriş beklemez. Dış hata yalnız sabit
`root_observation_unavailable` veya `root_observation_busy` olur. Kernel içinde
takılan filesystem syscall'ını kesme ya da son kontrolden sonra ayrıcalıklı
aktörün değiştirmesini engelleme sözü verilmez.

TDD kaydı: `b44dd5e` beş davranış testi için eksik modül RED checkpoint'i;
`879700b` ilk GREEN üretimi. İlk GREEN aynı kaynak üzerinde 5 testle doğrulandı;
daha geniş regresyonlar üretim değişikliği gerektirmedi.

- Yeni dosya: **87 PASS, 1 Linux-only skip**.
- Yeni gözlem + mevcut appdata, mount, identity, daemon, host/stack gözlemleri:
  **573 PASS, 5 Linux-only skip**, 4,95 saniye.
- Yeni modül: **%99** dal dahil coverage (163 statement, 26 branch; bir
  interrupt-cleanup satırı ve bir kısmi dal ölçülmedi).
- İzole Python import yolu doğrulandı; Python 3.12 mevcut Server ortamı ve
  ayrı coverage dosyası kullanıldı. Log:
  `/private/tmp/larenor-root-observation-combined.log`; ölçüm:
  `/private/tmp/larenor-root-observation-final.coverage`.

Mac testleri gerçek özel temp dizinlerini ve descriptor-relative rename/ENOENT
yarışlarını kullanır; `/` ve mount gözlemi bu testlerde açıkça sentetiktir.
Yeni Linux testi checkout altında kendi geçici dizininde gerçek `/`, proc,
mountinfo/fdinfo ve descriptor'ları kullanır; kernel verisi taklit edilmez.
Bu Linux testi henüz bu yeni kaynak için CI'da çalıştırılmış sayılmaz. Gerçek
mount/namespace kurma, chown, Docker, ev servisi veya cihaz çağrısı yapılmadı.

Sonraki bağımlılık aynı kalır: native supervisor'ın host/root/user/mount ve
daemon incarnation/remap-disabled başlangıç kanıtı, sonra policy/plan/journal
bağlayan gerçek issuer, en son staging/marker/publish. Linux 6.1 mount gözlemi
ayrı SO_PEERPIDFD 6.5+ gereksinimini veya güvenli supervisor fallback'ini çözmez.

## Ana dal kontrolü

`32254ad2d96e5e388025e8081264eca7ad7ee716` bağımsız son kod/test incelemesi
açık P1/P2 olmadan tamamlandı; `0d9e2506ac86e00f2f6e1a0be513ee0cabb7b073`
ile ana dala birleştirildi. İlk tam Server başlatmasında dört APK imza testi
yerel `LARENOR_TEST_APKSIG_JAR` verilmediği için setup hatası aldı; doğru
sabit apksig 9.1.0 ve Java 17 ile dört test geçti. Aynı doğru ortamda tam
Server **2.782 geçti, 10 Linux testi Mac'te atlandı** (200,80 saniye).
Bu hazırlık hatası başarılı koşu sayılmaz. Tam başarılı çıktı
`/private/tmp/larenor-root-observation-full-server-green.log`; yeni Linux
fixture'ın uzak kabulü ayrıca beklenir.

Tam yerel Server kontrolünde Java 17'nin `java`/`javac` ikilisi PATH'te,
`LARENOR_TEST_APKSIG_JAR` ise SHA-256 değeri
`562cd0a88890960d2ece48e116c61f12872222f1dcc306890799382bc019b201`
olan resmi apksig 9.1.0 JAR'ına ayarlı olmalıdır. Bu dosya bağımlılık
önbelleğinde zaten bulunuyordu; test için indirici veya ev servisi çalıştırılmadı.

## Gerçek Linux kabulü — 394de0f

[Server CI](https://github.com/ersingundem/larenor/actions/runs/33991460310),
`394de0fc5e0f7e672dda8847c83b6e8d3b50e61b` üzerinde **2.792 PASS,
0 skip/failure/error** (327,402 saniye) verdi. Yeni
`test_linux_real_exact_root_uses_actual_proc_mount_and_named_descriptors`
0,204 saniyede geçti; kernel proc/mount/name/descriptor verisi bu vakada
sentetik değildir. Önceki socket/native-thread/exited-thread testleri de geçti.

İki mimarili Core medya **hazırlığı**, restart geçmişi ve iptal smoke'u
doğrulandı. Gerçek bileşen kurulumu ve yazma issuer kabulü değildir;
`installAvailable=false` kalır. Anonim kaynak/lisans kayıtları ve imaj index'i
doğrulandı: `sha256:1dcc66fcc964d6f5d1ab6a1d0df653f43d21c7562bb5f19bd098815f89461642`.
