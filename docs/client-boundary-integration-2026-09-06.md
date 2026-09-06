# 6 Eylül — kayıt sınırları birleşik teslimi

Bu belge S08.4, B5.1 ve S06.3d'nin birbirinden bağımsız doğrulama dilimlerini
birleştirir. Bir dilimin testi tüm S08.4'ün kabulü değildir. Gerçek ev, router,
Proxmox, HomePod veya medya sunucusunda değişiklik yapılmadı.

| Dilim | Dondurulan kaynak | Yerel kanıt | İnceleme |
| --- | --- | --- | --- |
| Kişisel sağlık/fotoğraf ayarları | `4eac0f6` | 253 ilgili PASS | Bağımsız CLEAR |
| Jellyseerr/Bazarr/Prowlarr Direct sınırı | `37bd4c8` | 151 yeni / 241 ilgili PASS | Bağımsız CLEAR |
| qBittorrent Direct sınırı | `13d022a` | 121 odaklı / 531 ilgili PASS | Bağımsız CLEAR |
| Jellyfin Direct ve discovery sınırı | `142dc36` | 98 yeni / 297 ilgili PASS | Bağımsız CLEAR |
| Idle fixture hazırlığı | `1b2d7d3` | 23 PASS | Bağımsız CLEAR |
| Native tablet pencere odağı | `6c5fbb2` | 26 odaklı / 252 ilgili PASS | Bağımsız CLEAR |
| Saf yönetilen volume önerisi | `b5d4164` | 32 yeni / 182 ilgili PASS | Üretim kaynağı bağımsız CLEAR |

Tablodaki ilgili koşular örtüşür; toplanarak benzersiz toplam oluşturulmaz.
API-key bağlantılarının belirsiz kayıt sonucu için ek denetimi ve Proxmox
pilotu ayrı devam eder. Keenetic sınırı henüz kabul edilmedi.

## Birleşik test sırası

`a29257a` Dart dosyalarıyla ilk tam Client koşusu **3.665 PASS / 5 FAIL**,
3 dakika 59 saniye sürdü. Beş hata eski idle harness'in kişisel ayar
okumalarının tamamlanmasını beklememesinden kaynaklandı. `1b2d7d3` boş test
SharedPreferences deposunu kurar ve gerçek üç provider future'ını bekler;
gizlilik sonucu override edilmez, assertionlar gevşetilmez. Aynı hedefte
**23/23 PASS** elde edildi.

Ardından gerçek `ViewFocusEvent` negatif testleri aynı üretim açığını iki senaryoda gösterdi.
Native pencere düzeltmesi sonrası ilgili geniş koşu **252 PASS**, IdleGate
satır kapsamı **102/106**. Native ses sürer; eski root HA onayı yeni odakta
işlem gönderemez. Bu iki aşamanın bağımsız incelemesi temizdir.

Yeni tam Client koşusu, analiz, biçim kontrolü ve bu birleşimi içeren yeni
Android/Linux CI henüz ayrı kapılardır. Önceki **a2658ec / Android 98** için
3422 Flutter ve 11 E2E sonucu, bu tablodaki yeni kodun kanıtı sayılmaz.

## Ayrıntılı kayıtlar

- [Kişisel kayıtlar](personal-data-boundary-implementation-2026-09-06.md)
- [Üç API-key bağlantısı](direct-api-key-credentials-implementation-2026-09-06.md)
- [qBittorrent](direct-qbittorrent-boundary-implementation-2026-09-06.md)
- [Jellyfin](direct-jellyfin-boundary-implementation-2026-09-06.md)
- [Native odak](application-window-focus-implementation-2026-09-06.md)
- [Volume değerlendirmesi](managed-volume-storage-assessment-2026-09-06.md)
- [Saf volume planı](managed-volume-proposal-implementation-2026-09-06.md)

Volume modülü hiçbir Docker işlemi başlatmaz; HTTP kuruluma bağlı değildir.
`installAvailable=false` korunur. Native appdata yazma kabulü, volume
sahiplik/journal/bootstrap uygulaması ve fiziksel cihaz testleri açıktır.
