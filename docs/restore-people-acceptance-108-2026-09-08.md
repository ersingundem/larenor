# S08.5 ve S08.6 — CI108 yazılım kabulü

8 Eylül 2026. Kabul kaynağı: `960691c113b10e08ebddf75d464b99e74bdd4cb1`.

**S08.5 (restore/logout/journal hedef sınırı) ve S08.6 (kişi/oda/kaynak
kimliği ve yetki) yazılım kapıları tamamlandı.** Bu iki temel adımın kabulü
63 yeni özelliğin tamamlanma sayısını artırmaz. Merkezi HA adaptörünün
S08.7 bağımlılıkları artık sağlandı.

[Önceki bağımsız kaynak incelemesindeki](restore-people-acceptance-review-2026-09-06.md)
HomeResource/HomePeople, auth, database, contracts ve Client ev scope nesneleri
CI108 kaynağında aynı kaldı. Sonraki arşiv iptali, People geri dönüşü ve
restore diyalogu değişiklikleri kendi gerçek RED/GREEN testleriyle incelendi;
[yeni birleşik kaynak](tablet-core-volume-integration-2026-09-06.md) ayrıca doğrulandı.
Yerel inceleme makbuzu: `/private/tmp/larenor-960691c-restore-people-review.json`,
SHA-256 `b1deed4da6d724e8bdf8e22b1af65a034a0524c12d4e757ae2af3dab2d51d2ad`.
Bu makbuzdaki bekleyen yayın koşulu aşağıdaki teslimle karşılandı;
eski makbuz sonradan yeniden yazılmadı.

[CI108 tesliminin](client-delivery-108-2026-09-06.md) üç zorunlu koşusu aynı
kaynakta ilk denemede başarılı: 5.150 Flutter, 3.447 Linux Core, 98 JVM,
207 politika testi; analiz ve biçim kontrolü temiz. Android'de 4 platform ve
13 uygulama yolculuğu, 133 sıralı fazla geçti. Arşiv iptali, scoped restore,
kişi listesi ve yönetici ACL/onay akışları gerçek emülatörde doğrulandı.
APK108 bir kez indirilerek kaynak metadata'sı, sürüm ve kalıcı imzası
bağımsız kontrol edildi. Önceki başarısız CI105/106 sonuçları silinmedi.

Kapsam tek mevcut Core/ev bağlamıdır. Testler sentetik servislerle çalışır;
fiziksel tablet, evde gerçek cihaz komutu veya çoklu Core federasyonu kabulü
değildir. Sonraki Services ve hesap IME düzenlemeleri APK108'e dahil değildir.
