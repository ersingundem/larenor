# S08.10 — olay, komut sonucu ve sınırlı taşıma kabul matrisi

15 Eylül 2026 tarihli bu matris daha sonra tamamlanan dilimlerin başlangıç
kaydıdır. Birleşen yazılım zinciri, kesin CI ve bağımsız inceleme
`testing/s08-10-software-closure-2026-09-21.md` belgesinde toplandı; S08.10
**done** ve kuyruk 23/125 (%18,4) oldu. Fiziksel kabul ayrı manuel işlerde kalır.

## Ana dalda olan sözleşmeler

| Parça | Mevcut davranış | Açık bağı |
| --- | --- | --- |
| HA komut sonucu | Kaynak kapsamlı, şifreli/idempotent komut makbuzu; `pending`, `accepted`, `rejected`, `unknown`, ayrı provider kabulü ve gözlenen sonuç. Aynı `requestId` yeniden yazılmaz. | Son durum tek başına olay sırasını veya fiziksel etkiyi kanıtlamaz. |
| HA geçmişi | Kaynak ve aktör yetkisiyle sayfalı `/history`; `pending → final` yazımlarını koruyan, yetkili görünüme özel zincir kimliği ve ileri sıra cursor'ı sunan `/history/events`; admin için ayrı HMAC zinciri/checkpoint doğrulaması. Client'da aynı ev bağlamına bağlı etkinlik ekranı. | Client'ın yeni olay cursor'ını ve zincir değişimini kalıcı güven durumu ile birleştirmesi; yenileme başarısızken eski doğrulamanın yeni kanıt sayılmaması. |
| Sınırlı transfer | Ayrı `POST /blob` indirme akışı ve Core'da şifreli ürün blob sağlayıcısı; kaynak/user/ACL/service revision, 32 hex işlem kimliği, uzunluk, SHA-256 ve media type kapalı sözleşmedir. `PUT .../uploads/{requestId}` write yetkisini byte okumadan önce ve atomik kayıt anında denetler; Android güncel descriptor ile indirme ve write-yetkili bounded picker/upload akışını tüketir. | Medya-özel protokoller, kalan Client makbuz/olay checkpoint birleşimi ve fiziksel SAF. |

Client artık her kullanıcı başlatmalı indirme için kriptografik rastgele 128 bit
`requestId` üretir. Core bu kimliği doğrulayıp aynı değeri akış trace'i olarak
geri verir; Client farklı bir trace taşıyan yanıtı hiçbir byte yayımlamadan
reddeder. Böylece başlangıç ve doğrulanmış indirme sonucu aynı işlem kimliğine
bağlanır. Kalıcı transfer makbuzu, restart sonrası tekrar ayrımı ve geçmiş API'si
kalıcı Client geçmiş görünümü ve ürün protokolleri hala açık olduğundan S08.10
kabulü ve sayaçlar değişmez.

Komut olay okuması değiştirilebilir güncel komut satırını olaymış gibi tekrar
yorumlamaz. Şifreli append zincirindeki başlangıç ve sonuç snapshot'larını sıra
ile döndürür; cursor yalnız çağıranın o kaynakta görmeye yetkili olduğu görünüm
içinde artar. Global zincir konumu, başka aktör veya başka kaynak sayısı
sızdırılmaz. Aynı istek yeniden gönderildiğinde yeni olay üretilmez; okuma
restart sonrasında provider çağrısı veya komut replay'i yapmaz. Bu Server dilimi
olay sıra/tekrar temelini tamamlar; Client cursor/checkpoint bağlama ve kalıcı
transfer makbuzu açık olduğundan S08.10 henüz kapanmaz.

Core ürün sağlayıcısı Home resource `write` yetkisine bağlı, 256 KiB sınırında
ve AES-GCM ile şifreli belge/medya nesnesi saklar. İstek kimliği ile upload
makbuzu kalıcıdır; restart, değiştirilmiş SQLite satırı, eski revision, yetki
kaybı ve saat geri gidişi kapalı testlerle doğrulanır. Android descriptor ve
upload sözleşmesini tüketir; gerçek cihaz SAF/LAN ile medya-özel protokoller
henüz kapanmadığından S08.10 kapanmaz.
HTTP Range ve otomatik retry kapalı kalır. Core'un uygulama düzeyi devam
sözleşmesi yalnız aynı aktör/kapsam/içerik/provider revision değerlerine bağlı
`interrupted` makbuzdan yeni işlem kimliğiyle başlar; Android devam/cancel UX'i
ve fiziksel SAF kanıtı tamamlanana kadar özellik kapanmış sayılmaz.
[Pilotun sınırları](BOUNDED_TRANSFER_PILOT.md).

## Kabul dilimleri ve kaybolmaması gereken kanıt

1. **Yetki ve gizlilik:** Kullanıcı oturumu, Core/ev/kaynak, read ACL ve bütün
   beklenen revision alanları özel byte'a veya sağlayıcının 404/409/413 varlık
   sinyaline erişmeden doğrulanmalı. Yanlış hedef, iptal edilmiş oturum, hak
   kaybı ve gecikmiş yanıt testleri aynı sınırı zorlamalı; ham içerik/sır loga,
   makbuza veya hata gövdesine girmemeli.
2. **İzlenebilir olay:** Başlangıç ve sonuç aynı `requestId` ile ilişkilendirilmeli;
   kaynak kapsamlı olay okuması monotonic sıra, chain/epoch kimliği, `after`
   cursor'ı, tekrar/kopuş/rollback ayrımı ve bounded sayfa boyutu taşımalı.
   Eski aktörün veya başka kaynağın olayı sızmamalı. Geç olay yeni oturum/ev
   veya daha yeni sonucun üstüne yazılmamalı.
3. **Client durum dili:** Kayıtlı niyet, erişilebilir servis, provider kabulü ve
   cihazda gözlenen sonuç ayrı gösterilmeli. Kısmi/belirsiz durum başarı
   sayılmamalı; geçmiş veya integrity okuması başarısız olduğunda tutulan
   checkpoint güncel doğrulama gibi kullanılamamalı. Tablet/DeX 600 ve 1280
   genişlik, EN/TR 2× metin, 48 dp, klavye ve TalkBack sınırı korunmalı.
4. **Ayrı taşıma:** JSON kontrol yolundan ayrı binary indirme bütün length,
   digest, media type, revision, trace ve frame sırasını doğrulamadan SAF'a
   byte vermemeli. Fazla boyut, geç son frame, kopuş, iptal, kota ve yetkisiz
   indirme testleri hem Server hem Client tarafında olmalı. Ürün sağlayıcısı,
   upload/media protokolü ve kalıcı transfer makbuzu ayrıca tamamlanmalı.
5. **Birleşim:** Aynı exact committe hedefli Server/Client/kontrat testleri,
   bağımsız yetki/lifecycle incelemesi ve zorunlu GitHub CI yeşil olmalı.
   Fiziksel Huawei/DeX/SAF ve gerçek LAN kabulü `MANUAL.TABLET` ile
   `MANUAL.SERVICES` işlerinde ayrı izlenir; yazılım kanıtının yerine geçirilmez.

Bu matristeki tekil düzeltmeler teslim edilse bile S08.10 yalnız bütün gerekli
`test`, `review` ve `ci` kanıtı ile queue doğrulayıcısı `done` sonucunu verdiğinde
sayaç artırılır.
