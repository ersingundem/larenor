# Kişi listesi için gerçek Android yolculuğu

Mevcut Android hedefinin sonuna bir üye yolculuğu eklendi. Core hesabına
PIN ile giriş, ana sayfada otomatik kişi isteği olmaması, açık liste girişi,
iki izinli profil, boş yanıtı açık yenilemeyle gösterme, Core'a geri dönme
ve yeniden açılan listenin taze yanıt alması sınanır. Üye ekranında admin
eylemleri bulunmamalı; eski etiketler boş yanıtla silinmelidir.

Yeni `SyntheticCorePeopleAccount` yalnız bu yolculukta, `AppHarness.start`
sonrası ve ilk mount/HTTP öncesi açıkça seçilir. Gerçek uygulama gezinmesi,
controller ve HTTP parser çalışır. Depolama ve sunucu disposable test
fixture'ıdır; gerçek Server SQLite, fiziksel cihaz veya kalıcı disk kabulü
bu senaryodan çıkarılmaz. HA isteği, WebSocket, ev komutu ve dış ağ isteği
sayaçları sıfır kalmalıdır.

Eski on yolculuğun tüm gövdeleri,99 fazı, timeout ve assertion'ları aynıdır:
yeni import ve register satırları çıkarılınca dosya `4da7e52` ile byte-identical.
Yeni helper8 faz ekler: hedef **4 platform +11 uygulama =15 E2E /107 faz**.
CI gözlemcisi yeni helper'daki fazları da aynı kaynak üzerinden okumalıdır.

Statik analiz2 dosyada0; biçim kontrolü2 dosyada0 fark. Bağımsız kaynak
incelemesi CLEAR; UI dalındaki gerçek key/üye/yenileme/route davranışlarıyla
karşılaştırıldı. [Fixture'ın113 destek testi](core-people-read-fixture-2026-09-06.md)
ayrı kanıttır ve native test sayısına eklenmez. Makbuz:
`/private/tmp/larenor-core-people-journey-evidence.json`.

**Android koşusu henüz yapılmadı.** Kişi UI dalıyla birleşim, tam yerel test
ve kendi CI/Android kanıtı gerekir. Bu belge kişi admin/ACL yolculuğunu veya
S08.6 tamamlanmasını kabul etmez. APK104 önceki on yolculuğu içerir; bu
yolculuk o pakete dahil değildir.
