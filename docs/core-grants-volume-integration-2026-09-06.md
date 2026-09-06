# Core erişim yönetimi ve kalıcı volume gözlemi — üçüncü birleşim

Bu paket `1c2db575e7377e28e41bbd83aa34d4408e2029c1` / Android 100 üzerine
hazırlanır. Android 100 bu iki dilimi içermez; kendi CI kabulü ayrıca sürer.
Birleşik üretim/test kaynağı `5e82c0e01df751515a96e1789e2e1d12570f01a7`;
`eeb0b30` yalnız mevcut CI takibi belgelerini birleştirir.

| Dilim | Kaynak | Yerel kanıt | İnceleme |
| --- | --- | --- | --- |
| Core kaynak erişim ekranı/controller | `ab678df` (üretim `9492bdb`, son test `c63c16b`) | 52 odaklı / 371 ilgili Client, 2 actual Server fixture PASS | Root ve bağımsız karşı inceleme CLEAR |
| Volume gözlem journal'ı | `f9a3faa` (üretim `bd696ae`, son test `e274790`) | 54 odaklı / 273 ilgili Server PASS | Root bağımsız kaynak incelemesi CLEAR |

İlgili kümeler örtüşür; sayılar toplanmaz. ACL controller 158/160, ekran
277/280 satırda ölçüldü. Volume modülü 139/139 statement ve 8/8 branch
kapsamına sahiptir; bunlar proje kapsam oranı değildir.

## Birleşim kontrolleri

- ARB ekleri çakışmadan birleşti; l10n gerçek araçla üretildi.
- Birleşimde beş grants test dosyasının **52 testi / 6 saniye geçti**.
- `eeb0b30` birleşik kaynakta tam Client **4.353 PASS / 5:29** verdi.
  Tam Server **3.094 PASS / 10 Linux skip / 8:49,37** verdi; iki mevcut
  deprecation uyarısı var. Atlananlar Linux peer/procfs/mount/FD testleridir;
  bu kaynağın yeni Linux CI koşusu ayrıca gerekir.
- Tam analiz **0 bulgu / 4,4 saniye**; formatter **888 dosya / 0 değişiklik**.
- Ayrı ACL Android kullanıcı yolculuğu geliştiriliyor; mevcut metadata
  yolculuğu erişim değiştirme kabulü olarak sayılmaz.
- Root gerçek TR 600 ve 1280px / 2× form PNG'lerini, confirmation generation
  ve monotonic ACL düzeltmelerini son kaynaktan ayrıca inceledi.

## Sağlanan davranış ve açık koşullar

Gerçek PIN korumalı metadata ekranından kayıt erişimi açılır; mevcut Core
hesabı seçilir, okuma/okuma-yazma izni atanır veya ayrı onayla kaldırılır.
İzin hesabın rolünü değiştirmez. Eski Save callback'i kaldırma onayını atlayamaz;
başarısız okuma, daha eski ACL revision'ını kullanılabilir hâle getiremez.
Belirsiz yazım açık GET yenilemesi ister; PUT otomatik tekrarlanmaz.

Volume journal gözlem geçmişini kalıcı, ayrı SQLite domain'inde tutar.
`labels_observed` bir anda eşleşen etiketleri belirtir; volume oluşturma,
sürekli sahiplik, UID yazılabilirliği veya kurulum izni değildir. Native inode
journal'ı ile karışmaz; Engine/bootstrap kurulum bağlantısı açık ve
`installAvailable=false` kalır. Gerçek ev cihazında işlem yapılmadı.

Bu paket için yeni tam CI, Android E2E, bağımsız imzalı APK ve fiziksel kabul
henüz yok. S08.6/S06.3d sayaçları bu alt dilimler nedeniyle kapatılmaz.

- [Kaynak erişim ekranı kanıtı](core-home-resource-grants-ui-implementation-2026-09-06.md)
- [Volume journal kanıtı](managed-volume-journal-implementation-2026-09-06.md)
- [Önceki birleşim](core-client-integration-2026-09-06.md)
