# Android 104 — çıkış ve yeniden açılış doğrulandı

Kaynak `64bdf58951ea371dc5ad0ed65348c533c8c777dc`. Üç workflow ilk denemede
başarılı; imzalı APK ayrıca indirildi ve aynı kaynağın Java doğrulayıcısıyla
bağımsız incelendi. CI102 ve CI103 hata kayıtları korunur, yeniden koşulmadı.

| Kanıt | Sonuç |
| --- | --- |
| [Android104](https://github.com/ersingundem/larenor/actions/runs/34013071464) | Flutter4.421 PASS, analiz0,900dosya biçim farkı0, JVM98 PASS |
| [Core31](https://github.com/ersingundem/larenor/actions/runs/34013071566) | Linux3.203 PASS/0skip/421,96sn; iki mimaride build ve runtime smoke geçti |
| [Güvenlik104](https://github.com/ersingundem/larenor/actions/runs/34013071378) | 207 PASS; dependency ve redakte sır taraması geçti |
| Android E2E | 4 platform +10 uygulama =14 PASS;99 faz eksiksiz ve aynı sırada |
| [İmzalı APK104](https://github.com/ersingundem/larenor/actions/runs/34013071464/artifacts/9983375079) | Tek tam transfer; paket, sürüm, kaynak ve kalıcı imza eşleşti |

Onuncu yolculuk PIN korumalı çıkışı, iptali, kalıcı oturum silmeyi ve aynı
süreçte uygulamayı yeniden kurduktan sonra korunan kurtarma girişini doğruladı.
Önceki dokuz yolculuk ve89faz değişmedi. `singleElementReady` yalnız tek
mounted hedef hazırken mevcut predicate'i çağırır; timeout veya kabul
beklentileri gevşetilmedi. [Dar onarım](logout-remount-readiness-repair-2026-09-06.md).

Emülatör36.1.9.0/build13823996, API35 x86_64. Script496,014917sn/1080sn,
tüm emülatör adımı560sn/1500sn. Android workflow'un tekrar kullandığı
Server testleri de3.203 PASS/0skip verdi; aynı testler toplama eklenmez.

APK120.798.761 bayt; ZIP56.526.544 bayt, tam transfer sayısı1.
`com.ersingundem.larenor`, sürüm1.0.0/`100000104`, minSdk26,
`debuggable=false`. Java17 ve SHA256 ile sabitlenmiş apksig9.1.0 kullanıldı.

- APK SHA256: `426071fd9b53cfef28d1b2ad5472564ceb94bb19d811dcd325aca4d649a8cedb`
- Kalıcı sertifika: `d7c8be0fd89daa2d60aa97a249aa1e3615aed92fcb7e4135bbbd7456eb5882a0`
- Anonim stable/immutable Core index: `sha256:4fcaef0e049ab269bb6b17c86f0b5bb2a91e06899551c0ce6810dd98b80a967e`

İki mimarinin kaynak/AGPL etiketleri doğrulandı; imaj katmanı indirilmedi.
Container testi medya hazırlığı oluşturma/yeniden başlatma/iptal sınırını
sınar; gerçek bileşen kurma hâlâ kapalıdır. Ev Core'una yayın atlandı,
cihaz kurulumu ve gerçek HA/medya/ağ işlemi yapılmadı.

Makbuz `/private/tmp/larenor-64bdf58-delivery-evidence.json`; SHA256
`878b2331d34505c3eb0b3955ce00d9169780e9bf90360a13737d90071790ab70`.
Durum `delivery_verified`; tüm gözlem süreçleri tamamlandı. Kaynak commit'i
ve test sınırları bu makbuza bağlıdır.

Hazırlanan dosya/Vault restore, yeni Core oda arşivi ve kişi API/ekranları
bu APK'da bulunmaz. Bunlar ayrı yerel birleşimdedir ve kendi uçtan uca/CI
kabulünü bekler. Fiziksel tablet ve ev sistemi kabulü ayrıca açıktır.
