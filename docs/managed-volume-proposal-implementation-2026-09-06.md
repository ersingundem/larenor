# S06.3d — Ayrı yönetilen volume önerisi

6 Eylül 2026. Kaynak `82c9433`, izole dal `codex/managed-volume-proposals`.
[Depolama değerlendirmesinin](managed-volume-storage-assessment-2026-09-06.md)
ilk adımındaki saf plan kısmı uygulandı. Response okuyucusu, volume journal'ı,
bootstrap, gerçek Engine kurulum etkisi ve Client kurulumu bu dilimde yoktur.

`plugins/volume_plan.py`, mevcut tam stack/catalog/policy doğrulamasını kullanıp
yedi managed appdata hedefi için ayrı `VolumeStoragePlan` üretir. Kaynaklar
önce ham alanlardan katı biçimde doğrulanır; `model_copy` ile gizlenen alanlar
ve Python bool/int eşdeğerliği kabul edilmez. Kayıt yeniden kullanılırken bütün
plan mevcut girdilerden yeniden türetilip karşılaştırılır; tek başına hash
veya sabit bir volume adı geçerlilik kanıtı sayılmaz.

Her hedef kendi adı ve işlem kimliğini yeni `larenor-volume-plan-v1` alanından
alır. Core, ev, hazırlık, kurulum veya hedef değişimi adları ayırır. Geçerli
ayar/policy değişiminde aynı hedefin adı kalabilir fakat istenen eşleme ve plan
hash'i güncellenir; eski plan reddedilir. Bu davranış mevcut volume'un otomatik
sahiplenilmesi veya eski verinin taşınması anlamına gelmez.

Öneri yalnız `local` driver/scope taşır; `DriverOpts` ve host path alanı yoktur.
`noCopy=true` gelecekteki container mount önerisidir, Docker volume-create
parametresi değildir. Katalogdaki servis kullanıcısı ayrı korunur ve her hedef
`requires_bootstrap_validation` olarak kalır. Bu alan yazılabilirlik kanıtı
değildir. `installAvailable=false` bütün model ve verify yollarında korunur.

Eski 13 kaynaklı `ResourcePreparationPlan`, native inode journal'ı, onaylı
library kökleri ve Music Assistant host-network planı değişmedi. Bu modül
dosya, Docker socket, HTTP, süreç veya kurulum işine bağlanmaz. Saf isim/plan
üretimi için yeni HTTP endpoint'i eklenmedi.

## Kanıt

- `e5cac37`: yeni arayüz stub'ına karşı **27 runtime RED**. Bu yeni özellik
  sözleşmesidir; daha önce çalışan üretim kodunda 27 hata bulunduğu iddiası
  değildir. İlk GREEN denemesinde isim uzunluk limiti bir karakter kısa
  kaldı; düzeltilerek `82c9433` üzerinde **27 PASS** elde edildi.
- Bağımsız kaynak incelemesi `82c9433`: **P1/P2 bulgu yok**. Önerilen geçerli
  settings değişimi regresyonu eklendi; ayrıca typed model sınırları doğrulandı.
- Son **32 yeni test**, mevcut kaynak/stack testleriyle **182 PASS / 2,33 s**.
  Aynı hedefler `linux/amd64` ve `linux/arm64` katalog girdileriyle sınandı.
  Gerçek iki mimarili Docker kurulumu yapılmadı.
- Coverage 7.10.6 ile yeni modül: **85/85 satır, 16/16 dal = %100**.
  Ölçüm bu saf modüle aittir; bütün Server veya kurulum kapsamı değildir.
- Test sırasında socket, süreç başlatma, `open`, `mkdir` ve `chown` çağrıları
  yasaklandığında plan üretimi ve doğrulaması geçer. Eski plan/stack verisi
  değişmez; library hedefleri volume'a çevrilmez.
- İlk ilişkili test komutu yanlış dosya adı nedeniyle test toplamadan durdu.
  Doğru `tests/test_media_stack_plan.py` seçimiyle yeniden çalıştırıldı; bu
  hazırlık hatası RED veya kabul kanıtı sayılmadı.

Özel yerel kanıtlar: `/private/tmp/larenor-volume-plan-{red,green,broad}.log`,
`/private/tmp/larenor-volume-plan.coverage`. Secret/host veri girdisi yoktur.
Bu dilim S06.3d tamamlanması değildir; CI ve sonraki storage effect kabulü
ayrı izlenir. Bir sonraki adım katı response doğrulayıcısı ve volume'a özel
journal tasarımıdır; kurulum kapısı henüz açılmaz.
