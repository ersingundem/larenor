# S08.10 — olay, komut sonucu ve sınırlı taşıma kabul matrisi

15 Eylül 2026. S08.10 yazılım işi bu kayıtta **açık** tutulur. Bu belge
mevcut kabul sınırını ve sonraki parçaların kanıtını ayırır; yeni `done` veya
`installAvailable` iddiası üretmez. Kuyruk 15/125 (%12,0), seçili özellikler
0/63 (%0,0) olarak kalır.

## Ana dalda olan sözleşmeler

| Parça | Mevcut davranış | Açık bağı |
| --- | --- | --- |
| HA komut sonucu | Kaynak kapsamlı, şifreli/idempotent komut makbuzu; `pending`, `accepted`, `rejected`, `unknown`, ayrı provider kabulü ve gözlenen sonuç. Aynı `requestId` yeniden yazılmaz. | Son durum tek başına olay sırasını veya fiziksel etkiyi kanıtlamaz. |
| HA geçmişi | Kaynak ve aktör yetkisiyle sayfalı `/history`, admin için ayrı HMAC zinciri/checkpoint doğrulaması; Client'da aynı ev bağlamına bağlı etkinlik ekranı. | Kaynak olaylarının sıra/kopuş/tekrar izlenmesi ve yenileme başarısızken eski doğrulamanın yeni kanıt sayılmaması. |
| Sınırlı indirme | Ayrı `POST /blob` binary akışı; kaynak/user/ACL/service revision, 32 hex iz kimliği, sıralı frame, boş son frame, uzunluk ve SHA-256. Client tam doğrulamadan sonra Android SAF hedefini açar. | Gerçek ürün sağlayıcıları ve ayarları, kalıcı makbuz, ayrı upload/media protokolü, fiziksel SAF. |

Client artık her kullanıcı başlatmalı indirme için kriptografik rastgele 128 bit
`requestId` üretir. Core bu kimliği doğrulayıp aynı değeri akış trace'i olarak
geri verir; Client farklı bir trace taşıyan yanıtı hiçbir byte yayımlamadan
reddeder. Böylece başlangıç ve doğrulanmış indirme sonucu aynı işlem kimliğine
bağlanır. Kalıcı transfer makbuzu, restart sonrası tekrar ayrımı ve geçmiş API'si
hala açık olduğundan S08.10 kabulü ve sayaçlar değişmez.

İlk indirme sağlayıcısı üretimde boş kalır. Sunucuda hazırlanan medya kataloğu
veya bir dosya yolunun varlığı, yetkili binary sağlayıcı kurulmuş olduğu
anlamına gelmez. Range/resume, otomatik retry ve belirsiz komutun replay'i
güvenli kurtarma sözleşmesi ayrıca kurulmadan açılmaz. [Pilotun sınırları](BOUNDED_TRANSFER_PILOT.md).

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
