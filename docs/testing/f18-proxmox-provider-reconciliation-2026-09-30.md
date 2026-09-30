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

Açık teslim işleri: Flutter'da açık admin uzlaştırma etkileşimi, normal kurulum
yoluyla hedef seçimi ve gerçek UPS/Proxmox ortam kabulü. Fiziksel ev sistemine
bu dilimde mutation gönderilmedi.
