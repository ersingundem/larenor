# Core logout kurtarma testinde çizim sırası

Yeni kişi satırı ve büyük yazı, hesap kurtarma eylemini görünür ekranın altına
itti. `ensureVisible` sıfır süreli kaydırmayı başlatır; widget testinde sonraki
frame çizilmeden `tap` önceki koordinatı kullanıyordu. Test artık tek frame
bekliyor, hedefin `hitTestable` olduğunu doğruluyor ve gerçek dokunmayla PIN
ekranını açıyor. Üretim UI, kaynak/oturum korumaları, timeout ve eski PIN
beklentileri değişmedi.

`9c8d4ca` ilk tam Client sonucu5.014 PASS/4 FAIL/5:51 olarak korunur. Aynı
kaynakta izole dokuz logout testi5 PASS/4 FAIL verdi. Dar onarım **9 PASS/2sn**,
analiz0 ve tek dosya biçim farkı0 verdi; bağımsız kaynak incelemesi CLEAR.
Dört eski hata EN/TR,600px,2× ve uzak/yerel silme hata durumlarıdır;1200px
ve mevcut normal akış kontrolleri de aynı dokuz testte korunur.

Loglar `/private/tmp/larenor-logout-scroll-{red,green,analyze,format}.log`;
source/hash makbuzu `/private/tmp/larenor-logout-scroll-evidence.json`.
Başarısız ve başarılı süreçler ayrıca exit kodlarıyla kapatıldı. Bu dar
geçiş yeni birleşimin tam Client, Android veya CI kabulü yerine geçmez.
