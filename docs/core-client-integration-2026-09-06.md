# Core yönetimi ve Client sınırları — ikinci birleşim

Bu paket, son doğrulanmış `4bc79dc` / APK 99 üzerine hazırlanır. Önceki
teslimin testleri bu yeni kod için kullanılmaz. Root birleşim kaynağı
`8d9e4d2bdbbf55f685e35f5f5979b61303c2d67e`; sonraki E2E/kanıt değişiklikleri
ayrıca kaydedilir. Son E2E birleşimi `bb6ed4e8b4d52fa1ae43555d743515fd0c2a4429`.

| Dilim | Freeze | İlgili yerel doğrulama | İnceleme |
| --- | --- | --- | --- |
| Dashboard WebView kaynak sahipliği | `0a742a9` | 79 PASS | CLEAR |
| Keenetic kayıt, PIN ve kurtarma | `dc87062` | 181 odaklı / 1008 ilgili PASS | CLEAR |
| Keenetic Wi-Fi/cihaz/port ekranları | `74e3f44` | 202 odaklı / 1047 ilgili PASS | CLEAR |
| Core metadata mutasyon API | `8e00548` | 87 odaklı / 656 Client, 40 Server PASS | CLEAR |
| Gerçek PIN korumalı metadata UI | `036a356` | 431 ilgili PASS, 12 tablet ölçü/dil/tema kontrolü | CLEAR |
| Gerçek grant/revoke sözleşmesi + Client API | `a65691d` | 53 odaklı / 709 Client, 131 Server PASS | CLEAR |
| Sekizinci Android yönetim yolculuğu | `0d29755` | 43 account/member/admin fixture PASS; birleşimde tüm integration_support 48 PASS | İki bağımsız CLEAR |
| Saf volume sahiplik gözlemi | `4baa55a` | 95 odaklı / 282 Server PASS | CLEAR |

İlgili test kümeleri örtüşür; sayılar toplanmaz. Her dilimin aşağıdaki belgesi
gerçek RED/GREEN geçmişini, kapsam oranının paydasını ve açık koşulları tutar.

## Birleşim doğrulaması

İngilizce/Türkçe ARB dosyalarının bağımsız ekleri üç yönlü JSON anahtar
karşılaştırmasıyla birleştirildi; iki dalın değiştirdiği tüm anahtarların
değerleri korundu. Model ve l10n çıktıları gerçek araçlarla yeniden üretildi.
`8d9e4d2` üretim/test kaynağında tam Client **4.271 PASS / 4:48** verdi.
Tam Server **3.040 PASS / 10 Linux'a özgü skip / 8:17,88** verdi; iki mevcut
bağımlılık uyarısı var. Atlananlar gerçek Linux SO_PEERCRED, peer-pidfd,
procfs/mount/fd ve Unix stream davranış testleridir; yeni Linux CI'da
ayrıca çalışmaları gerekir. Tam analiz **0 bulgu / 11 saniye**, formatter
**878 dosya / 0 değişiklik**. **207 araç testi / 69,383 saniye** ve Android
backup/CI trust policy denetimi geçti. Ardından `bb6ed4e` ile sekizinci
Android kaynak yönetimi yolculuğu birleştirildi. Son fark üretim/Server/CI
kodunu değiştirmedi. Tüm integration_support **48 PASS / 4 saniye**; tam
analiz **0 bulgu / 2,9 saniye**, formatter **881 dosya / 0 değişiklik**.
Önceki yedi yolculuk ve 65 işareti aynen korunur; yeni toplam 8 uygulama
yolculuğu / 76 işarettir. Dört native testle yeni Android hedefi 12 testtir;
CI çalışmadan geçti sayılmaz. Önceki 4.271 tam yerel sonuç yeni fixture
testlerini içermez; sayılar yeni tam koşu gibi toplanmaz.

E2E8 birleşimi sonrası **37 Android hazırlık/diagnostics araç testi / 41,189
saniye** ayrıca geçti. 57 önceki commit için redakte secret taraması sıfır
bulgu verdi; son teslim aralığı yeniden kontrol edilecek. Kuyruk şeması geçerli; 125 iş ve 63 seçili
özellik sayısı korunur. Yeni kaynak için Linux CI/Android emülatör/bağımsız
imzalı APK kapıları henüz bu belgenin kabul kanıtı değildir.

## Kalan sınırlar

Keenetic'in mevcut işlem hattı gerçek router'a uygulanmadı; tüm firmware
API'leri veya fiziksel tablet kabulü iddiası yok. WebView düzeltmesi kişisel
genel web panelinin cookie politikasını değiştirmez. Core metadata yönetimi
registry kaydını düzenler; HA cihazı/container/disk silmez.

Grant API henüz ACL controller/ekranına bağlı değildir; bu sonraki bağımsız
iştir. Volume gözlemi kurulum veya volume oluşturma yetkisi değildir;
kalıcı journal, bootstrap ve gerçek Engine bağlantısı açık,
`installAvailable=false` kalır. Huawei/DeX/HomePod ve ev kurulumu ayrıca
kullanıcıyla fiziksel kabul gerektirir. S08.4/S08.6 ve 63 özellik sayacı bu
alt teslimler nedeniyle artırılmaz.

## Ayrıntılı kanıtlar

- [Dashboard WebView](direct-web-panel-boundary-implementation-2026-09-06.md)
- [Keenetic bağlantısı](keenetic-direct-boundary-implementation-2026-09-06.md)
- [Keenetic işlem ekranları](keenetic-operational-boundary-implementation-2026-09-06.md)
- [Core metadata API](core-home-resource-admin-api-implementation-2026-09-06.md)
- [Core yönetim ekranı](core-home-resource-admin-ui-implementation-2026-09-06.md)
- [Grant sözleşmesi](core-home-resource-grants-contract-2026-09-06.md)
- [Sekizinci Android yolculuğu](core-resource-admin-android-journey-2026-09-06.md)
- [S08.4 kabul incelemesi](client-boundary-acceptance-review-2026-09-06.md)
- [Volume gözlemi](managed-volume-observation-implementation-2026-09-06.md)
- [Önceki APK 99 teslimi](client-delivery-99-2026-09-06.md)
