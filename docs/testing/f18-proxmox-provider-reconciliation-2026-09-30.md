# F18 Proxmox sağlayıcısı ve belirsiz sonuç uzlaştırması

Tarih: 2026-09-30. Bu dilim F18'i tamamlandı olarak işaretlemez.

Normal Core composition artık doğrulanmış Proxmox worker'ını, resource binding
ve egress politikası oluşturulduktan sonra PowerRecoveryService'e bağlıyor.
Servis başlangıcındaki belirsiz işlem incelemesi de aynı gerçek sağlayıcıyı
kullanıyor. Worker yoksa sağlayıcı hazır gösterilmiyor.

Politika hedefi; admin revision, Core/home/resource/ACL, binding, service ve
egress revisionlarına bağlı bir providerRef taşıyor. Her işlem öncesinde bu
yetki yeniden kontrol ediliyor. Worker yalnız sealed node/kind/guest kimliği
için sabit `/api2/json/nodes/{node}/{kind}/{guest}/status/current` GET'ini
yapıyor. Başlatma/kapanış mevcut bounded worker yolunu kullanıyor. Proxmox'un
gerçek API dayanağı: [LXC durum ve güç işlemleri](https://github.com/proxmox/pve-container/blob/master/src/PVE/API2/LXC/Status.pm)
ve [QEMU API uygulaması](https://github.com/proxmox/qemu-server/blob/master/src/PVE/API2/Qemu.pm).
Durum okuması VM.Audit, güç işlemleri VM.PowerMgmt yetkisi gerektiriyor.

Kaybolan komut cevabı, daha sonra hedefin istenen durumda görülmesiyle geçmiş
komut başarısına çevrilmiyor. Yeniden başlatmada dış etki tekrar gönderilmiyor.
Admin'in açık `/runs/{run}/steps/{step}/reconcile` isteği yalnız güncel durumu
okuyor; revision değişmişse veya durum eşleşmiyorsa işlem belirsiz kalıyor.
Eşleşen durum `reconciled_current_state` olarak kaydediliyor. Flutter geçmişi
bunu ayrı bir uzlaştırma etiketiyle gösteriyor; zamanında tamamlanan komut
makbuzu olarak sunmuyor. Şema v1/v2 kayıtlarını v3'e taşıyor.

Doğrulama: Proxmox sağlayıcısı, observation, restart, worker IPC/runtime ve Core
runtime paketlerinde 61 Python testi geçti. Flutter providerRef ve yeni sonuç
alanının roundtrip/strict parser kontrolleri ayrıca çalıştırıldı.

Flutter admin ekranı belirsiz hedef adımı için açık güncel durum denetimi sunar.
İstek exact run/step ve expectedUpdatedAt revisionı taşır; retry/execute çağırmaz.
Durum uyuşmazlığı eski belirsiz adımı korur, başarıdan sonra durum yeniden okunur.
GET ve komut tek kalan deadline bütçesini paylaşır; geç gelen uzlaştırma kanıtı
kabul edilmez. Yeni ekran ve model kontrollerinde 4 Flutter testi geçti; ilgili
Flutter analyze temiz. Genişletilmiş güç paketlerinde 67 Python testi geçti.

Normal admin ekranı artık yazılabilir Core resource kaydından doğrulanmış
Proxmox hedefi ekliyor. Singleton target discovery, exact service revision ve
`proxmox_command_worker` egress grant'i okunuyor; deterministik hedef ID'si
sunucuyla aynı formülden üretiliyor. ProviderRef normal politika PUT'unda
saklanıyor. Belirsiz çoklu guest eşleşmesi reddediliyor; eski sağlayıcı bağı
olmayan guest hazır gösterilmiyor. Kullanıcı akışı testleri hiçbir cihaz
mutation isteği gönderilmediğini de kontrol ediyor. Politika en fazla 64 hedef
alıyor. 14 Flutter testi ve ilgili analyze temiz; 21 odaklı Python testi geçti.

Açık teslim işleri: gerçek UPS/Proxmox ortam kabulü. Fiziksel ev sistemine bu
dilimde mutation gönderilmedi.
