# Services, IME ve Jellyfin native CI yayın hazırlığı

8 Eylül 2026. Birleşik kod/test/workflow kaynağı `cb25e7894631c7efbfa9733b98dd654f32a694c3`.
Bu kaynaktan sonraki hazırlık değişiklikleri yalnız belgelerdir.

| Alan | Gerçek yerel kanıt | Ayrı bekleyen kapı |
| --- | --- | --- |
| Android Services ve hesap IME | [5.218 PASS / 2 timeout; aynı kaynakta 2 PASS tekrar, analiz 0, 973 dosyada biçim farkı 0](core-services-ime-integration-2026-09-08.md) | Temiz tam Client CI, 17 E2E / 133 faz ve bağımsız APK |
| Jellyfin fixture ve launcher | [122 pytest PASS, 215 politika PASS, root kaynak incelemesi temiz](jellyfin-storage-manual-ci-2026-09-08.md) | Gerçek ayrı native amd64/arm64 ephemeral Engine |
| Server otomatik test keşfi | **3.569 test toplandı**; collection hatası yok | Bu sayı yeni tam Server PASS sonucu değildir; Linux CI bekliyor |
| Güvenlik ve kuyruk | Statik CI/Android güvenlik politikası, 125 işlik kuyruk doğrulaması ve 39 commit gizli bilgi taraması temiz | Yeni kaynağın kendi GitHub sonuçları |

Yeni Server testi sayısı, önceki 3.447 teste 87 fixture ve 35 launcher testi
eklenmesiyle 3.569 olur; collection bunu doğruladı. Önceki full Core sonucu
bu yeni sayıya yeniden etiketlenmedi. Server, tool ve workflow Git ağaçları
`da5fd47` test/inceleme kaynağıyla aynı; Android lib/test/integration/lockfile
nesneleri `cd961ac` Client doğrulamasıyla aynıdır. Yeni HA adaptörü ayrı dallarda
çalışıyor, bu yayına dahil değildir.

İmzalı Client'ı ev Server'ına gönderen repository değişkeni bulunmadığı
salt okunur kontrolle görüldü; bu hazırlık ev yayını yapılandırmaz. Yeni
native workflow yalnız GitHub'ın kendi geçici VM/daemon/volume'larında
çalışabilir. `installAvailable=false`; ilk Jellyfin hesabı ve gerçek ev
kurulumu bu hazırlığın sonucu değildir.

Özel kaynak/kanıt kayıtları:
`/private/tmp/larenor-services-ime-native-publication-checks.json`,
`/private/tmp/larenor-jellyfin-workflow-root-review.json` ve
`/private/tmp/larenor-jellyfin-workflow-delivery-evidence.json`.
Eski CI108 teslim makbuzu ve başarısız yerel Client koşusu aynen korunur.
