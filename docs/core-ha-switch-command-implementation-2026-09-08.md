# S08.7 dilim 2 — kalıcı Core komutu ve tablet denetimi

8 Eylül 2026. İncelenen davranış kaynağı
`409ffc8c8e0760234fd011d4f95396d0d9a8e2d5`; bu dilim seçili ve
önceden bağlanmış bir Home Assistant `switch` kaynağına Larenor Core üzerinden
`turn_on` / `turn_off` komutu gönderir. S08.7 hâlâ Direct aktarımı, geniş HA
varlık/servis kapsamı, exact-source CI ve fiziksel Android/HA kabulü nedeniyle
açıktır.

## Sonuç ve güvenlik sınırı

Client yalnız güncel Core kaydında WRITE izni ve güncel snapshot'ta
`commandAvailable:true` birlikte bulunduğunda Aç/Kapat denetimlerini gösterir.
Core komuttan hemen önce oturumu, home/resource kapsamını, WRITE ACL'yi,
resource/ACL/binding/service revision'larını yeniden okur. Ortak transport DNS,
bağlantı ve TLS kurulumundan sonra, ilk HTTP baytı gönderilmeden hemen önce aynı
yetki ve revision kapısını yeniden çalıştırır. Bu yetki ağ gönderim kapısıdır;
eski snapshot veya eski ACL bir dispatch yetkisi değildir. Salt-okunur üye yalnız
durumu görür. Admin ve WRITE üyelerinin snapshot capability değeri `true`,
preview capability değeri `false` kalır.

Her komut Client'ta kriptografik rastgele 128-bit küçük-hex `requestId` ile bir
kez hazırlanır. Core şifreli `pending` niyeti ağ çağrısından önce SQLite'a
yazar; aynı actor/resource/request gövdesi kalıcı makbuzu döndürür ve upstream'i
ikinci kez çağırmaz. Aynı kimliğin farklı gövdesi `409 ha_command_conflict`,
başka actor çakışması `404` olur. Süreç kesilmiş bir `pending` kayıt restart
sonrası `unknown` olur ve otomatik replay edilmez.

Upstream yolu mevcut kapalı transport üzerinden yalnız
`POST /api/services/switch/turn_on|turn_off` ve sabit
`{entity_id:<bağlı anahtar>}` gövdesidir. Redirect, proxy ve retry kapalıdır;
ortak 3 saniye/64 KiB sınırı ve en fazla dört eşzamanlı adaptör işlemi korunur.
Provider yalnız `200` döndürürse `accepted/providerAccepted:true` olur.
`400/401/403/404/405/422` açık `rejected`, diğer bütün sonuçlar ve bağlantı
belirsizlikleri `unknown` olur. Ayrı durum okuması hedefi gösterse bile
`causalityVerified:false` kalır; fiziksel cihaz sonucu iddia edilmez.

Komut başlarken ve tamamlanırken kaynak cache nesli ilerletilir. Böylece komut
öncesinde başlayan veya komut sürerken biten bir snapshot, sonradan eski veriyi
cache'e geri koyamaz. Son makbuz diske yazıldıktan sonra yanıt yayınlanmadan önce
güncel READ yetkisi yeniden doğrulanır; yetkisini o arada kaybeden actor sonucu
göremez, fakat admin kalıcı makbuzu kurtarabilir.

## Makbuz ve kurtarma

Public HTTP yüzeyi:

| İşlem | Sonuç |
| --- | --- |
| `POST .../resources/{id}/commands` | `202 {receipt}`; yeni veya birebir idempotent sonuç |
| `GET .../resources/{id}/commands/{requestId}` | `200 {receipt}`; yalnız sahibi, admin veya yetkili güncel kapsam |

Makbuz request/resource/binding/actor/action kimliklerini; `pending`,
`accepted`, `rejected` veya `unknown` dispatch durumunu; nullable provider ve
gözlem sonucunu; oluşturma/tamamlama zamanlarını taşır. Kayıtlar AES-GCM ile
şifrelenir, AAD request/resource'a ve HA envanter HMAC'i binding+komut
tablolarına bağlıdır. Şema v1→v2 geçişi eski binding HMAC'ini doğrulayıp yeni
tabloyu aynı transaction'da ekler. Bozuk tablo, index, ciphertext veya HMAC
startup'ı kapalı biçimde durdurur. Komut kotası 1024'tür.

Client yanıt kaybında aynı POST'u göndermez. Orijinal request ID bellekte
tutulur ve “Komut sonucunu geri al” yalnız GET yapar. `pending` makbuz kurtarma
kimliğini korur; yalnız terminal makbuz bu kimliği temizler. Dispatch öncesi
kesin `403/404/409` gibi yanıtlar kimliği temizleyerek yeniden komuta izin verir.
Kaynak/hesap/home/route, PIN veya pencere otoritesi kaybolursa controller
alanları emekliye ayırır. Başarılı, reddedilmiş veya sonucu bilinmeyen makbuz
açık metin durumuyla gösterilir; eski switch snapshot'ı hemen geçersizleşir ve
kullanıcı güncel durumu ayrıca yeniler.

## Sözleşme ve doğrulama

`contracts/home-assistant.v1.json` gerçek FastAPI/auth/SQLite ve sahip olunan
loopback HA fixture'ından üretilen 22 Client tüketimli karşılığı taşır. Toplam
upstream gözlem sayısı 8, gerçek komut fixture çağrısı 1'dir. Contract SHA-256:
`a8cd02a6f0bb1f4af3e763807303cff3897284142f7c258bf422dfc778295d79`.

- Server ilgili koşu: **222 PASS**, 0 fail/error/skip. Coverage log SHA-256
  `cf5f9996f00cdd63327c4470fe21b3bc059abe617a793efc734265185c670d59`.
- Doğru Java 17 ve SHA-256 ile pinlenmiş resmi `apksig 9.1.0` ortamındaki tam
  Server koşusu **3748 PASS**, 0 failure/error ve 12 macOS platform skip verdi;
  JUnit toplamı 3760, süre 384,928 saniye. JUnit SHA-256
  `b71829bb14ac87ef27a6c238ba216988b47d67565a75f02eaba1264dbd324fa1`,
  log SHA-256
  `10fc694d87d2becf376c3920dda4244c33cfe214e42e692be35c5bbd7921e691`.
- HA namespace ve ortak statik hata modülü 601/645 satır, 154/194 dal;
  birlikte 755/839 (**%89,99**). Paylaşılan servis transportu da dahil
  edildiğinde 1247/1377 (**%90,56**) dal dahil kapsamdadır. Bu tüm Server
  coverage'ı değildir.
- Client ilgili koşu: **124 PASS**. Coverage log SHA-256
  `cf70c5c3061cfc4592a5eb4e5d2209e78db3eeb7f6e5b6e199cf2b286a104b90`.
- Client feature coverage: Core HA dosyaları 1023/1071 satır (**%95,52**).
  Paylaşılan Server HTTP transportu dahil toplam 1082/1156 satırdır
  (**%93,60**); bu line coverage ölçümüdür.
- Tüm Flutter analyzer: 0 issue; log SHA-256
  `24f06e06c72775c69fd97e2969d75f78a9066373dce6d8564a72ef9088717969`.
  Biçim denetimi 17 dosyada sıfır fark verdi; log SHA-256
  `e509da41baebdb0dbe6cd05fae63b600d9b56e51d5d5ebd4984674da78d07b30`.
  EN/TR, 320/600/1280, açık/koyu, 2× yazı,
  48 px hedef, klavye Enter/Space ve viewport testleri geçti. Komut denetimleri
  600/1280 genişlikte ayrıca çalıştırıldı.

Apple tasarım denetimi sistem renkleri, ölçeklenen sistem metni, açık durum
metni, renk dışı seçili durum, canlı sonuç bölgesi, basit düğme eylemi ve
tablet/yeniden boyutlanan pencere uyumunu doğruladı. QA görüntüleri
`/private/tmp/larenor-ha-command-qa2/` altındadır. Bunlar fiziksel Huawei,
Samsung DeX, TalkBack veya gerçek Home Assistant kabulü değildir.

Bağımsız son kaynak incelemesi; gönderimden hemen önce yetki iptali, eski cache
yeniden doldurma yarışı, provider `5xx` belirsizliği, `pending` kurtarma
kimliğinin korunması, kesin dispatch-öncesi hatanın kimliği temizlemesi ve
makbuz yazımı ile yanıt yayını arasındaki READ iptalini yeniden sınadı. Açık
P1/P2 bulmadı.

Testlerde yalnız geçici SQLite ve sahip olunan loopback fixture kullanıldı.
Kullanıcının gerçek HA sunucusuna hiçbir yazma, silme veya komut işlemi
yapılmadı. Gerçek HA üzerinde daha önce verilen erişim anahtarı hiçbir kanıta,
loga, sözleşmeye veya repoya yazılmadı.
