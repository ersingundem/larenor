# Direct HA aktarımı — Client uygulama kanıtı

8 Eylül 2026. Client tabanı `25d438aed00b44cf10322a500a4dbb001c920dfd`;
son kaynak/test checkpoint'i `2139d327d3a509d6f8a67d4193735905607e4d0d`.
Server sözleşme checkpoint'i `327a3b2` ve son Server dalı
`387867e1c1b747254100442dc88fea1936578db9` geçmiş korunarak birleştirildi.
Bu belge sonlu Client aktarım akışını kapsar; Android cihaz/CI veya bütün
S08.7 kabulü değildir. Gerçek HA, ev ağı veya komut kullanılmadı.

## Kullanıcı akışı ve kayıt sınırı

Direct ana kaynak ayarından açık aktarım girişine, mevcut SettingsGate ve
PIN altında ulaşılır. Ayrı, güncel doğrulanmış Core admin oturumu gerekir.
Kullanıcı yerel dashboard'daki tek canonical `switch.*` ile aynı Core/evdeki
mevcut resource hedefini seçer. Önizleme hedefin güncel metadata revision,
ACL revision ve henüz HA binding'i bulunmadığını GET ile doğrular. Server
confirm sırasında kendi transaction/CAS kontrollerini yeniden uygular.

Önizleme, yeni Home Assistant servisinin adı, seçilmiş switch ve kapalı
projection gösterir. URL/token gösterilmez. İptal ve onay açık eylemlerdir;
URL/token çifti yalnız bu eylem için okunur. Direct dashboard ve credential
kayıtları korunur. Oda düzeni, scene/script, diafon, web URL/origin izinleri
ve diğer bağlantıların aktarılmadığı ekranda açıklanır. Bu, bütün Direct
verilerinin taşınması veya var olan Core servisin üzerine yazılması değildir.

`CredentialsStore.readForTransfer` ayrı bir metottur. Mevcut genel `read`
imzası ve normal Direct arka plan okuması değişmez. Aynı ConfigurationWrites
sırasında marker, URL ve token okumalarının her birinden önce ve sonra hem
Direct kaynak hem eylem yetkisi denetlenir. Pending marker, yarım çift,
bozuk/oversize değer ve platform hatası statik hata üretir. False/throw
callback veya ilk okuma sırasında PIN/kaynak kaybı bir sonraki secure-store
okumasını ve HTTP dispatch'i durdurur. Core kaynakta bu aktarım yolunun
credential/client okuması sıfırdır. Direct uygulama açılışındaki mevcut genel
HA okuması ile yeni aktarım eyleminin okumaları testlerde ayrı ölçülür.

## Ömür, onay ve belirsiz sonuç

Controller ve route; ProviderContainer, home controller, repository/store,
HomeSession runtime identity/epoch, account generation ve tam oturuma bağlıdır.
PIN, parent/root gate, native view, pencere focus/PiP, lifecycle, route/Ticker
ve callback geçerliliği korunur. Gözlenmiş false/throw sahipliği emekliye ayırır;
aynı State A→B→A taşındığında eski callback yeniden yetki kazanmaz. Route
örtülmesinden dönüş ancak yeni bir owner ve yeni okuma ile devam eder.
Pencere false/loading/error iken tutulan giriş callback'i yeni PIN açmaz.

Yalnız public seçenekler ilk yüklemede okunur. Önizleme ile onay arasında
private yerel layout fingerprint'i ve ham HA çifti yeniden okunup karşılaştırılır.
Token normalize edilmez; ASCII 0x21..0x7e, 1–2048 sınırı korunur. Preview TTL
monotonic dispatch başlangıcından hesaplanır; ağ süresi kullanma süresinden
çıkarılır. Onaydan önce TTL ve bütün eylem sınırları denetlenir. Onay gönderilmişse
sonradan TTL dolması bir commit'i yok saydırmaz.

Onay sonrası belirsiz cevapta otomatik POST tekrarı yoktur. Credential ve
layout witness bırakılır; yalnız public request/preview bilgisiyle açık sonuç
GET'i sunulur. Sonuç404 hâlâ belirsizdir. Receipt tarihsel commit bilgisidir,
güncel binding veya HA komut sonucu sayılmaz. Route/account/source emekliliği
bu bellek içi kurtarma bilgisini de temizler; Client pending request ID'yi
uygulama yeniden başlamaları arasında kalıcı saklamaz. Server'ın kalıcı
receipt/restart kanıtı ayrı Server belgesindedir. Dart string belleği için
secure-zeroization iddiası yoktur; token Vault/backup/preview/log içine yazılmaz.

Aktif Core401 normal account rejection'a ulaşır; emekli eylemden gelen geç401
cancelled olur ve güncel hesabı silemez. Upstream502 Core401 sayılmaz. Açık
permission/not-found başarısızlığı seçenekleri temizler. Sayfalama snapshot ve
cursor'a bağlıdır; filtrelenen room kayıtları dahil toplam512 yüklenen kayıt
sınırı ve monotonic metadata/ACL revision tabanı uygulanır.

## Gerçek sözleşme, runtime RED ve GREEN

`contracts/home-assistant-direct-migration.v1.json` SHA-256:
`8b3c17a461b98db163a265da15248ce29f2ec7228a1d5cc3a5ed796087a43fdb`.
Server'ın15 gerçek HTTP response kaydı değiştirilmedi. Client parity testi
bunlardan14 adapter isteğini MockClient ile oynatır; değişmiş-body confirm'i
HTTP'den önce yerel olarak reddeder. Request capture'ın çıkardığı token testte
sentetiktir. Bu test, gerçek Client/Server soket yolculuğu veya yeni Server
suite koşumu olarak sunulmaz.

| Checkpoint | Gerçek ölçüm |
| --- | --- |
| `72ff027` → `0938a73` | Eksik public store API: 1 FAIL → 1 PASS; yalnız API varlığı. |
| `a5359e1` → `aea1667` | Gerçek secure MethodChannel: 5 PASS/13 FAIL → 18 PASS. |
| `b9b675a` → `ec0adf0` | Typed adapter ve hata eşleme: 11 FAIL → 11 PASS. |
| `2fbb808` → `acaae14` | Mounted controller: ilk boş yükleme 2 PASS/4 FAIL → 6 PASS. Sonraki fault adımlarının ilk RED'de tamamı çalıştığı iddia edilmez. |
| `5fff0a2` → `fac321d` | Gerçek HomeSource/PIN girişinin eksikliği: 1 FAIL → 1 PASS. |
| `41a25ac` → `3ae9984` | Window girişleri ve parent/root preframe401: 20 PASS/4 FAIL → 24 PASS. |
| `68d5e29` → `3a54441` | Boş SettingsSection, permission sonrası etiketler ve filtrelenen room sayfalama: 16 PASS/3 FAIL → 19 PASS. |

Eksik generated l10n, fixture JsonCodec adı, fixture requestId eşleşmesi,
fixture owner teardown'ında pending timer ve SemanticsHandle dispose sırası
ürün kusuru sayılmadı. Bunların başarısız logları korunur; kontrollü runtime
RED tekrarları yukarıdaki tabloda ayrıdır. Son analyzer'daki test-only eksik
brace düzeltildi; genel assertion veya timeout gevşetilmedi.

## Son yerel doğrulama

- Son own focused: **92 PASS**, yaklaşık7s; gerçek store/platform, mounted
  provider, gerçek HomeSessionScope/SettingsGate/PIN ve bounded HTTP fixture.
- Son ilgili regresyon: **599 PASS**, yaklaşık58s. Own92 ile toplanmaz.
- Analyzer: **6 item, 0 issue**. Formatter: **20 file, 0 değişiklik**.
- Altı yeni modülün Dart satır kapsamı: **767/800 = %95,88**. Her yeni modül
  %80'in üzerindedir; branch coverage veya bütün uygulama coverage iddiası yoktur.
- EN/TR ×320/600/1280,2x metin: altı gerçek-font tablet/DeX pencere testi.
  Effective, parent'a merge olmayan button semantics'te en az48×48 ve tek tap;
  gerçek Tab/Shift-Tab, Enter iptal ve Space onay, viewport içinde focus ring
  ve boyalı kontrast ölçümleri vardır. Inline onay iptali sıfır confirm etkisi;
  normal onay tek POST üretir. Tutulan/örtülen/idle/native-focus callback'ler
  ve geç401 ile provider reparent negatifleri ayrıca çalışır.

Özel QA görüntüleri `/private/tmp/larenor-ha-transfer-qa/` altındadır.
`transfer-tr-600-2x.png` (koyu) ve `transfer-en-1280-2x.png` (açık) gerçekten
incelendi: sarılan metin ve odak çizgisi görünür, token/URL yoktur. Bunlar
README galerisi, gerçek TalkBack, fiziksel DeX veya genel son tasarım kabulü değildir.

Bütün SDK komutları `/private/tmp/larenor-flutter-check.py` ile serialize edildi.
Özel son loglar `larenor-ha-transfer-focused-final.log`,
`larenor-ha-transfer-related.log`, `larenor-ha-transfer-analyze-freeze.log`,
`larenor-ha-transfer-format-freeze.log`; coverage `larenor-ha-transfer-final.lcov.info`.
Tam SHA, log hash'leri, süreç reap ve korunma kanıtı
`/private/tmp/larenor-direct-ha-migration-client-delivery-evidence.json` içindedir.
Main, queue, push, CI ve gerçek ev işlemleri bu Client dalında yapılmadı.
