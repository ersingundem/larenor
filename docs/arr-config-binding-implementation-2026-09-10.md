# S06.5 — Sonarr/Radarr journal-bound yapılandırma bağı

Bu dilim, sahipli Sonarr/Radarr `config.xml` üretimini yalnız güncel ve journal
ile kanıtlanmış ilgili `/config` appdata kaynağına bağlar. Saf bağlayıcı dosya
sistemi, Docker, IPC veya ağ etkisi oluşturmaz; sonraki worker etkisinin bütün
kaynağı işlem öncesinde ve sonrasında yeniden kanıtlamasını sağlar.

## Yeniden türetilen yetki

Bağlayıcı çağırandan servis, volume, yol, port, stack veya policy seçimi almaz.
`VolumeCreateJournal` içindeki güncel intent üzerinden şunların tamamını yeniden
türetir ve exact eşleştirir:

- resource, operation, journal, ownership nonce ve revision kimlikleri;
- `managed_appdata` türü, yalnız `/config` hedefi, yazılabilir/no-copy volume ve
  `1000:1000` container kullanıcısı;
- ilgili installation/child-plan ve volume plan digest'leri;
- Sonarr için `8989` ile `larenor-sonarr`, Radarr için `7878` ile
  `larenor-radarr` stack ayarları;
- yalnız beklenen `dataRootId`, `libraryRootId`, `webPort` ve `instanceName`
  ayar kümesi;
- yeniden üretilen exact XML, `config.xml` göreli yolu ve SHA-256 özeti.

Sonuçtaki yapılandırma baytları ve API anahtarı `repr` içinde görünmez. Kaynak
revision'ı, receipt, stack, resource, volume, ayar, API anahtarı veya tek bir
binding alanı değişirse geri doğrulama başarısız olur. Yabancı ya da hazır
olmayan bir uygulama kaynağı sahiplenilmez.

## Kanıt ve açık iş

- Exact kaynak `25b7850f40c678ab4b4e5218d56cca26f1f41183`.
- **44 bağlayıcı testi**; helper ve owned-config paketleriyle **138 PASS**.
- Host/ağ etkisinin kapalı olduğu monkeypatch ile, public fonksiyonun caller
  kontrollü yol/servis/stack/policy alanı sunmadığı imza testiyle doğrulandı.
- `compileall`, güvenlik politikası, kuyruk, diff ve Gitleaks kontrolleri PASS.

Bu saf bağ henüz Docker helper'ını çalıştırmaz. Sıradaki dilim, aynı binding'i
etkiden önce ve sonra yeniden doğrulayan, private config'i yalnız bounded Engine
stdin üzerinden ileten ve sabit ağsız helper'ı create/start/stream/wait/remove
sırasıyla çalıştıran kapalı worker etkisidir. Native Sonarr/Radarr başlangıcı ve
authenticated API readback bunun ardından gelir. S06.5 ve
`installAvailable=false` açık kalır.
