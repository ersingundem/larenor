# Seerr kalıcı konteyner kurulum işi

Tarih: 10 Eylül 2026
Kapsam: S06.5 içinde Seerr için Core tarafından denetlenen `create/start`
konteyner fazı

## Teslim edilen davranış

- Yönetici, aynı doğrulanmış medya hazırlığından `jellyfin` ve `seerr` için
  ayrı kalıcı kurulum işleri oluşturabilir.
- Servis seçimi `jellyfin` veya `seerr` kapalı kümesiyle sınırlıdır. Docker
  komutu, image, port, ağ veya host path HTTP isteğinden alınmaz.
- Core, seçilen bileşenin operation ve step kimliklerini şifreli medya
  planından yeniden türetir.
- Worker IPC, `installationId` değerini plan içindeki tek bileşenle eşleştirir;
  eşleşmeyen veya desteklenmeyen servis adımı etkiye ulaşmaz.
- Seerr binding'i worker'ın sabit politikasından üretilir ve mevcut
  `JournaledManagedContainerOperations` create/start makbuzlarını kullanır.
- Şema v1 kayıtları ve bunlara bağlı Jellyfin bootstrap satırları korunarak
  v2'ye taşınır. Foreign key yeniden `media_installations` tablosuna bağlanır.
  Eski kayıtlar varsayılan `jellyfin` seçimiyle okunur; aynı preparation için
  servis başına tek iş oluşturulabilir.
- Public sonuç yalnız iş, servis, faz ve sabit hata durumlarını taşır.
  `installAvailable=false` korunur.

## TDD ve doğrulama

- RED `fb3ecf3`: Seerr capability, aynı preparation üzerinde ikinci servis ve
  exact Seerr create/start beklentileri mevcut uygulamada kırmızıydı.
- GREEN `47e3d04`: model, Core koordinatörü, plan yürütücüsü, worker binding ve
  IPC doğrulaması Seerr'a genişletildi.
- `7b82201`: v1 satırlarının unique-constraint kaldırılan v2 şemasına kayıpsız
  taşındığını ve migration'ın idempotent olduğunu doğruladı. Sonraki migration
  koruması mevcut Jellyfin bootstrap satırlarıyla foreign key hedefini de yeniden
  doğruluyor.
- `8ee12c5`: sürümlü public sözleşme örneği iki servisi ilan ediyor.
- API, execution, IPC ve runtime paketinde 106 test; migration ve public
  contract paketinde 3 test geçti. Exact rebased kaynakta tam Server paketi
  5.248 testte geçti.

## Açık sınırlar

Bu dilim Seerr konteynerinin journal-bound start makbuzunu üretir. Core'un
AES-GCM şifreli Seerr bootstrap işi henüz bu installation kimliğini tamamlanmış
Jellyfin bootstrap kaydıyla birleştirmiyor. Sonarr/Radarr ve Jellyfin kütüphane
ayarlarının Seerr'a yazılması, `/settings/initialize` geri okuması ve gerçek
amd64/arm64 Seerr kabulü de açıktır.
