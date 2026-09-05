# S06.3e — özel kontrol ağını okuma

5 Eylül 2026. [Saf ağ sözleşmesinin](network-resource-implementation-2026-09-05.md)
üzerine `network_transport.py` eklendi. `UnixNetworkEngine.list` yalnız
kaynak planından türetilen adla liste okur; `inspect` yalnız tam 64 hex ağ
kimliğiyle ayrıntı okur. Oluşturma, otomatik inspect, container attach veya
journal yazımı yapmaz. `installAvailable=false` korunur.

İki işlem de [ortak Unix HTTP katmanını](engine-http-implementation-2026-09-05.md)
kullanır: aynı bağlantıda peer/socket ve sürüm/platform denetimi → tek GET →
son kimlik/iptal/süre kontrolü. Sabit Accept başlığı ve boş request body
korunur. Allowlist'e yalnız canonical ad filtresi ve tam ID inspect eklenir;
network POST, DELETE, ek filtre, prefix ID veya serbest URL açılmaz.

Bir çağrının varsayılan toplam süresi 10 saniye, idle süresi 2 saniye,
chunk sınırı 4.096'dır; özel operatör değerleri bunları yalnız azaltabilir.
Liste 128 KiB, inspect 64 KiB ile sınırlıdır. Liste ve inspect iki açık çağrı
olduğundan bu sınırlar birleşik iş bütçesi sayılmaz. İstemci mevcut 5 saniyelik
IPC işlerine bağlanmaz.

Bağlı plan/katalog/politika snapshot'ı ve intent I/O öncesinde ve yanıt
doğrulamasında yeniden denetlenir. Yeni bir global katalog nesnesini otomatik
izlediği iddia edilmez; güncel actor/politika/revision yetkisi gelecekteki
çağıran koordinatörün sorumluluğudur. Dışarıda kalmış orijinal plan kopyası
bağlı snapshot'ın yerine geçmez.

Tam yanıtın gerçek framing başlıkları saf doğrulayıcıya iletilir. Yalnız tam,
sınırlı ve uygun 200 listesi `missing` veya `candidate` verebilir. 404,
yönlendirme, kısmi/paginated cevap, kesilmiş gövde veya encoding hatası
`missing` sayılmaz. Aday liste kaydı sahiplik makbuzu değildir; ayrıca tam ID
inspect gerekir. Inspect, bağlı etiket/profil ve boş container bağlantıları
gözlemini doğrular; aynı adlı yabancı/çoklu ağ ve sonradan eklenmiş yabancı
endpoint reddedilir. Bu zaman noktasındaki sonuç create/attach yetkisi vermez.

## Kanıt

Plan `a293f06` → RED `9b27990` → ilk GREEN `b09c12e` → geniş regresyon
`3076f5f`. Yeni adaptör testleri **100 geçti, bir Linux peer testi Mac'te
atlandı**. Ağ, imaj, imaj/journal köprüsü ve kaynak regresyonunda **579 geçti,
üç Linux testi Mac'te atlandı**. Bütün denemeler geçici Unix listener/SQLite
ile yapıldı; ev Docker daemon'una veya registry'ye bağlanılmadı.

AMD64/ARM64, sabit uzunluk/chunked framing, bağlı snapshot değişimi, bozuk
limit/intent, uncertain intent ile salt okuma, kayıp/bozuk cevap, iptal/süre
ve journal revision'ının değişmemesi kapsanır. İlk geniş koşudaki tek hata,
bağlı snapshot yerine dışarıda kalan orijinal kopyayı bozan test fixture'ından
kaynaklandı. Fixture düzeltildi; bu iki kopyanın ayrılığı ayrıca test edildi.
Üretim kodu ilk GREEN'den sonra değişmedi; final regresyon bütünüyle geçti.

Yeni adaptör **66/66 statement, 16/16 dal (%100)**; ortak HTTP katmanı **%98**.
İki bağımsız incelemede yeni P1/P2 bulgu kalmadı. Tam Server ve uzak Linux CI
kanıtı [PROGRESS](PROGRESS.md) içinde kendi kaynak commit'iyle ayrılır.
`3076f5f` ile tam yerel Server regresyonu **2.291 geçti, beş Linux testi
Mac'te atlandı**; 202 araç testi ve yeni commit aralığının güvenlik taraması
da geçti. Son Client paketinde **2.701 Flutter testi** ve temiz tam analiz var.
Create/journal etki köprüsü ve gerçek Engine kabulü açık olduğundan S06.3e
bütünü tamamlanmış sayılmaz.

## Linux CI bağlantı kapanışı düzeltmesi

`54a677b` Server CI'ında 2.295 test geçti, yalnız iptal sonrası peer kapanışı
bekleyen test başarısız oldu. İstemcinin `network_cancelled` beklentisi geçti;
fixture `recv` için yalnız EOF kabul ediyordu. Linux, okunmamış Unix stream
verisiyle kapanışta peer'a ECONNRESET bildirir ([sabit Linux v6.8 kaynağı](https://github.com/torvalds/linux/blob/v6.8/net/unix/af_unix.c#L605-L610)).
Eski fixture reset istisnasını dış yardımcıda yuttuğundan CI logu errno'yu
kanıtlamaz; bu açıklama kaynak ve kontrollü yeniden üretimle desteklenir.

`b2ca01f` RED: gerçek bağlantı EOF'u alındıktan sonra sentetik reset üreten
parametre, eski fixture'da başarısız oldu. `bff9b98` GREEN: yalnız
`ConnectionResetError` da kapanış sayılır. Gerçek EOF/reset olmadan event
ayarlanamaz; veri, timeout ve diğer hatalar hâlâ başarısız. `closed.wait(1)`
değişmedi, üretim kodu değişmedi. Ayrı Linux socketpair testi okunmamış veri
kapanışının gerçek kernel sonucunu denetler; Mac'te atlanır.

Odaklı koşu **2 geçti / 1 Linux atlaması**; network/shared HTTP/image regresyonu
**333 geçti / 4 Linux atlaması** (24,06 saniye). Bağımsız inceleme kapanış
kanıtının zayıflatılmadığını doğruladı. Yeni uzak Linux sonucu kendi yayın
commit'iyle [PROGRESS](PROGRESS.md) içinde kaydedilecek; eski başarısız koşu
başarılı sayılmaz ve ev daemon'una herhangi bir işlem yapılmadı.
