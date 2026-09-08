# Services ve Core hesap IME birleşimi

8 Eylül 2026. Kaynak `cd961acb1586680f24ec00eead8f4d972520df4c`; tree `c36173194d8d987f9d31b27f0e1fc2b6a93a1bc9`.

[Services erişilebilirliği](core-services-tablet-accessibility-2026-09-06.md)
ve [hesap formları IME düzeltmesi](core-account-ime-navigation-2026-09-08.md)
ayrı kaynak incelemelerinden sonra nonsquash merge ile birleştirildi.
Çalışma kodu/test/lockfile/CI ağaçları aşağıdaki doğrulama boyunca değişmedi.
Bu paket [APK108](client-delivery-108-2026-09-06.md) sonrasındadır.

| Kontrol | Gözlenen sonuç |
| --- | --- |
| Tam Client, coverage açık, test başına 90 saniye | **5.218 PASS / 2 timeout**, exit 1; başarılı tam koşu değildir |
| Yalnız iki başarısız test, aynı kaynak ve 90 saniye | **2 PASS**, exit 0 |
| Tam analiz | **0 sorun** |
| Biçim kontrolü | **973 dosya, 0 değişiklik** |
| Paket/üretim hazırlığı | Offline kilitli pub get ve codegen geçti; worktree temiz |

Başarısız testler `synthetic_core_resource_admin_test.dart` içindeki kayıp
yanıt ve `core_layout_archive_codec_test.dart` içindeki exact 3 MiB sınırıdır.
İlki fixture'ın 3 saniyelik yanıt bekleme süresini, ikincisi dosya boyutu
sınırını sınar. Mac'in test sırasında 800, 875, 572 ve 472 saniyelik bakım
uykuları sistem kaydında görüldü. Test raporunun 80:22 süresi ile süreç
koordinatörünün 611,59 saniyelik monotonic ölçümü bu yüzden ayrı tutulur;
bunlardan ürün performansı sonucu çıkarılmaz.

Sadece bu iki test kaynak değiştirilmeden tekrar çalıştırıldı: 2 PASS,
6,52 saniye monotonic ölçüm. Test süresi artırılmadı, assertion kaldırılmadı,
ürün veya test kaynağı değiştirilmedi. Analiz de başarılı; rapordaki 579
saniye ile koordinatörün 10,52 saniyesi farklı saat/uyku ölçümleridir.
Geçici idle-sleep önleme yalnız doğrulama sürecinin ömrüne bağlandı ve
kapatıldı; sistemin kalıcı güç ayarları değiştirilmedi.

Bu sonuç **5.220 test tek temiz tam koşuda geçti** biçiminde sunulmaz.
Sonraki aynı kaynaklı GitHub tam Client/E2E ve bağımsız APK kapısı açıktır.
Services'ın 46 ve IME'nin 24 yeni testi, tam koşudaki 5.218 başarılı teste
dahildir; ayrı test sayısı olarak eklenmez. Fiziksel tablet/IME kabulü açık.

Özel log ve makbuzlar:

- `/private/tmp/larenor-services-ime-client-execution.json`: ilk tam koşu;
  `/private/tmp/larenor-services-ime-client-full-client.log`, SHA-256
  `23d574127068d1caafaf1ea69be2a486b48d6d75074c5225a228de30aea910df`.
- `/private/tmp/larenor-services-ime-recovery-execution.json`: iki test,
  tam analiz ve biçim kontrolü; bütün süreçler reap edildi.
- `/private/tmp/larenor-services-ime-integration-evidence.json`: kaynak
  nesneleri, log özetleri ve ayrı sonuçlar; SHA-256 `1ec59b567eed183136fefafd2b369b3e5889fcebb95fc018901fb4e4ddc5b826`.

Önceki test/yayın makbuzları korunur. Gerçek ev veya HA işlemi yapılmadı.
