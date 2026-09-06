# Hane profilleri — bağımsız Core API ve şifreli kayıt

S08.6'nın kişi sözleşmesinden sonraki dilimidir. Kişi kaydı, evde görünen ad ve
sıra bilgisidir. Oluşturmak oturum hesabı, Home Assistant kişisi veya sağlık
profili oluşturmaz. Bu paket Android kişi ekranının ya da bütün S08.6'nın
kabulü değildir.

## API ve veri sınırı

`/api/v1/home-people/{core_id}/{home_id}` yalnız mevcut evin izinli kayıtlarını
listeler; `/{record_id}` ayrıntıyı verir. Aynı yolun `/api/v1/admin` altında
oluşturma, metadata güncelleme, silme, izin okuma ve izin değiştirme uçları
vardır. Swagger'da ayrı `Household profiles` modelleri görünür. Yönetim
uçları güncel admin gerektirir; member görünürlüğü açık kayıt iznine bağlıdır.
Yazma izni gözlemi admin endpoint erişimi veya cihaz çalıştırma yetkisi vermez.

Eski `home-resources` endpoint/modeli yalnız oda/kaynak olarak kaldı. Ayrı
`home_people_records`, `home_people_state`, `home_people_audit` tabloları ve
`home_people_schema=1` işareti Core'un mevcut başlangıç transaction'ına eklenir.
Genel schema_version3 ve diğer kayıtlar korunur. Önceki veritabanından eklemeli
migration testi hesaplar, tokenlar, vault, context ve oda satırlarını karşılaştırır.

Metadata/izinler AES-GCM ile şifrelenir. AAD, integrity state ve görünür liste
snapshot'ı ayrı kişi domain'lerine bağlıdır. Kimlik Server tarafından üretilir;
istemci yalnız ad/sıra sağlar. Metadata ve ACL revision ayrı CAS koşullarıdır.
Güncel actor/session/role aynı yazı transaction'ında tekrar doğrulanır. Gizli ve
olmayan kayıtlar aynı404 yanıtını verir; gizli değişiklikler member'ın liste
snapshot'ını değiştirmez. Pagination görünür snapshot'a bağlıdır.

Kayıt sınırı128, kişi başına izin128, toplam izin4096 ve audit10000'dir.
Silme boşalan kapasiteyi açar. Değişiklik olmayan metadata/ACL isteği revision,
şifreli payload veya görünür snapshot'ı yenilemez. Bu audit genel değiştirilmeyi
kanıtlayan işlem günlüğü özelliğinin kabulü değildir.

## Kanıtlar

| Kontrol | Kaynak / sonuç |
|---|---|
| İlk gerçek HTTP regresyonu | RED133a254:11 başarısız; GREEN878598a:11 PASS |
| İlk actor/storage güvenliği | 0b407fe:37 PASS; daha geniş ilgili kaynak seti205 PASS/58,22sn |
| Bağımsız kaynak incelemesi | Actor transaction, ayrı API/crypto, görünür snapshot ve migration incelendi; bağlı SQLite nesnesi bulgusu çıktı |
| Bağlı index/trigger düzeltmesi | RED95d1cef:6 FAIL/1 PASS; GREENa3b523f:7 PASS |
| Kişi model/API/safety regresyonu | a3b523f:101 PASS/22,37sn |
| No-op ve kapasite HTTP kontrolleri | 789026a:104 PASS/22,64sn; ilgili104 aynı koşunun toplamıdır |
| Son dal kapsamı | 401statement/30eksik,122branch/25partial; branch-inclusive%89. API38/38statement%100 |

Üç kişi tablosuna farklı adlarla bağlı UNIQUE index ve INSERT'i sessizce yutan
trigger yeniden başlangıçta reddedilir. Hatalı storage ve dump korunur; yalnız
beklenen gerçek SQLite PK autoindex'i kabul edilir. Başka tabloların nesneleri
etkilenmez. Bu düzeltme root tarafından bağımsız olarak tekrar incelendi;
somut açık P1/P2 bulunmadı. Eski kaynak domain'ine bu dilimde değişiklik yapılmadı.

Özel loglar `/private/tmp/larenor-home-people-http-{red,green}.log`,
`larenor-home-people-regression.log`, `larenor-home-people-attached-schema-*`,
`larenor-home-people-final-http.{log,xml}`. İlk uygulamadaki çoğul property
hatasının başarısız çıktısı da korunur. Sonradan eklenen no-op/kapasite testleri
zaten doğru davranışı doğruladı; onlar için yeni RED iddiası yoktur.

## Kalan doğrulama ve ürün işi

Son tam Server koşusu7819866 kaynağında **3.298 PASS / 0 FAIL / 11 Linux skip /
321,74sn** verdi. JUnit3309test/0error/0failure;11skip Linux kernel/procfs/peer
credentials gerektirir. Log/XML `larenor-home-people-full-server-final.{log,xml}`.
İlk tam koşudaki3.291 PASS/5 FAIL ve tarihsel v1/v2 fixture onarımı
RED5db91ad→GREEN7819866 ile korunur; üretim migration korumaları gevşetilmedi.
Testler geçici sentetik veritabanı/HTTP kullanır. Gerçek evde migration,
kurulum veya cihaz işlemi yapılmadı. CI103 yalnız dar logout fixture onarımıdır;
bu Server kişi API'sini içermez. Android listesi/admin yönetimi, kalıcı ortak
HTTP sözleşme fixture'ı ve kendi exact-source Linux/Android teslimi sonraki
adımlardır. Kişisel sağlık/varlık tanıma ve hesap eşleme sessiz eklenmez.
