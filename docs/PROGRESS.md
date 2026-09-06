# Larenor — güncel ilerleme ve iş kuyruğu

**Son güncelleme: 6 Eylül 2026, 07:38 (Türkiye saati).**

```text
Önceki kapsam       █████████████░░░░░░░  ≈ %65
S06 koordinatörü    ███████░░░░░░░░░░░░░  2/6 yazılım dilimi; test/yayın geçti
S06.3 kaynak temeli  █████████████░░░░░░░  4/6 alt adım; Linux CI ile kabul
Yeni 63 özellik     ░░░░░░░░░░░░░░░░░░░░  0/63 kabul edildi
Genişletilmiş toplam                     Henüz hesaplanmadı
```

**İlk 60 özelliğin tamamı ve ardından VNC/RDP/SSH seçildi: toplam 63.**
[Bağımlılıklara göre uygulama sırası](feature-expansion-plan-2026-09-05.md)
11 teslim grubunu, mevcut S06–S09 temellerini ve her özelliğin kabul koşulunu
gösterir. 0/63, yeni özelliklerin henüz tamamlanma kabulü almadığını belirtir;
kullanıcı seçimi 63/63'tür. [Uzak erişim](remote-access-plan-2026-09-05.md)
Proxmox'tan bağımsız IP/alan adı eklemeyi kapsar; oturumlar Client'ta,
isteğe bağlı ortak profil/şifreli kayıt Core'da tutulur.
Mevcut kodla örtüşen işler yeniden yazılmayacak.

**Yaklaşık %65 yalnız önceki kapsamın tahminidir.** Önceki kapsamda S06 gerçek
kurulum, S07–S09, ileri kiosk/kamera, son tablet tasarımı ve fiziksel kabul
kalmıştı. Bu oran test kapsamı veya cihaz uyumluluk oranı değildir. Yeni 63
paketin eforu ayrıntılandıkça genişletilmiş toplam ayrıca hesaplanacak;
eski %35 kalan tahmini yeni toplam için kullanılmayacak.

Bu dosya yapılanları, devam eden işleri ve sıradaki paketleri tek yerde izlemek
içindir. Bütün kalan işler [yürütme kuyruğunda](EXECUTION_QUEUE.md), makinece
doğrulanabilen durum ve bağımlılıklar [JSON kaydında](execution-queue.json)
tutulur. Her doğrulanan dilimden sonra sıradaki uygun yazılım işine geçilir;
yeniden “devam et” talimatı beklenmez. Ayrıntılı kapsam için
[ürün planı](product-implementation-plan-2026-09-05.md),
[Server/Client planı](server-client-architecture-2026-09-05.md) ve
[test matrisi](testing-matrix-2026-09-05.md) kullanılır. Yeni onaylı özellikler
[63 özellik uygulama planında](feature-expansion-plan-2026-09-05.md) izlenir.

GitHub'a gönderilmiş işlerin **anlık CI durumu**
[Actions ekranından](https://github.com/ersingundem/larenor/actions) izlenir.
Bu yerel dosya geliştirme aşamalarında güncellenir; Actions ise çalışan
derlemelerin ve test işlerinin kendi canlı durumunu gösterir.

**Devam mekanizması etkin:** aynı Codex görevindeki “Larenor geliştirme ve
bakım” takibi 15 dakikada bir bu planı, kuyruğu, git durumunu ve yarım kalan
CI işlerini kontrol eder. Aynı iş için ikinci yürütücü başlatmaz; bir sonraki
bağımsız adıma geçer. Günlük depolama temizliği aynı görev içinde, Türkiye
saatinde 03.15 sonrasında günde en fazla bir kez korunur. Bilgisayarın ve Codex
uygulamasının açık, deponun erişilebilir olması gerekir; bu dosyanın kendisi
bir servis değildir. Görev Codex'in zamanlanmış görevler ekranından durdurulabilir.

**Kuyrukta kabul edilen işler: 8/125.** Saf kaynak planı, kalıcı journal,
imaj/journal ve ağ/journal köprüleriyle **S06.3 içinde 4/6 alt adım** kapandı. **S08.1** de
Core/ev bağlamını tokenlarla güvenle bağlama kapsamında tam CI kabulü aldı.
**S08.2** ilk parola/eski Server uyumluluğu da `19dbcbe` tam CI ve APK 91
ile kabul edildi. **S08.3** ev runtime sınırı da `4b98680` tam CI ve APK 94
ile kabul edildi. **S08.4** kalıcı ev kayıt sınırı da `1c2db57` tam CI ve APK100 ile kabul edildi. Bu işler yeni 63 özelliğin kabul sayısı değildir; o sayaç **0/63**. Ana S06
sayacı **2/6** kalır; dizin, kurulum ve gerçek Engine kabulü açıktır.

**Son tam doğrulanmış yayın `a27abea` / APK 101.** Üç CI ilk denemede başarılı:
Core **3.104 PASS / 0 skip**, güvenlik **207 PASS**, Flutter **4.390 PASS**,
JVM **98 PASS**, **4 platform + 9 uygulama = 13 E2E PASS / 89 sıralı faz**.
Tam analiz0; CI formatter895 dosya,0 fark. İmzalı APK tek tam indirmeyle
ayrıca doğrulandı: sürüm `100000101`, kalıcı sertifika, minSdk26,
`debuggable=false`, paket/kaynak/SHA eşleşiyor.
[Android101](https://github.com/ersingundem/larenor/actions/runs/34005590269) ·
[Core](https://github.com/ersingundem/larenor/actions/runs/34005590288) ·
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/34005590189) ·
[APK101 ve teslim kanıtı](client-delivery-101-2026-09-06.md).
Anonim iki mimarili Core yayını da doğrulandı; evde kurulum yapılmadı.

**Bu paketin içeriği:** ACL yönetim ekranı `ab678df`, volume journal
`f9a3faa` ve dokuzuncu Android yolculuğu `1d909b8`.
[Birleşim kanıtı](core-grants-volume-integration-2026-09-06.md).
[Önceki APK100](client-delivery-100-2026-09-06.md) ve S08.4 kabulü korunur.
Yeni paket, aşağıdaki logout ve Unix okuyucusu birleşimidir; kendi CI'si
ayrıca çalışacak. Hazırlanan restore ve kişi sözleşmesi bu pakete eklenmez.

**CI102 sonuçlandı: Core ve güvenlik geçti; Android teslimi durdu.**
Exact `38bc2bc` kaynakta Linux3.203, Flutter4.417, güvenlik207, JVM98 test geçti.
E2E13 PASS/1 FAIL: onuncu logout yolculuğu test verisindeki `ref.id` yerine
`id` okuduğu için mount öncesinde düştü; imzalı APK102 üretilmedi.
[Sonuç ve hata kaydı](client-delivery-102-2026-09-06.md).
Dar fixture düzeltmesi ve aynı HTTP sözleşmesini sınayan host regresyonu
ayrı dalda hazırlanıyor. Son kabul edilmiş Client APK101 olarak kalır.

**S08.5 başladı:** logout'ta başarısız kalıcı silme sonrası eski oturumun geri
kullanılması ve gecikmiş hatanın Core ana ekranında görünmemesi gideriliyor.
Paralelde geri yükleme önizlemesi/onayı, hedef okuma kümesi ve özel journal
aynı işleme bağlanıyor; provider kapanışında açık devir uygulanacak.
[Somut uygulama sırası ve açık sınırlar](client-restore-logout-implementation-plan-2026-09-06.md).
Logout `2911ac9`, **25 odaklı / 1.547 ilgili PASS** ve bağımsız son inceleme
ile yerelde tamamlandı. Volume Unix okuyucusu `0d86fa1` ile ayrı sonraki
`091b2bb` birleşiminde **4.415 tam Client PASS / 5:05**, **3.192 tam Core
PASS / 11 Linux skip / 5:13**, analiz0 ve896dosya biçim farkı0 elde edildi.
[Sonraki birleşim](volume-reader-integration-2026-09-06.md).
Onuncu Android çıkış yolculuğu `0bf1258` ile birleşti: **87 fixture testi**, tam analiz0 ve897dosya biçim kontrolü geçti. Eski9yolculuk/89faz aynen korundu; yeni hedef **14 E2E / 99 faz**. İki yeni host testi önceki tam koşuya dahil değil.
Restore çalışması ve yeni paketin kendi CI kabulü açık. CI101 kaynağına
bu değişiklikler eklenmedi. Ayrı restore dallarında gerçek dosya ve Server
kasası ekranları prepared journal yoluna geçiriliyor; başarısız kurtarma
sonrasında eski ekranların açılması, değişen hedefe yazma ve başka journal'a
müdahale etme sınırları RED→GREEN ile kapatılıyor. Bu dallar henüz birleşmedi.

**S08.6 kişi sözleşmesi yerelde hazır:** ayrı `person` modeli46 yeni/92 ilgili
Server testi ve bağımsız kaynak incelemesiyle geçti. Eski oda/kaynak modeli
aynı kaldı. Kişi oluşturma yalnız ad/sıra kabul eder; hesap, rol, izin veya
HA kişisi bağı yaratmaz. HTTP/şifreli persistence ayrı dalda205 ilgili testle ilerledi; bağlı SQLite nesneleri inceleme bulgusu kapanıyor. Android kişi ekranı açık;
model dilimi CI102'ye dahil değildir.
[Model kanıtı](home-people-contract-implementation-2026-09-06.md).

**S08.4 kabul edildi:** üç madde ve 22 kayıt sınıfı exact `1c2db57` kaynağında
bağımsız son inceleme + CI/APK100 ile doğrulandı.
[İnceleme](client-boundary-acceptance-review-2026-09-06.md).
Önceki 31 alt dilim ve kapanış öncesi 14 kanıt, başarısız Android97 dahil
[özgün arşivde](client-boundary-evidence-archive-2026-09-06.json) ve
[kapanış arşivinde](client-boundary-completion-archive-2026-09-06.json) korunur.

## Önceki checkpoint notları

Aşağıdaki sonuç ve “açık/bekliyor” ifadeleri ilgili eski kaynağın tarihsel
snapshot'ıdır. Güncel kabul, sıradaki paket ve aktif işler yukarıda gösterilir.

**Önceki tam doğrulanmış yayın `4bc79dc` / APK 99.** Üç CI başarılı:
Core **2.951 PASS**, güvenlik **207 PASS**, Flutter **3.941 PASS**, JVM
**98 PASS**, **4 native + 7 uygulama = 11 E2E PASS**. Analiz sıfır bulgu,
860 dosyada sıfır biçim farkı. 65 E2E fazı sıralı tamamlandı.
[Android](https://github.com/ersingundem/larenor/actions/runs/34002121963) ·
[Core](https://github.com/ersingundem/larenor/actions/runs/34002121806) ·
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/34002121729).
[İmzalı APK 99](https://github.com/ersingundem/larenor/actions/runs/34002121963/artifacts/9980085515)
tek tam indirme sonrası Java 17 + sabit apksig ile ayrıca doğrulandı:
kalıcı sertifika, kaynak commit, paket `com.ersingundem.larenor`, sürüm kodu
`100000099`, minSdk 26 ve `debuggable=false` eşleşti. APK SHA-256:
`099476a93aa3492c8c4aae283be8868d3c536f448ddcfecdab9c9b980a93b396`.
İki mimarili Core yayını anonim doğrulandı. Ev Core'una yayın ve cihaz
kurulumu yapılmadı. [Teslim kanıtı](client-delivery-99-2026-09-06.md).
Sonraki yerel paketler için yeni birleşik test ve CI ayrıca gerekir.

**Önceki tam doğrulanmış yayın `a2658ec` / APK 98.** Linux Server **2.919 PASS**,
güvenlik **207 PASS**, Flutter **3.422 PASS**, JVM **98 PASS**, temiz analiz,
845 dosyada sıfır biçim farkı ve **dört native + yedi uygulama = 11 E2E PASS**.
Eski scoped-layout fixture düzeltmesi gerçek Android akışını geçti. Üç workflow
ilk denemede başarılı; başarısız Android 97 kaydı aşağıda korunuyor.
[Android 98](https://github.com/ersingundem/larenor/actions/runs/34000029533) ·
[Server](https://github.com/ersingundem/larenor/actions/runs/34000029460) ·
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/34000029415).

[İmzalı APK 98 ve metadata](https://github.com/ersingundem/larenor/actions/runs/34000029533/artifacts/9979498174)
tek tam indirmeyle Java 17 ve sabit apksig 9.1.0 üzerinden ayrıca doğrulandı:
`com.ersingundem.larenor`, `1.0.0` / `100000098`, minSdk 26,
`debuggable=false`, kalıcı sertifika ve kaynak commit eşleşiyor. APK SHA-256:
`eac472cec2a0e9de02a2df6f1f78876ae5e4dc9c56ef7e9440fe1691690586ae`.

İki mimarili Core **hazırlık** smoke'u ve anonim kaynak/AGPL etiketli yayın
geçti: `sha256:ed365020ea6bf38200beaa8a73627111a27a87c54124f6cd30bbd234bc846410`.
Ev Server'ına yayın atlandı, cihaz kurulumu yapılmadı. Aşağıdaki yeni yerel
paketler bu APK'da bulunmaz; kendi birleşik testleri ve CI ayrıca gerekir.

**`4bc79dc` ile gönderilen birleşim:** kişisel sağlık/fotoğraf ayarları,
Jellyseerr/Bazarr/Prowlarr ve qBittorrent paketleri bağımsız incelemelerden
geçti. İlk birleşik koşu **3.665 PASS / 5 FAIL** verdi; beş hata idle testinin
eski yerel depolama hazırlığındaydı. `1b2d7d3`, gerçek gizlilik sağlayıcılarını
bekleyen test düzeltmesiyle **23/23 PASS** verdi. Ardından gerçek native
pencere odağı açığı `729d96d` ile düzeltildi: **26 odaklı / 252 ilgili PASS**,
arka plan müziği korunuyor. Son birleşik koşu `1b260ce`: **3.923 PASS / bir eski test taklidinde derleme hatası**, 4:15. `ad5f866` yalnız bu taklidin yeni Proxmox imzasını düzeltti; aynı sistem ekranının **18 testi geçti**, bağımsız inceleme temiz. Tam analiz sıfır bulgu; 860 dosyada biçim farkı yok. Bu, tek koşuda tam yeşil yerel sonuç diye sayılmıyor; yeni CI tam paketi sınayacak.
[Odak kanıtı](application-window-focus-implementation-2026-09-06.md).

**Birleşime alınan bağlantılar:** Jellyfin 98 yeni/297 ilgili, Proxmox 213 odaklı/665 ilgili test ve bağımsız inceleme ile tamamlandı. Keenetic sonraki ayrı pilotta. Jellyfin'de
başarısız credential yazısının eski doğrulanmış bağlantıyı bırakması düzeltildi;
aynı durum yedi API-key bağlantısında 370 ilgili test ve bağımsız incelemeyle düzeltildi. Dashboard WebviewTile için kaynak sahipliği düzeltmesi `0a742a9` ayrı yerel diliminde **79 ilgili test** ve bağımsız inceleme ile geçti; yeni yayın paketine henüz dahil değil. Bu incelemeler tüm
entegrasyon API'lerinin veya fiziksel cihazların kabulü değildir.

**Yeni yerel birleşim hazırlanıyor:** Keenetic kayıt/PIN/kurtarma pilotu
`dc87062` **1008 ilgili PASS**, Wi-Fi/cihaz/port ekranı koruması `74e3f44`
**1047 ilgili PASS** ve bağımsız inceleme ile tamamlandı. Dashboard WebView,
Core yönetim ekranı ve volume gözlemi aynı sonraki pakete alındı.
[Birleşim kanıtı](core-client-integration-2026-09-06.md) tam test/CI aşamasını izler.
`8d9e4d2` birleşik üretim/test kaynağı **4.271 Client testi / 4:48** ile geçti;
207 güvenlik/CI araç testi ve backup/CI politika kontrolü de temiz. Tam Server
**3.040 PASS / 10 Linux'a özgü skip / 8:17,88** verdi. Tam analiz 0 bulgu,
878 dosyada biçim farkı yok. Sonraki `bb6ed4e` birleşimi sekizinci Android
metadata yolculuğunu ekledi: tüm fixture klasörü **48 PASS**, tam analiz
0 bulgu ve **881 dosyada sıfır biçim farkı**. Yeni CI hedefi 4 native +
8 uygulama = **12 E2E**; Linux'a özel testler ve yeni Android yolculuğu
gerçek CI sonucu gelmeden kabul edilmiş sayılmaz.
[Sekizinci yolculuk](core-resource-admin-android-journey-2026-09-06.md).
Core metadata mutasyon API'si `8e00548` yerel dalında **87 odaklı / 656 ilgili
Client ve 40 Server testi**, temiz analiz ve bağımsız inceleme ile doğrulandı.
Bu API'nin PIN korumalı oluşturma, ad/sıra değiştirme ve kayıt silme UI'si
`68e77b8` yerel diliminde **431 ilgili test**, temiz analiz, 12 tablet/DeX
boyut-tema-dil kontrolü ve bağımsız inceleme ile geçti. Yeni Android E2E
yolculuğu birleştirildi; bu UI henüz APK 99'da değildir. ACL editörü ve gerçek cihaz komutları
ayrı açık işlerdir. Kuyrukta kabul sayısı bu alt dilimler için artırılmadı.

**Kaynak erişimi API'si yerel olarak doğrulandı:** `a65691d`, gerçek Core
grant/no-op/revoke yanıtlarını Client'a bağlar; **53 odaklı / 709 ilgili Client,
131 ilgili Server PASS**, yeni 108 satırın tamamı testte, bağımsız inceleme
temiz. Kullanıcı seçimi ve ACL yönetim ekranı ayrı dalda geliştiriliyor.
[Sözleşme kanıtı](core-home-resource-grants-contract-2026-09-06.md).

**S06.3d depolama alternatifi:** Core'a ait yönetilen volume önerisi saf plan
olarak eklendi: **32 yeni / 182 ilgili PASS**, modülde dal dahil %100 kapsam,
bağımsız kaynak incelemesi temiz. Henüz Engine'e veya HTTP kurulum yoluna
bağlanmadı; `installAvailable=false` sürer. Sahiplik gözlemi, kalıcı journal,
UID/bootstrap ve gerçek kurulum etkileri açıktır.
[Değerlendirme](managed-volume-storage-assessment-2026-09-06.md) ·
[Uygulama kanıtı](managed-volume-proposal-implementation-2026-09-06.md).

**Volume gözlemi sonraki yerel birleşime alındı:** `4baa55a`, yedi managed
hedefi tam plan/kimlik/etiketlerle eşleştiren katı Engine yanıt denetimini
ekler. **95 odaklı / 282 ilgili test**, 124 satır ve 24 dalda %100 kapsam;
bağımsız inceleme temiz. Host dizini açılmaz ve gözlem kurulum yetkisi sayılmaz.
Kalıcı volume journal'ı, gerçek bootstrap ve Engine işlem bağlantısı açık.
[Gözlem kanıtı](managed-volume-observation-implementation-2026-09-06.md).

**Sonraki bağımsız volume journal paketi hazır:** `codex/managed-volume-journal`
dalı `f9a3faa` checkpoint'inde **54 odaklı / 273 ilgili PASS** ve bağımsız
inceleme ile donduruldu; yeni modül 139 satır ve 8 dalda %100 kapsamda.
Bu dal yukarıdaki tam Server koşusuna veya mevcut yayına dahil değil.
Yalnız gözlem geçmişini saklar; Engine/bootstrap ve kurulum yetkisi açık.

**S08.4 kabul incelemesi tamamlandı:** üç kabul maddesi ve 22 kayıt sınıfı
kaynak/test kanıtlarıyla eşleştirildi; yeni somut P1/P2 bulunmadı. Yeni paketin
kendi CI kapısı geçince bu adım kapanabilir. Restore S08.5 ve typed
adaptör/cache S08.7–9 ayrı kalır.
[İnceleme](client-boundary-acceptance-review-2026-09-06.md).

S08.4'ün önceki 31 ayrıntılı kanıt kaydı
[özgün kayıt arşivinde](client-boundary-evidence-archive-2026-09-06.json)
aynen korunur. Yürütme kuyruğu yerel test/inceleme özetlerini buraya bağlar;
başarılı ve başarısız CI kayıtları kuyrukta da kalır. Bu düzenleme kabul
sayılarını veya tarihsel test sonuçlarını değiştirmez.

**6 Eylül günlük depolama bakımı tamamlandı:** bir eski debug APK çıktısı,
**129.424.470 bayt** temizlendi. En yeni üç debug APK korundu; imzalı çıktılar
ve test raporları silinmedi. Sonraki envanter silinen kaydın yokluğunu ve
korunan üç kaydı doğruladı. GHCR paket izni olmadığından imaj temizliği yapılmadı.

**Önceki tam doğrulanmış yayın `8c3b60d` / APK 96: üç CI ve bağımsız APK kontrolü başarılı.**
Linux Server **2.916 testi atlamasız**, Flutter **2.989**, JVM **98** ve
**dört native + altı uygulama = 10 E2E** geçti. Güvenlik CI 207 testi ve
secret taramasını geçti. Yeni Core login/PIN/oda kopyası/remount/başka Core
akışı gerçek Android CI'da doğrulandı. 57 faz, altı temizlik; E2E komutu
322,195 saniye, 18 dakika sınırında 757,805 saniye pay var.
[Android 96](https://github.com/ersingundem/larenor/actions/runs/33995289219) ·
[Server](https://github.com/ersingundem/larenor/actions/runs/33995289140) ·
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33995288940).

AMD64/ARM64 Core medya **hazırlığı**/restart/iptal smoke'u ve anonim yayın
başarılı: `sha256:d3a2b48c07634be20c59b14e2a84b2b6f3e89e69c1094205f4e7f7be3355c027`.
Bu kontroller gerçek medya bileşeni veya ev kurulumu değildir.

[İmzalı APK 96 ve metadata](https://github.com/ersingundem/larenor/actions/runs/33995289219/artifacts/9978185451)
tek tam indirmeyle Java 17 + sabit apksig 9.1.0 kullanılarak ayrıca doğrulandı:
`com.ersingundem.larenor`, sürüm kodu `100000096`, minSdk 26,
`debuggable=false`, kalıcı sertifika ve kaynak commit eşleşti. APK SHA-256:
`1017d1405d4127dbed241a4957826ab6660b4fc2185c33d57bb334e5dba2a5c8`.
Ev Server'ına koşullu Client yayını atlandı; ev/tablet kurulumu yapılmadı.

**Yeni birleşik teslim `27def3d`:** Arr/backup ve eski Core fixture düzeltmesi ana dalda.
`7f9a74f` üzerinde tam Client **3.421 PASS / 4:00**, tam analiz temiz,
845 dosyada biçim kontrolü sıfır değişiklik. Ardından eklenen tek fixture testi
ve genişletilen senaryo `27def3d` üzerinde **18 son destek testi**, dört dosyada
temiz analiz/biçim ile doğrulandı. Kaynak incelemesi temiz. Yeni Android/Core
CI üstteki Android 98 kaydında geçti; bağımsız imzalı APK 98 kontrolü de geçti.
[Fixture düzeltmesi](core-resource-fixture-compat-2026-09-06.md).

**Kaynak ekranı paketi `808938e`:** diafon/film gecesi kaynak sınırı, Core'un
salt okunur oda/kaynak ekranı ve yeni yedinci Android yolculuğu birleştirildi.
Birleşik yerel Client **3.115 testi 3:40 içinde geçti**; tam analiz sıfır
bulgu, 838 dosyada biçim kontrolü sıfır değişiklik. Gerçek Server ortak
kaynak sözleşmesi üç testi, kuyruk doğrulaması 24 testi geçti. Bu yeni
ekran/yolculuk APK 96'da yoktur; yeni CI ve imzalı APK kabulü ayrıca izlenecek.

**`20d92d7`: Core ve güvenlik geçti; Android 97 başarısız, APK üretilmedi.** [Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33997176904)
207 testi ve secret taramasını geçti. [Android 97](https://github.com/ersingundem/larenor/actions/runs/33997176965)
içindeki Server işi 2.919, Flutter 3.115, JVM 98 testi geçti.
E2E: dört native ve altı uygulama senaryosu geçti; eski scoped-layout senaryosu
son temizlikte dört reddedilen istek nedeniyle durdu. Yeni kaynak ekranının
yedinci uygulama senaryosu geçti. Eski admin test sunucusunda görünür ekranın
oda/kaynak GET desteği eksikti; `1f7c6b4` bu eski kullanıcı/rolü değiştirmeden
aynı kapsama ait boş liste yanıtını ekler. İstek/yetki/temizlik kontrolleri korunur.
Bu düzeltmenin Android 98 E2E kabulü geçti; imzalı APK 98 kontrolü de geçti.
[Core imajı](https://github.com/ersingundem/larenor/actions/runs/33997176958)
ilk denemesinde 2.918 PASS ve bir Unix test düzeneği kapanış zaman aşımı var.
İlk hata kaydı korunarak yalnız başarısız iş bir kez yeniden çalıştırıldı;
ikinci deneme **2.919 test ve imaj işlerinde başarılı**. İlgili dokuz intent-değişimi senaryosu
yerelde 20 ayrı koşuda, toplam 180 çalıştırmada geçti. Bu tekrarlar ilk Linux
hatasının sebebini kesinleştirmez veya onun yerine geçmez.

**Sıradaki birleşik paket `e4f0f15` ana dala alındı:** dört Arr bağlantısı
ve yedek sınırı **3.418 tam Client testi**, temiz analiz ve 845 dosyada sıfır
biçim değişikliğiyle doğrulandı. Bağımsız incelemeler temiz. Önceki yayının
eksik Android kapısı düzeltilirken Jellyseerr/Bazarr/Prowlarr, qBittorrent ve kişisel sağlık/fotoğraf
kayıtlarının sınırları ayrı dallarda ilerliyor. Bu paketler henüz CI kabulü almadı. Kişisel kayıt paketi `4eac0f6` 253 ilgili
test ve bağımsız incelemeyle sonraki birleşim için hazır; diğer iki pilotun
son UI/inceleme işleri devam ediyor.

<details>
<summary>Önceki tam doğrulanmış yayın: 394de0f / APK 95</summary>

**Önceki tam doğrulanmış yayın `394de0f` / APK 95: üç CI ve bağımsız APK kontrolü başarılı.** 2.792 Linux Server testi
atlamasız, 2.837 Flutter, 98 JVM, dört native + beş uygulama = dokuz E2E ve
207 araç testi geçti. Yeni gerçek Linux tam kök/proc/mount/descriptor fixture'ı
0,204 saniyede geçti. Android akışı 260,80 saniye; Gradle ağır derlemesi cihaz
başlatılmadan önce tamamlandı. İmzalı APK 95, Java 17 ve sabit apksig 9.1.0
ile ayrıca doğrulandı.
[Android](https://github.com/ersingundem/larenor/actions/runs/33991460336) ·
[Server](https://github.com/ersingundem/larenor/actions/runs/33991460310) ·
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33991460186).

AMD64/ARM64 Core medya hazırlığı/restart/iptal smoke'u ve anonim yayın
başarılı: `sha256:1dcc66fcc964d6f5d1ab6a1d0df653f43d21c7562bb5f19bd098815f89461642`.
Bu kontroller gerçek medya bileşeni veya ev kurulumu değildir.

[İmzalı APK 95 ve metadata](https://github.com/ersingundem/larenor/actions/runs/33991460336/artifacts/9977060537):
`com.ersingundem.larenor`, sürüm kodu `100000095`, minSdk 26,
`debuggable=false`, kalıcı imza ve kaynak commit eşleşti. APK SHA-256:
`e12a90c81ff1b22ab1bf5dc1ca272dc6675de65dac2587cd311f594f6ce67be1`.
Ev Server'ına koşullu Client yayını atlandı; ev veya cihaz kurulumu yapılmadı.
İlk bağımsız indirme hazırlığı geçici dizin adı hatasıyla 0 bayt yazmadan durdu;
yol düzeltildikten sonra tek tam indirme ve kontrol başarılı oldu.

</details>

<details>
<summary>Önceki tam doğrulanmış yayın: 4b98680 / APK 94</summary>

**Son tam doğrulanmış yayın `4b98680` / APK 94:** üç CI ve bağımsız APK
kontrolü başarılı. **2.704 Linux Server testi atlamasız**, 2.815 Flutter,
98 JVM, **dört native + beş uygulama = dokuz E2E** ve 207 araç testi geçti.
[Android](https://github.com/ersingundem/larenor/actions/runs/33989941216) ·
[Server](https://github.com/ersingundem/larenor/actions/runs/33989941147) ·
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33989940928).

Yeni Direct → Core → Direct yolculuğu eski HA bağlantısının kapanmasını ve
açık seçimden sonra yeni abonelik kurulmasını doğruladı. 48 faz, beş temizlik;
E2E komutu 242,584 saniye, 18 dakika sınırında 837,416 saniye pay var.
Emülatörden önce Gradle 331 saniye; cihaz açıkken 20,6/31,2 saniye.
Native odak geçti; önceki Quickstep hatası bu koşuda görülmedi.

AMD64/ARM64 Core restart, medya **hazırlığı** ve iptal smoke'u; anonim
commit/stable/index ve iki mimarinin kaynak/lisans kayıtları doğrulandı:
`sha256:8df10dcadb6f97db17eabbf41fc566c394b45a9b0161227f5107673a348bb19b`.
Gerçek medya bileşeni kurulumu bu smoke kapsamında değildir.

[İmzalı APK 94 ve metadata](https://github.com/ersingundem/larenor/actions/runs/33989941216/artifacts/9976632723)
Java 17 + sabit apksig 9.1.0 ile ayrıca doğrulandı: doğru paket/sertifika,
`100000094`, minSdk 26, `debuggable=false`, kaynak commit ve metadata eşleşti.
APK SHA-256: `44d505607e282ff23bb24ffeb349dd12f5e71ea6533d5be6db65812f3a3f6bbf`.
Ev Server'ına koşullu Client yayını atlandı; ev/cihaz kurulumu yapılmadı.

</details>

- **S08.3 ev kaynak sınırı kabul edildi:** `10d3eb1` → `4ba7024`; açık, kalıcı doğrudan
  HA/Core seçimi ve bağımsız ev runtime'ı. Eski evin route/WS/callback'leri
  kapanır; hesap, PIN, tema ve güç ayarları ortak sahiplikte kalır. Core
  adaptörleri hazır olmadan eski yerel HA/medya verisi Core ekranına sızmaz.
  50 odaklı ve 1.093 ilgili test, %99,2 yeni modül satır kapsamı ve bağımsız
  inceleme geçti. Yeni beşinci uygulama akışıyla **dokuz E2E ve imzalı APK 94**
  `4b98680` kaynağında doğrulandı. [Uygulama kanıtı](client-home-session-scope-implementation-2026-09-05.md).
- **B5.1 dashboard:** `5cf7f30` → `8cc4665`; kartlarda Tab/Enter/Space,
  menü tuşu, tekil ekran okuyucu duyurusu ve görünür odak. Servis kartları
  gizli/eski oturumdan sayfa açamaz; termostat ok tuşlarıyla ayarlanır.
  343 dashboard ve 49 son delta testi, kapsam %88,1, scoped analiz ve
  bağımsız inceleme ve `4b98680` Android/yayın CI geçti. Genel B5.1 ve ayrı
  fiziksel TalkBack kabulü açık.
  [Uygulama kanıtı](tablet-dashboard-accessibility-implementation-2026-09-05.md).

Yeni birleşimde ilk yerel test başlangıcı eski üretilmiş çeviri dosyaları
nedeniyle durduruldu; kaynak üretimi ve çeviriler yenilendikten sonra tam
Client suite **2.815 testi 3:46 içinde geçti**. Bu hazırlık hatası başarı olarak sayılmaz.
Bu hazırlık düzeltmesinden sonra aynı kaynak uzak CI ve APK 94 kabulünü de geçti.

**Yeni CI ile doğrulanan paket (`14b7b62` → `394de0f`):** appdata tam kök gözlemi ve medya posterleri
birleşti. Medya kartları native klavye odağına sahip; 2× başlık satırı gerçek
ızgara genişliğine göre hesaplanıyor. 733 ilgili/22 son test, %92,5 ilgili
satır kapsamı, bağımsız kod ve açık/koyu gerçek-font görsel incelemesi geçti.
Tam Client **2.837 testi 4:04 içinde geçti**; analiz sıfır bulgu, 803 dosyada
biçim kontrolü sıfır değişiklik. Aynı üretim kaynakları yeni `394de0f`
Android CI içinde 2.837 Flutter, 98 JVM ve dokuz E2E ile doğrulandı. [Medya kanıtı](tablet-media-accessibility-implementation-2026-09-05.md).

**Sıradaki bağımlı çalışma:** S06.3d'de salt okunur native kimlik gözlemi
`3dde2f8` Linux CI ile doğrulandı. Onaylı tam appdata kökünün bütün parent/name/descriptor bağlarını tutan
resolver `32254ad` → `0d9e250` main içinde. 87 odaklı/573 ilgili test ve
bağımsız inceleme geçti. Tam Server **2.782 geçti, 10 Linux testi Mac'te
atlandı** (3:20,8). Ardından `394de0f` Linux CI **2.792 testi atlamasız**
geçti; yeni gerçek kök fixture'ı doğrulandı. Supervisor,
remap-disabled başlangıç kanıtı, issuer ve create/publish hâlâ açık.
[Native kimlik](native-identity-observation-implementation-2026-09-05.md) ·
[Kalan sıra](appdata-native-lease-plan-2026-09-05.md).
S08.3 kabulüyle başlangıç bağımlılığı açılan [kapsamlı düzen deposu ve açık taşıma](client-scoped-storage-plan-2026-09-05.md)
ilk dilimi `3018c57` → main `fd23a3f` içinde. Core/ev/kullanıcıya ayrı kayıt,
PIN korumalı önizleme ve seçili pasif oda adlarının kopyası eklendi.
93 son test, %96,9 ilgili satır kapsamı, bağımsız inceleme ve dört gerçek-font
görsel kontrolü geçti. `115dfa1` altıncı Android yolculuğu da birleşti;
`fd23a3f` üzerinde tam Client **2.914 test**, temiz analiz ve 814 dosyada
biçim kontrolü geçti. Bu altıncı Android yolculuğu `8c3b60d` ve APK 96 ile CI kabulü aldı.
[Diğer kayıtların envanteri](client-record-ownership-2026-09-06.md) çıkarıldı.

**S08.4 HA ve yedek sınırı ana dalda:** `d8edab5` ve `9b11195` → `7ed736b`.
Gerçek HA provider/store ve EnabledServices seed erişimi Direct kaynak
sahipliğine bağlı; Core veya eski callback sır okuma, kayıt veya HA transport
oluşturamaz. Yarım HA adres/token kaydı kalıcı bir işaretle durur; yalnız açık,
tam yeniden bağlantı veya silme bu belirsizliği kapatır. Böyle bir çift yeni
yedeğe/restore hazırlığına giremez; mevcut journal kurtarması çalışır ve işareti
silmez. Direct paketinde 53 son/482 ilgili test ve %99,5 satır kapsamı;
yedekte 40 son/143 ilgili test, repository %98,2 ve ekran %94,4; bağımsız
incelemeler ve analizler temiz. Toplamlar birbirine eklenmez. `7ed736b`
birleşik Client **2.989 testi 3:58 içinde geçti**; analiz sıfır bulgu,
820 dosyada biçim kontrolü sıfır değişiklik. Aynı dilimler `8c3b60d`
2.916 Linux, 10 E2E ve APK 96 ile de geçti. Bütün S08.4 kabulü açık.
[Direct kanıtı](direct-home-boundary-implementation-2026-09-06.md) ·
[Yedek kanıtı](ha-backup-boundary-implementation-2026-09-06.md).
**Diafon/film gecesi sınırı da `cc3db2` → main `cc0d89d` içinde:**
eski kaynak callback'leri kayıt yapamaz, kapı komutu veya film akışı
başlatamaz. 542 ilişkili test, %86,2 ilgili satır kapsamı, temiz analiz
ve bağımsız inceleme geçti. `808938e` birleşik Client 3.115 testi ve analizi
geçti; yeni CI kabulü açık.
[Kanıt](direct-home-routines-implementation-2026-09-06.md).
Sıradaki pilot ortak credential kayıt sınırıyla Sonarr/Radarr/Lidarr/Readarr
bağlantılarıdır; çok alanlı kayıt belirsizliği ve yedek kontrolleri birlikte
tamamlanmadan bu pilot birleştirilmeyecek.

**Paralel S08.6 ana dalda:** Kalıcı, şifreli oda/kaynak/hesap izin kayıtları ve
gerçek authenticated HTTP API `133786e` / belge `1b6b866` ile birleşti.
Üye yalnız izinli kayıtları görür; opak sayfa özeti gizli kayıt hareketlerini
açıklamaz. 124 odaklı test, dal dahil %95 kapsam, bağımsız inceleme ve tam
Server **2.906 PASS / Mac üzerinde 10 Linux skip** geçti. `8c3b60d` Linux CI **2.916 testi atlamasız** ve iki mimarili
imaj kapısını da geçti. Client salt okunur liste ekranı `codex/core-home-resource-list` üzerinde
`73dba35` → main `808938e` içinde. 82 odaklı/940 ilgili test,
%99,2 yeni feature satır kapsamı, 8 gerçek-font tablet kontrolü ve bağımsız
inceleme geçti; `808938e` birleşik Client 3.115 testi ve analizi geçti.
Yeni yedinci Android yolculuğu ve CI kabulü açık.
[Client kanıtı](core-home-resource-list-implementation-2026-09-06.md) ve
[yedinci Android yolculuğu](core-home-resources-android-journey-2026-09-06.md)
yeni teslim kapsamını ayırır. Yönetim ekranı, hane kişi profilleri, değişmez sağlayıcı bağları
ve gerçek cihaz komutları henüz tamamlanmış sayılmıyor.
[Uygulama ve kanıt](home-resource-registry-implementation-2026-09-06.md).

**S08 kabul sırası netleştirildi:** Mevcut kayıt kapsamı S08.4, restore/journal
S08.5, kimlik/yetki S08.6; gerçek HA eşlemesi ve typed cache S08.7, medya
S08.8, altyapı S08.9. Böylece bir adım kendi sonraki adaptörünü bitiş önkoşulu
olarak beklemiyor. Kapsam ve 125 işlik kuyruk korunuyor; kabul sayısı 7/125.

**Yarım çalışmaları kaybetmeden devam:** önce çalışma kopyaları, dallar,
agent ve CI durumları incelenir; aynı iş yeniden başlatılmaz. Tamamlanan
RED/GREEN checkpoint'leri git geçmişinde tutulur; ana dala birleşme uzak CI
kabulü değildir. Geçici çalışma kopyaları kalıcı arşiv yerine geçmez.

| İş | Dal / çalışma kopyası | Durum |
| --- | --- | --- |
| B5.1 tablet ayarları | `codex/tablet-settings-accessibility` | `ba884f6` main içinde; yeni `3dde2f8` sekiz E2E ve Android CI geçti. |
| B5.1 medya posterleri | `codex/tablet-media-accessibility` · `/private/tmp/larenor-tablet-media-accessibility` | `cb792c0` → `14b7b62` main içinde; 733 ilgili/22 son test ve bağımsız görsel inceleme geçti. Tam Client 2.837 test/analiz ve `394de0f` dokuz E2E geçti; bağımsız imzalı APK 95 doğrulandı. |
| B5.1 dashboard | `codex/tablet-dashboard-accessibility` · `/private/tmp/larenor-tablet-dashboard-accessibility` | `5cf7f30` birleşti; `4b98680` tam Android CI ve APK 94 kabulü geçti. |
| S06.3e ağ journal köprüsü | `codex/network-effect-bridge` | `6a00168` main içinde; `9138e61` Server/güvenlik CI ile yazılım kabulü tamamlandı. |
| S08.4 kaynaklı düzen | `codex/client-scoped-layout` ve `codex/scoped-layout-e2e` | `3018c57` ve `115dfa1` ana dalda; 93 son ve 2.914 tam Client testi/analiz geçti. Altıncı Android yolculuğu ve APK 96 `8c3b60d` ile doğrulandı. |
| S08.4 HA ve yedek sınırı | `codex/direct-home-boundary` ve `codex/ha-backup-boundary` | `d8edab5` ve `9b11195` → main `7ed736b`; 53/40 son test ve bağımsız incelemeler temiz. `8c3b60d` 2.989 Flutter/10 E2E ve bağımsız APK 96 kontrolü geçti. |
| S08.4 diafon/film gecesi | `codex/direct-home-routines` | `cc3db2` → main `cc0d89d`; 542 test ve inceleme geçti. `808938e` birleşik Client 3.115 test/analiz geçti; yeni CI açık. |
| S08.4 Arr bağlantıları ve yedek sınırı | `codex/direct-arr-credentials` ve `codex/direct-credential-backup` | 0298c5a ve 6426d55 birleştirildi; 192 odaklı/547 ilgili Arr ve 245 ilgili backup testi, bağımsız incelemeler temiz. e4f0f15 birleşik 3.418 test/analiz geçti; yeni Android düzeltmesiyle CI açık. |
| S08.6 Core kaynak listesi | `codex/core-home-resource-list` ve `codex/core-home-resources-e2e` | `73dba35` ve `c0b765c` → main `808938e`; 82 odaklı/940 ilgili test, tablet QA ve bağımsız inceleme geçti. Birleşik Client 3.115 test/analiz temiz; yedinci Android yolculuğu ve yeni CI açık. |
| S08.6 Core kaynak/yetki kaydı | `codex/home-resource-registry` | `133786e` / `1b6b866` ana dalda; tam Server 2.906 PASS/10 Mac skip, 124 odaklı test, %95 dal kapsamı ve inceleme temiz. `8c3b60d` Linux 2.916/iki mimari geçti. Yeni Client liste/bütün yönetim kabulü açık. |
| S08.3 Client ev runtime'ı | `codex/client-home-session-scope` · `/private/tmp/larenor-client-home-session-scope` | `10d3eb1` birleşti; `4b98680` dokuz E2E ve imzalı APK 94 ile S08.3 kabul edildi. |
| S06.3d appdata tam kök gözlemi | `codex/native-appdata-root-observation` · `/private/tmp/larenor-native-appdata-root-observation` | `32254ad` → `0d9e250` main içinde; `394de0f` gerçek Linux 2.792 test/0 skip ve iki mimarili hazırlık smoke geçti. Salt okunur gözlem yazma yetkisi değildir. |

Ağ yazılımının gerçek Engine/iki mimarili kaynak kabulü **S06.3f** içindedir.
Production dispatcher/host grant, appdata oluşturma ve medya kurulumu açık;
`installAvailable=false` değişmedi.

<details>
<summary>Önceki doğrulanmış yayın: 3dde2f8 / APK 93</summary>

**Önceki tam doğrulanmış yayın `3dde2f8` / APK 93:** Server, Android ve güvenlik başarılı.
Linux **2.704 test atlamasız**, 2.739 Flutter, 98 JVM, dört native + dört
uygulama E2E senaryosu ve 207 araç testi geçti. İndirilen APK 93, Java 17 +
sabit apksig 9.1.0 ile ayrıca doğrulandı: doğru paket/sertifika, `100000093`,
minSdk 26, `debuggable=false`, kaynak commit ve metadata eşleşti.
[İmzalı APK 93 ve metadata](https://github.com/ersingundem/larenor/actions/runs/33988283337/artifacts/9976135162).
APK SHA-256: `b9582694525493255641ab172aa90630d114ed88218a821accff5556f3695065`.
[Server](https://github.com/ersingundem/larenor/actions/runs/33988283387) ·
[Android](https://github.com/ersingundem/larenor/actions/runs/33988283337) ·
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33988283178).

AMD64/ARM64 Core restart, medya **hazırlığı** ve iptal smoke'u geçti; anonim
commit/stable/index ve iki mimarinin kaynak/lisans kayıtları doğrulandı:
`sha256:e77b7a11907ac009d8000ec374fcb94745614602331c9da307d41ca97fb895d6`.
Gerçek medya bileşeni kurulumu bu smoke kapsamında değildir; ev Server'ına
koşullu Client yayını atlandı, ev/cihaz kurulumu yapılmadı.

**Emülatör hazırlığı gerçek CI'da doğrulandı:** ağır derleme emülatörden önce
403 saniyede tamamlandı. Emülatör açıkken ilk Gradle derlemesi önceki koşudaki
363,9 saniyeden 23,9 saniyeye indi; ikinci derleme 36,0 saniye. Test komutu
231,793 saniye sürdü; 42 aşama ve dört temizlik tamamlandı. Native odak testi
geçti. Bu tek koşu, önceki Quickstep ANR'nin kesin kök nedenini veya kalıcı
çözümünü kanıtlamaz; toplam CI aynı oranda hızlanmış değildir.
[Ölçüm ve sınırlar](android-e2e-precompile-2026-09-05.md).

</details>

<details>
<summary>Önceki koşu: 9138e61 Core kabulü, Android 92 hatası</summary>

Linux 2.566 test atlamasız, iki mimarili Core hazırlık/restart/iptal ve
güvenlik kontrolleri geçti; bu backend kanıtıyla **S06.3e** kabul edildi.
[Server](https://github.com/ersingundem/larenor/actions/runs/33986835291) ·
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33986835178).
İmaj `sha256:7902dc0fcf299c0b2b7e598943a6293c8af6e5e60efd0e13f1f27ac28216d805`.

[Android 92](https://github.com/ersingundem/larenor/actions/runs/33986835301)
2.739 Flutter, 98 JVM ve dört uygulama akışını geçti. Quickstep ANR nedeniyle
native odak testi başarısız oldu: E2E 7/8, imzalı APK 92 üretilmedi.
QEMU/adb canlı, ekran uyanık ve kilitsizdi; OOM veya emülatör çökmesi
kanıtlanmadı. 673,224 saniye, 42 aşama ve dört temizlik kaydedildi.

</details>

<details>
<summary>Önceki doğrulanmış yayın: 19dbcbe / APK 91</summary>

**Önceki tam uzak yayın `19dbcbe`:**
[Server](https://github.com/ersingundem/larenor/actions/runs/33985459924),
[Android](https://github.com/ersingundem/larenor/actions/runs/33985459959) ve
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33985459857)
**imzalı APK 91 dahil başarılı**. **2.298 Linux Server testi atlamasız**;
2.701 Flutter, 98 JVM, sekiz emülatör senaryosu ve 202 araç testi geçti.
Linux'un unread Unix stream reset davranışı ve iki iptal/kapanış varyantı
ayrıca geçti; önceki `54a677b` hatası kapandı. Emülatör 9:34,4 ile 18 dakika
sınırında; 42 aşama ve dört tamamlanmış temizlik var.

AMD64/ARM64 Core restart/medya hazırlığı/iptal smoke'u ve anonim
commit/stable/index/child/sourceRevision doğrulaması geçti:
`sha256:9867d551fb10cf141bc513569eab523162485eb04caaa181abd06249a840b8cd`.
[İmzalı APK 91 ve metadata](https://github.com/ersingundem/larenor/actions/runs/33985459959/artifacts/9975280844)
Java 17 + sabit apksig 9.1.0 ile ayrıca doğrulandı: doğru paket/sertifika,
`100000091`, minSdk 26, `debuggable=false`, kaynak commit ve metadata eşleşti.
APK SHA-256: `caf77a39de2586b1250c3dcf1ebe3cbd2a3b66f4a73f3b1342b28e7319ccc498`.
Ev Server'ına koşullu Client yayını atlandı; ev/cihaz kurulumu yapılmadı.
Bu kanıt sonraki kaynak değişikliklerini kapsamaz.


</details>

<details>
<summary>Önceki doğrulanmış yayın: 1408e80 / APK 89</summary>

**Son tam uzak yayın `1408e80`:**
[Server CI](https://github.com/ersingundem/larenor/actions/runs/33982544738),
[Android CI](https://github.com/ersingundem/larenor/actions/runs/33982544696) ve
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33982544575)
**imzalı APK 89 dahil başarılı**. 2.092 Linux Server testi atlamasız;
2.678 Flutter, 98 JVM, sekiz emülatör senaryosu ve 202 araç testi geçti.
Üç gerçek Linux peer/mount vakası ayrıca doğrulandı. Emülatör akışı 9:59,2
ile 18 dakika sınırında; 42 aşama işareti ve dört tamamlanmış temizlik var.

AMD64/ARM64 Core imajları restart/medya hazırlığı/iptal kontrolünü geçti;
anonim commit/stable/index ve iki mimarinin sourceRevision değerleri doğrulandı:
`sha256:2c639e795687b28290de3f83bd3e85dad658812e79f03e094863aa86a0e27523`.
[İmzalı APK 89 ve metadata](https://github.com/ersingundem/larenor/actions/runs/33982544696/artifacts/9974481883)
Java 17 + sabit apksig 9.1.0 ile ayrıca doğrulandı: doğru paket/sertifika,
`100000089`, minSdk 26, `debuggable=false`, kaynak commit ve metadata eşleşti.
APK SHA-256: `6829fd342d629931b2ef60ab7911af0d445340642d2b7cee1eb96023ca363243`.
Ev Server’ına koşullu Client yayını atlandı; cihaz/Server kurulumu yapılmadı.

</details>

<details>
<summary>Önceki doğrulanmış yayın: fc632b6 / APK 88</summary>

[Server](https://github.com/ersingundem/larenor/actions/runs/33981106713),
[Android](https://github.com/ersingundem/larenor/actions/runs/33981106645) ve
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33981106554)
imzalı APK 88 dahil başarılı. 1.890 Linux Server testi atlamasız; 2.659
Flutter, 98 JVM ve sekiz emülatör senaryosu geçti. Emülatör akışı 10:04,7;
42 aşama/temizlik işareti doğrulandı. Bu paket S06.3c ve S08.1 kabulüdür.
İki mimarili imaj anonim doğrulandı:
`sha256:00902e8b6142d546a9493e7db4a2b55a8fa166cbd44f9a4932894ae9fd5c4c22`.
[APK 88](https://github.com/ersingundem/larenor/actions/runs/33981106645/artifacts/9974067173)
Java 17 + sabit apksig ile ayrıca doğrulandı; `100000088`, doğru sertifika ve
`debuggable=false`. APK SHA-256:
`757b63032d51b3289f8ecb9d189f451bf777828e1867273d75e13eb485d75a47`.
Ev Server'ına yayın atlandı; ev kurulumu yok.

</details>

<details>
<summary>Önceki doğrulanmış yayın: 483ec13 / APK 87</summary>

[Server](https://github.com/ersingundem/larenor/actions/runs/33979199140),
[Android](https://github.com/ersingundem/larenor/actions/runs/33979199144) ve
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33979199030)
1.736 Linux Server, 2.625 Flutter, 98 JVM, sekiz E2E ve 202 araç testini geçti.
İki mimarili imaj anonim doğrulandı:
`sha256:7b368f5e5575746de203e88c96a3c64fb99527032b6806dce538f816c73ced61`.
[APK 87](https://github.com/ersingundem/larenor/actions/runs/33979199144/artifacts/9973530086)
Java 17 + sabit apksig 9.1.0 ile ayrıca doğrulandı: doğru paket/sertifika,
`100000087`, minSdk 26, `debuggable=false` ve kaynak commit eşleşti.
APK SHA-256: `1d642a628da571fbb5f4e0d453ac6c6bf94c2d69b6b5aa2109926df0730f3a76`.
Bu önceki kanıt daha yeni Client bağlamı veya imaj/journal köprüsünü kapsamaz.

</details>

<details>
<summary>Önceki temel kabul ve CI düzeltmeleri: 62b2054 ve öncesi</summary>

**S06 dilim 2 tamamlandı:** [birleşik medya gereksinim kontrolü](media-inspections-implementation-2026-09-05.md),
şifreli kalıcı sonuç/geçmiş/iptal, Android yönetim ekranı, toplam disk bütçesi ve
ayrı daemon bağlamı gözlemleri uygulandı. Bağımsız inceleme bulguları
regresyonlarla düzeltildi. İlk dilimdeki altı bileşenli hazırlık korunur;
`prepared` kurulum, `succeeded` ise bütün gereksinimler geçti demek değildir.

**Doğrulanan kod ve yayın: `62b2054`.**
[Security](https://github.com/ersingundem/larenor/actions/runs/33976443262),
[Server](https://github.com/ersingundem/larenor/actions/runs/33976443375) ve
[Android](https://github.com/ersingundem/larenor/actions/runs/33976443371)
CI'larının tamamı **imzalı APK teslimi dahil başarılı**.

- **1.516 Linux Server testi, sıfır atlama**; gerçek Linux socket/peer-context
  testi JUnit raporunda geçti. Yerelde 1.515 geçti, bir Linux testi Mac'te atlandı.
- **2.625 Flutter, 98 JVM/Robolectric ve 8 cihaz E2E senaryosu** geçti.
  Emulator 36.1.9.0/build 13823996; dört platform + dört uygulama senaryosu,
  42/42 aşama/temizlik işareti. Script yaklaşık 8:39 ile 18 dakika sınırında;
  bütün action yaklaşık 9:50. Analiz temiz; 178 araç testi geçti.
- **AMD64 ve ARM64 imajları** gerçek container restart/medya hazırlığı/iptal,
  APK doğrulayıcı ve kapalı inspection yeteneği kontrollerini geçti. Anonim
  erişimle commit ve `stable` için aynı imaj indeksi doğrulandı:
  `sha256:7ff0e5ef2322ad1711be7b9bcd6d79119695a2b9aa6718ce40e224b007875e70`.
- [**İmzalı APK 86 ve metadata**](https://github.com/ersingundem/larenor/actions/runs/33976443371/artifacts/9972729514)
  indirildi ve Java 17 + hash ile sabitlenmiş resmi apksig 9.1.0 ile ayrıca
  doğrulandı. Paket `com.ersingundem.larenor`, sürüm `100000086`, minSdk 26,
  doğru sertifika ve `debuggable=false`; kaynak commit ve APK SHA-256 eşleşti:
  `f5fa27b755331d8389985f4aa53ac8ef7b58f0e2f5de2615db06d849b91f70dc`.

Ev Server'ı henüz yapılandırılmadığından koşullu Client yayın adımı atlandı.
Ev cihazına veya sunucusuna kurulum yapılmadı. Medya motorlarını kurma,
otomatik eşleştirme ve gerçek HomePod oynatma kabulü hâlâ açık.

Bu sonuçları kaydeden son değişiklikler belgeler ve bir kaynak sürümü
alıntısının docstring düzeltmesidir; çalıştırılabilir Python AST'si aynı,
Client/test/workflow davranışı değişmedi. APK/imaj ve CI kanıtının kaynak
commit'i **`62b2054`** olarak kalır.

**Devam eden teslim:** [S06 dilim 3 — sahiplikli kaynak hazırlığı](media-resource-preparation-plan-2026-09-05.md).
Kaynak planı/journal → sabit digest ile imaj → sahiplikli appdata → özel kontrol
ağı → yarım işlem kurtarma/iki mimarili kabul sırası ayrıntılandırıldı.
Saf plan/journal ve imaj taşıması yerel testlerden geçti; bütün dilimin kabulü
henüz tamamlanmadı ve kurulum yetkisi açılmadı.

**CI hazırlığı düzeltmesi:** `ce1ce38` E2E'si uygulama senaryoları başlamadan
uyanık kalma ayarını doğrulayamadığı için durmuştu. `16dda6b` RED → `4e05b66`
GREEN ile yalnız seçilmiş QEMU emülatöründe toplam 10 saniye/en fazla beş
uygula-oku denemesi eklendi. Tam `7` veya `15` dışındaki kalıcı değer, ADB
hatası, taşan çıktı ve süre aşımı başarısız kalır; 21 regresyon geçti.
`19b14aa` gerçek koşusunda önkoşul ilk denemede doğrulandı ve bütün sekiz E2E
senaryosu geçti. Önceki hatanın kesin kök nedeni bu koşudan çıkarılmaz.

Önceki `5331f22` commit'inin Android/analiz/güvenlik CI çalışmaları artifact
depolama kotasına takıldı; taramalar bulgu üretmedi. Bu pakette rapor yükleme
hatası açık uyarıyla ayrıldı, güvenlik taramalarının artifact bağımlılığı
kaldırıldı. Asıl test/tarama hataları ve imzalı APK teslim hataları hâlâ engelleyicidir.

</details>

## Şu anda çalışılanlar

| İş | Durum | Tamamlanma ölçütü |
| --- | --- | --- |
| S05 hizmet yönetimi ve denetimi | Client admin ekranı, şifreli Server kayıtları ve 17 servis türünün kontrol yolu uygulandı | `19b14aa` Server/Güvenlik/Android ve imzalı APK teslimi geçti; gerçek servis kabulü ayrı |
| S06 birleşik medya hazırlığı/kontrolü | İlk iki dilim: hazırlık, toplam disk ve daemon bağlamı gözlemi, şifreli kontrol geçmişi/iptal ve Client akışı uygulandı | `62b2054` bütün CI ve imzalı APK geçti. Kaynak hazırlığı → kurulum adımları → özel bootstrap → kurtarma açık; port/alıcı ağı henüz `unknown` |
| B3 kalıcı Core/ev bağlamı | Korumalı kimlik API'si ve S08.1 atomik Client oturumu kabul edildi; S08.2 uyumluluk kod/testi hazır | S08.1 `fc632b6` tam CI; S08.2 kendi CI'ını bekliyor. Global provider/route/cache sınırı, merkezi adaptörler ve kaynak yetkileri açık |
| Gerçek Server imajı doğrulaması | `1408e80` AMD64/ARM64 Core restart/medya hazırlığı/iptal kontrolünü geçti ve yayımlandı | Anonim index ve kaynak kimliği doğrulandı; gerçek ev kurulumu ve medya motorlarının kurulması ayrı |
| Seçilen 63 özelliğin bağımlılık planı | İlk 60 seçim ve bağımsız VNC/RDP/SSH kaydedildi; 11 grup ve mevcut temel kapıları | Yeni özellik kabulü 0/63; SSH/tünel temeli → RDP → VNC, Proxmox veya medya kurulumu zorunlu değil |

**Son kapsam kararı:** Medya ve Music Assistant için ayrı uygulama kurulumu veya
elle API bağlantısı yapılmayacak. Bileşenler Larenor Server'a dahil olacak;
Client yalnız Larenor hesabı/API'si ve kullanıcı ayarlarını sunacak. Bu otomasyon
henüz tamamlanmadı. [Güncel bütünleşik medya planı](integrated-media-stack.md).

**Platform anlatımı:** Larenor Client tablet öncelikli Android uygulamasıdır.
DeX ayrı bir uygulama değil; aynı uygulamanın değişken pencere ve harici ekran
desteğidir. README, mimari belgeleri ve GitHub açıklaması buna göre güncellendi.

## Backend, Music Assistant ve HomePod: bugün nerede?

| Özellik | Çalıştığı yer / mevcut durum | Eksik adım |
| --- | --- | --- |
| Hesap, parola, oturum, rol, kullanıcı yönetimi | Larenor Server API ve veritabanında uygulandı | Gerçek sunucuya manuel kurulum |
| Kasa ve güncelleme sürümleri | Server'da şifreli kasa ve sürüm API'leri; Client geri yükleme/güncelleme akışları mevcut | Gerçek imzalı Client yükseltmesi ve yeniden kurulum kabulü |
| Entegrasyon bağlantı kayıtları | S05 şifreli Server kaydı, Client admin ekranı ve 17 türün kontrol yolu uygulandı | Yerel/uzak testler geçti; gerçek servis kabulü ve S08 adaptör taşıması |
| Gereksinim kontrolü ve iş geçmişi | Kalıcı şifreli işler, Linux işçisi ve açık politikayla Docker API/platform kontrolü uygulandı | Port ve alıcı ağı `unknown`; medya kurma/başlatma ve otomatik eşleştirme henüz yok |
| Birleşik medya hazırlığı/kontrolü | Altı bileşen planı, kalıcı kontrol, toplam disk ve ayrı daemon bağlamı sonuçları; Client geçmiş/iptal | Kaynak hazırlığı ve özel bootstrap; port/alıcı ağı `unknown`, kurulum kapalı |
| Core ve ev kimliği | Server'da kalıcı, anahtarla doğrulanan kimlikler; korumalı API ve Client sözleşme okuyucusu | Client oturum/cache ve kaynak kimliklerine bağlama; çoklu ev/federasyon henüz yok |
| HA, medya ve ağ komutları | Mevcut kontrollerin çoğu hâlâ Client adaptörlerinde | S08 ile gerçek veri ve komut akışlarını Server'a taşıma; yalnızca token saklamak bu taşıma sayılmaz |
| Music Assistant | Client müzik ekranı, eski MA-only paket ve Server token/sürüm kontrolü var; ev sunucusuna kurulmadı | Tek Larenor kurulumu içinde dahili motor; Client üzerinden sağlayıcı/oynatıcı yönetimi, ayrı MA URL/token girişi olmaması |
| HomePod / AirPlay | Music Assistant üzerinden hedef kapsamda; keşif, eşleştirme, kuyruk, ses ve oynatma akışları tamamlanıp doğrulanacak | Sağlayıcı oturumları, aynı ağda keşif/eşleştirme, gerçek ses/grup/yeniden bağlanma testleri |

**Backend taşıması henüz tamamlanmadı; Music Assistant şu anda Larenor Server
tarafından kurulmuş/yönetilen bir servis değil.** Eski
`deploy/larenor-server/compose.yaml` yalnızca Music Assistant bileşenini çalıştırır;
Python Larenor Server API'sinin yerini tutmaz. Ortak pakette bu isim ayrımı
düzeltilecek. Ayrıntı: [Music Assistant kurulum planı](music-assistant-deployment.md).
HomePod için upstream [AirPlay desteği](https://www.music-assistant.io/player-support/airplay/)
mevcuttur; Larenor üzerinden gerçek cihaz uyumluluğu henüz doğrulanmadı.

## Uygulananlar

“Uygulandı” kod ve belirtilen test kapsamını anlatır. Gerçek cihaz gerektiren
kabul işleri aşağıda ayrıca tutulur.

| Alan | Uygulanan kapsam |
| --- | --- |
| Ortak kullanım | Gezinme/arama, oda ve kart düzenleme, Bugün, enerji/bakım, bağlantı ve işlem sonucu ayrımı |
| Medya ve ağ | Ortak medya aşamaları, film gecesi rutinleri, Keenetic ölçüm kartları, Jellyfin/HA üzerinden yetenek kontrollü oynatma hedefleri |
| Tablet ve kiosk temeli | Değişken pencere/DeX düzeni, PIN ve özel sağlık görünümü, WebPanel kaynak/zoom ayarları, yönetilen görev kilidi, yerel fotoğraflı ortam ekranı ve haftalık program |
| Server hesapları | API ve veritabanı, ilk parola değişimi, dönen oturumlar, yönetici yetkileri, kullanıcı/oturum/denetim API'leri |
| Yapılandırma kalıcılığı | Şifreli yerel yedek; Server hesabıyla kasa önizleme, seçili bağlantı bilgilerini kaydetme ve yeniden kurulumdan sonra geri yükleme akışı |
| Client yönetici ekranları | Hesap, kullanıcı/rol, geçici parola, oturumlar ve denetim; son yöneticiyi koruma ve geçersiz kalan onayları kapatma |
| Merkezi hizmet bağlantıları | 17 tür için şifreli kayıt, ekle/düzenle/unut/kontrol; hizmete uygun giriş alanları. HA, medya ve ağ komutlarının tamamının Server'a taşındığı anlamına gelmez |
| Güncelleme altyapısı | APK paket/imza/hash/sürüm doğrulaması, sürüm API'leri, indirme ve Android kurucusuna geçiş; ayrı yayın kimliğiyle koşullu CI teslimi |
| Otomatik güncelleme uyarısı | Ön planda açılış/dönüş ve 15 dakika aralıklı kontrol; oturumluk kapatma, PIN korumalı bağlantı, hesap/rota/arka plan sınırları. İlgili 92 test geçti |
| Server Docker/CI kodu | Sabitlenmiş bağımlılıklar ve imza aracı, root olmayan süreç, ayrı veri/anahtar depoları; iki mimari ve gerçek APK imza kontrolü geçti. Yeniden başlatma testi de geçti ve ortak imaj yayımlandı; anonim manifest indirmesi doğrulandı |
| Server ekran tasarımı | Altı gerçek-widget önizlemesi incelendi; admin seçili sekmesi belirginleştirildi; test matrisi ve README'ye görseller eklendi |
| Bağımsız kod incelemesi | Server başlatma/kaynak/lisans/sürüm sözleşmeleri, Client güncelleme uyarısı ve Docker/CI akışında uygulanabilir ek bulgu çıkmadı; gerçek imaj çalışması yerine geçmez |
| Sunucu bileşenleri önizlemesi | Altı sabitlenmiş katalog kaydı, yönetici/oturum/katalog revizyonuna bağlı şifreli ve süreli önizlemeler; Client gereksinim ekranı. Kurulum düğmesi veya çalışan kurulum API'si yok |
| Kalıcı gereksinim işleri | Yönetici oluşturma/geçmiş/olay/iptal API'leri, şifreli plan/sonuç, belirsiz isteği aynı kimlikle kurtarma, restart ve güncel yetki denetimi. `succeeded` inceleme tamamlandı demektir; bütün kontrollerin geçtiği veya kurulum yapıldığı anlamına gelmez |
| Birleşik medya hazırlığı | Altı sabitlenmiş bileşen için tek kalıcı plan ve toplam istenen kaynak bütçesi; yönetici oluşturma/geçmiş/iptal, restart ve idempotence. Katalog değişse de geçmiş okunur; `installAvailable=false`. Jellyfin ortak kütüphaneyi yalnız salt okunur kullanır |
| Birleşik medya kontrolü | Toplam disk bütçesi, ayrı daemon mount/network/root gözlemleri, şifreli kalıcı kontrol işi ve tablet yönetimi; kaynak ayırma/servis kurma yok |
| Dahili salt okunur işçi | Aynı Server paketindeki `larenor-preflight-worker`, Linux UID doğrulamalı Unix IPC; toplam kapasite/platform, Docker GET `/version` ve açık v3 politikasıyla socket/process bağlamı. Varsayılan kapalı; kurulum yok ve `installAvailable=false` |
| Kalıcı Core/ev bağlamı | `/api/v1/context`, atomik şema 1→2→3 geçişi, HMAC doğrulaması; aynı 27 JSON örneğiyle Server ve Client okuyucu. Client oturum/cache bağlama henüz yok |
| Düzenli GitHub temizliği | Geliştirme/bakım takibi içinde günlük 03.15 sonrası kontrol ve testli araç; en yeni üç debug APK, bütün imzalı APK ve raporlar korunur. İlk koşumda beş eski debug APK (641.275.745 bayt) silindi; kalan 171 çıktı doğrulandı. GHCR izin ve manifest grafiği eksikliği nedeniyle silinmez |
| CI rapor kotası düzeltmesi | Test kanıtı yükleme hataları görünür uyarı üretir; Gitleaks/OSV taramaları artifact kotasına bağlı değildir. Gerçek tarama hatalarının engelleyici kaldığı test edildi |
| Lisans ve kaynak | AGPL-3.0-only, üçüncü taraf bildirimleri, uygulama içi lisans ekranı ve Server kaynak/lisans API'si |
| Geliştirme becerileri | İstenen frontend/CI seçkisinden 27 beceri kuruldu; 81 dosyanın kaynağı ve hash'i kaydedildi. Kurulum uygulama özelliği sayılmaz |

Son yerel doğrulamada **2.625 Flutter, 1.515 Server ve 178 araç testi** geçti.
Gerçek Linux peer-context testi macOS'ta atlandı; Linux CI'da 1.516 testin tamamı atlamasız geçti.
Server koşumunda gerçek Java/apksig kullanıldı. Workflow `actionlint` ve diff
kontrolü ve tam Flutter analizi temiz. Bağımsız incelemede bulunan
iş geçmişini belleğe topluca alma, hatalı worker ortam değerlerini güvenle
reddetme ve socket başlatma hatasında yalnız kendi inode'unu temizleme sorunları
regresyonlarla düzeltildi. Bu sonuçlar otomatik medya kurulumu veya fiziksel
cihaz kabulü yerine geçmez.

GitHub saklama politikası ve günlük görevin çalışma koşulları
[depolama temizliği belgesinde](github-storage-retention.md). Görevin çalışması için
Codex hostunun kullanılabilir olması gerekir; GitHub Actions cron işi değildir.
Container paketleri bu otomasyonun silme kapsamında değildir.

## Sıradaki geliştirme paketleri

Aşağıdaki mevcut işler korunur. Yeni G01–G11 grupları
[ayrıntılı plana](feature-expansion-plan-2026-09-05.md) göre bu işlerin arasına
yerleşir: S06/B1 ve S08/B3 temeli paralel; S07 otomatik medya bağlantıları ve
S09'un yazılım kurtarma bölümü erkenden tamamlanır. Yeni modüller yalnız kendi
bağımlılıklarını bekler. Son ortak tasarım, README ve fiziksel kabul tüm
seçili yazılım dilimlerinin ardından kalır.

Yarıda kalmaması için S06 kurulum koordinatörü ve B3 oturum/cache taşıması
[küçük teslimlere ayrıldı](remaining-core-integration-slices.md). Her dilimin
somut kabul koşulu vardır; yalnız model veya worker ilkeli eklemek uçtan uca
kurulum/yalıtımın tamamlandığı anlamına gelmez.

| Sıra | Paket / durum | Somut teslim ve bitti sayılma ölçütü |
| --- | --- | --- |
| 1 | **S05 — Hizmet yönetimi · kod ve uzak testler geçti** | Client admin ekranından bağlantı ekle/düzenle/unut/doğrula; şifreli Server kaydı, altı açık doğrulama durumu, yetki/oturum/çakışma testleri. Gerçek servis kabulü ayrı, servis kurulumu S06'da |
| 2 | **S06 — Eklenti sistemi · birleşik hazırlık uygulandı, kurulum eksik** | Altı bileşen için kalıcı hazırlık ve Client yönetimi; katalog/önizleme, kalıcı işler, Linux IPC ve açık politikayla Docker API/platform kontrolü mevcut. Birleşik kontrol ve daemon bağlamı da uygulandı. Sıradaki teslim: [sahiplikli imaj/dizin/ağ kaynakları](media-resource-preparation-plan-2026-09-05.md); ardından dar kurulum ve bootstrap |
| 3 | **S07 — CasaOS ve Music Assistant · sırada** | Tek Larenor Server kurulumu içinde medya ve Music Assistant; otomatik API anahtarı/adres/kütüphane eşleştirmesi, durum doğrulaması; Client'tan yalnız ayar yönetimi |
| 4 | **S08 — Merkezi entegrasyonlar · kimlik temeli eklendi** | Kalıcı Core/ev kimliği ve korumalı API hazır. Sırada Client cache sınırı, önce HA sonra medya/ağ adaptörleri, kaynak yetkileri, olay akışı ve widget sözleşmeleri; mevcut doğrudan yollar belgelenir |
| 5 | **Kalan ürün yetenekleri · sırada** | İleri kiosk ve kamera seçenekleri, Apple TV video, müzik sağlayıcıları ve HomePod kuyruk/grup/oynatma; yetenek matrisindeki desteklenmeyen durumları açık gösterme |
| 6 | **S09 — Ortak kurulum ve bütünlük · sırada** | Tek Larenor kurulumu ve dahili bileşenleri için kurulum/yedek/geri yükleme; özellikler arası akışlar, hata kurtarma, performans/güvenlik ve CI testleri |
| 7 | **G01–G11 — Seçilen 63 özellik · planlandı** | Güvenilir Core → kurtarma → tablet/bildirim → AI/otomasyon → eklentiler/çok ev → medya → aile → kamera → enerji → yeni cihazlar; bağımsız VNC/RDP/SSH dalı kendi ortak profil/güven kapıları hazır olunca paralel ilerler |
| 8 | **Son arayüz geçişi · işlevler tamamlanınca** | Apple tasarım ilkeleriyle ortak renk, tipografi, kart, gezinme, form ve diyalog sistemi; Dashboard, Media, Settings ve Server panelleri aynı düzende. Tek slogan korunacak |
| 9 | **Android tablet görsel kabul ve README · en son** | Huawei MatePad 11.5 S 2026 ve diğer tabletler, yatay/dikey yön, yeniden boyutlanan DeX penceresi, dokunma/klavye erişilebilirliği. Frontend bittikten sonra gerçek tablet görselleri; profesyonel README, ayrı Server/Client kurulumu, doğru GitHub konu etiketleri/açıklama ve insan/AI için açık belge gezinmesi. Telefon için ayrı tasarım hedefi yok |
| 10 | **Manuel kurulum ve fiziksel kabul · kullanıcıyla en son** | CasaOS/Proxmox kurulumu; sağlayıcı girişleri, gerçek HomePod/Chromecast/Apple TV, güç/kilit ekranı, güncelleme/geri yükleme senaryolarının cihazda doğrulanması |

Son tasarım aşamasında Flutter'a uygun Apple tasarım ve erişilebilirlik
becerileri uygulanacak; teknolojiye uymayan web becerileri uygulamaya zorlanmayacak.
README görselleri gerçek tablet düzenini temsil edecek; hazırlanmış taslaklar
çalışan uygulama ekranı gibi sunulmayacak.
Profesyonel README, keşfedilebilirlik ve gerçek kurulum yollarının son kontrolü
için [yayın hazırlık planı](readme-publication-plan.md) eklendi. GitHub açıklaması ve gerçek kapsamı anlatan 16 konu etiketi uygulandı; yıldız veya AI görünürlüğü artışı garanti edilmeyecek.

## Manuel kurulum ve fiziksel kabul

- CasaOS Docker veya Proxmox Linux VM kurulumu **en sonda kullanıcıyla manuel**
  yapılacak. Güncel geliştirme ev sunucusuna kurulmuş değildir.
- Spotify, Apple Music ve YouTube Music yetkilendirmesi; Music Assistant,
  HomePod, Chromecast ve Apple TV üzerinde gerçek arama/kuyruk/oynatma kabulü.
- Huawei MatePad 11.5 S 2026 ve diğer tabletler; Samsung DeX, dokunmatik monitör,
  ekran kapalı ses, kilit ekranı ve OEM güç davranışları.
- Sağlık sağlayıcısı/cihaz izinleri, yönetilen kiosk için fiziksel cihaz kabulü.
- Netelsan Algan 7'nin tam donanım revizyonu ve elektronik köprü; gerçek zil,
  kamera ve kapı davranışı. Yazılım temeli fiziksel bağlantı tamamlandı demek değildir.
- Gerçek Server üzerinden aynı imzalı Client yükseltmesi ve yeniden kurulumdan
  sonra hesap/kasa geri yükleme kabulü.

Üretim Home Assistant üzerindeki kontroller salt okunur kalır. Native iOS
geliştirmesi güncel kapsam dışındadır.

## Son test kanıtı

| Çalıştırma | Sonuç | Sınır |
| --- | --- | --- |
| Tam Server API/depolama/sürüm/iş paketi | **1.515 geçti; 1 Linux testi Mac’te atlandı** | Gerçek Java/apksig dahil bütün `server/tests`; sentetik servisler ve yerel IPC, canlı ev sunucusu değil |
| Tam Flutter paketi | **2.625 geçti** | Birleşik medya hazırlığı, bağlam ve sayfalama, hesap/yaşam döngüsü ve ortak JSON sözleşmeleri dahil unit/widget kapsamı |
| Bütün Python araç/politika testleri | **178 geçti** | Yeni container medya yolculuğu dahil; gerçek imaj çalışması GitHub CI'da ayrıca doğrulanır |
| Birleşik medya kontrol işleri | **116 odaklı test**, **%99 satır/dal** | Model/API/şema %100; gerçek HTTP→Unix→restart ortak JSON, şifreli sonuç, idempotence, iptal ve yetki yarışları |
| Client birleşik kontrol | **160 ilgili test**, **%93,8 satır** | Yeni alan 680/725 satır; aynı Server JSON örneği, beklenen Core/ev sınırı, EN/TR ve büyük yazı |
| Daemon bağlamı | **179 geçti; 1 Linux testi Mac’te atlandı**, **%94 satır/dal** | Socket pidfd, thread/proc/root/mount kimlikleri; gerçek ev Docker'ı kullanılmadı |
| Host/IPC son bağımsız inceleme | **120 geçti**, **%95 satır/dal** | Host %98, IPC %91; ortak bütçe, path değişimi, tek süre sınırı, bozuk nested sonucun reddi |
| Birleşik medya planner'ı | **83 geçti**, **%97 birleşik kapsam** | Altı bileşen, güvenli katalog, değişmez hash/kimlikler; host I/O veya kurulum yok |
| Medya API/depolama/ortak sözleşme | **75 geçti**, **%92 birleşik kapsam** | Şema/API/model %100; şifreleme/AAD, paralel tekrar/iptal, restart, katalog/yetki ve 8/256 sınırları |
| Client medya hazırlığı | **52 geçti**, 18 widget; **%95,3 satır** | İlgili katalog/iş/bağlamlarla birlikte 237 test; farklı Core, 256 kayıt erişimi, belirsiz POST, 2× yazı ve erişilebilir alanlar |
| Container medya smoke protokolü | **29 ilgili test**, helper **%100 kapsam** | `19b14aa` CI'ında gerçek amd64/arm64 imajlarında oluştur/restart/iptal geçti; medya servisleri kurulmadı |
| Emülatör hazırlığı | **21 araç regresyonu geçti** | Sınırlı tekrar, QEMU kanıtı, kesin ayar değeri ve hata halinde derleme başlamaması; `19b14aa` gerçek E2E önkoşulu ilk denemede geçti |
| Client gereksinim işleri | **53 geçti**, 19 widget; **%94,8 satır** | Tam Flutter toplamının içindeki odaklı kapsam; fiziksel tablet kabulü değil |
| Docker ve politika bütünleştirmesi | **236 geçti**, üç modülde **%99 birleşik satır/dal** | Docker probe %96; host/runtime %100. Sonradan eklenen dördüncü yavaş-daemon journey de geçti; fiziksel daemon kabulü değil |
| Kalıcı Core/ev kimliği ve ortak sözleşme | **59 Server / 63 Client testi geçti** | Yeni Server modülü ve Client model/metot %100 kapsam; çoklu ev ve Client oturum/cache henüz yok |
| Dahili işçi CLI | **47 geçti**, **%100 kapsam** | Politika/izin, statik hata ve durdurma testleri; gerçek kurulum yok |
| İşçi IPC bağımsız incelemesi | **83 testlik ilgili koşum**; 201/216 statement, 59/68 dal | 16 temel IPC testi ve başlatma hataları dahil; kapsamdaki diğer dosyalarla toplanmaz |
| Kalıcı iş bağımsız incelemesi | **55 geçti**, **%89 birleşik kapsam** | Yetki, kalıcılık, iptal, idempotence, bozulma ve restart; Server toplamının içindedir |
| Önceki yerel Android native koşumu | **98 geçti**, 18 test paketi | Güncel S06 için yeni fiziksel kurulum/oynatma kanıtı değildir |
| Uzak API 35 x86_64 E2E (`62b2054`) | **4 uygulama + 4 platform senaryosu geçti** | Gerçek emülatör 36.1.9.0; 42/42 işaret ve yaklaşık 8:39 script süresi. Fiziksel tablet kabulü değil |

Test dosyaları, kapsam ve açıklar [test matrisinde](testing-matrix-2026-09-05.md).
Test adetleri farklı zaman ve kapsamları temsil eder; toplanarak başarı oranı
üretilmez. CI kanıtı yukarıda adı verilen commit içindir; yalnız belge değişiklikleri uygulama veya workflow kodunu değiştirmez.

## Güncelleme kaydı

- **19:42:** Kullanıcının sürekli devam talimatıyla kalan adımların kalıcı
  yürütme kuyruğu hazırlanıyor; mevcut takip 15 dakikalık geliştirme devamına
  genişletildi, günlük debug APK temizliği aynı sınırlarla korundu.
  S06.3a saf kaynak sözleşmesi `8ab8006` RED → `0de91a2` GREEN: 67 yeni,
  katalog/stack ile 249 test geçti. Kaynak journal'ı ve imaj akışı paralel;
  kurulum yetkisi açılmadı, fiziksel ev işlemi yapılmadı.

- **19:22:** S06 dilim 2 tamamlandı, koordinatör **2/6**. `62b2054` bütün
  CI ve imzalı APK 86 teslimi geçti; APK yerelde ayrıca doğrulandı.
  1.516 Linux Server, 2.625 Flutter, 98 JVM/Robolectric, 8 E2E, 178 araç testi;
  iki mimarili imaj ve anonim index doğrulaması başarılı. `072aa8a` son tam
  regresyonunda bulunan üç eski test taklidi `62b2054` ile güncellendi;
  eski koşular concurrency ile iptal edildi. Sonraki kaynak hazırlığı altı
  adıma ayrıldı; yeni özellik kabulü hâlâ 0/63, gerçek ev kurulumu yok.

- **18:24:** `19b14aa` Güvenlik, Server ve Android CI'ı imzalı APK 84 teslimi
  dahil başarılı. 1.273 Server, 2.572 Flutter ve yerelde 176 araç testi;
  gerçek emülatörde 4 native + 4 uygulama senaryosu, 42 aşama işareti geçti.
  İki mimarili medya restart/iptal imajı yayımlandı, anonim manifest doğrulandı.
  Dilim 2 için daemon bağlamı, ortak süre sınırı, değişen yol, toplam dosya
  sistemi bütçesi ve ağ bilinmezliği beş somut kabul senaryosuna ayrıldı.
  Uzak erişim F61–F63 planlandı; protokol motorları henüz uygulanmadı.
- **18:00:** `ce1ce38` Server/Güvenlik ve gerçek iki mimarili medya restart
  akışı geçti; anonim imaj manifesti doğrulandı. Android analiz ve debug/native
  başarılı; E2E hazırlıkta durdu, imzalı APK üretilmedi. Ayarı doğrulamayı
  gevşetmeden 21 regresyonlu, süre/çıktı sınırları olan hazırlık düzeltmesi
  eklendi; bütün araç paketi 176 testle geçti. Uzak erişimde kişisel bağlantının
  Core gerektirmediği ve açık
  oturumların çıkış/hesap/ekran değişimindeki kapanış politikası netleştirildi.
- **17:40:** S06 ilk dilimi 2.572 Flutter, 1.273 Server ve 169 araç testiyle
  yerelde doğrulandı. Bağımsız incelemenin boş/bozuk şema, farklı Core
  tarihçesi, eski kayıt erişimi ve son erişilebilirlik/sınır bulguları düzeltildi.
  Gerçek iki mimarili imaj smoke'una hazırlık → restart → aynı kayıt → iptal
  eklendi. VNC/RDP/SSH F61–F63 olarak onaylı plana eklendi; toplam 63,
  yeni kabul 0/63. Protokoller Client'ta, ortak profil/kasa isteğe bağlı Core'da.

- **17:27:** `21bbf58` üç CI kapısından geçti; imzalı APK-82 teslim edildi.
  S06 dilim 1 için altı bileşenli plan, şifreli hazırlık, HTTP/Client sözleşmesi
  ve yönetici ekranı uygulandı. Jellyfin ortak kütüphanesindeki salt okunur
  amaç uyuşmazlığı düzeltildi. Bağımsız inceleme ve yeni tam testler sürüyor;
  kurulum/otomatik eşleştirme ve B3 oturum/cache sınırları açık kalıyor.

- **16:57:** `e73533e` Android/Güvenlik/Server CI tamamen başarılı;
  `app-signed-release-apk-81` imzası doğrulanarak teslim edildi. Gerçek ev
  Server'ına yayın yapılandırılmadığından atlandı. Son ortak sözleşme dilimi
  1.103 Server, 2.520 Flutter, 159 araç testi, analiz/format/sır taraması
  kanıtlarıyla yeni push için hazır; önceki koşum onun CI'ı yerine sayılmaz.

- **16:50:** `e73533e` uzak Android E2E **8/8 geçti**. Emülatör pininin
  gerçekten yüklendiği ve bütün uygulama aşamalarının tamamlandığı doğrulandı;
  timeout/assertion sınırları gevşetilmedi. İmzalı APK işi sürüyor.

- **16:44:** `e73533e` Server/Güvenlik CI başarılı; iki mimaride kimlik restart
  kontrolü geçti, Android sürüyor. Ortak 27 JSON örneği Server ve Client'a
  bağlandı; bool/float şema kabulü düzeltildi. Tam Server 1.103 test geçti;
  Client 63 ilgili test ve tam 2.520 Flutter testi geçti; analiz temiz.
  [Sonraki küçük teslimler](remaining-core-integration-slices.md)
  açıklandı; cache izolasyonu ve otomatik medya kurulumu hâlâ açık.

- **16:32:** Kesilen işlerden S06 Docker kontrolü ve B3 kalıcı Core/ev kimliği
  tamamlandı; tam 1.075 Server, 2.479 Flutter ve 159 araç testi geçti.
  `5deb1e6` Server/Güvenlik CI başarılı; Android native 4/4 sonrası emülatör
  kaybı nedeniyle E2E başarısız. Yeni pin ve aşama tanılaması hazır; yeni
  commit'in CI sonucu bekleniyor. [Docker kanıtı](docker-preflight-implementation-2026-09-05.md)
  ve [kimlik kanıtı](core-context-implementation-2026-09-05.md) eklendi.

- **15:55:** Kullanıcı 60/60 yeni özelliği seçti. Seçim JSON'a kaydedildi;
  her özellik 10 teslim grubunda tekil ID, bağımlılık ve kabul ölçütüyle
  mevcut kuyruğa bağlandı. Eski yaklaşık %65 yalnız önceki kapsam olarak
  ayrıldı; yeni kabul 0/60, genişletilmiş toplam henüz hesaplanmadı.
  Tam Flutter analizi de temiz sonuçlandı. Yeni kurulum veya cihaz işlemi yok.

- **15:40:** S06 kalıcı salt okunur gereksinim işleri, Linux IPC ve Client
  geçmiş/iptal/istek kurtarma akışı `5c6b83b` üzerinde yerelde doğrulandı:
  2.477 Flutter, 921 Server ve 157 araç testi. Henüz gönderilmedi; yeni CI ve
  tam analiz sonucu bekleniyor. `09729be` güvenlik ve iki mimarili Server yayını
  başarılı; Android E2E Quickstep ANR/odak hatası açık. Yaklaşık %65 tahmini
  korundu; yeni 60 fikir seçim bekliyor ve kapsama eklenmedi.

- **14:14:** Katalog/önizleme dahil **653 Server testi** geçti; işçi testleri
  bu koşuma henüz dahil değil. Ortak Python/Dart katalog-plan sözleşmesi için
  ayrıca bir API testi geçti. Wheel içindeki paketlenmiş katalog bağımsız
  açılarak doğrulandı. Android E2E odak/grafik düzeltmesi `8346c01` ile gönderildi;
  yeni CI sürüyor. Birleşik medya kurulum otomasyonu sıradaki ana iştir.

- **14:11:** Kullanıcının yeni kararı işlendi: Music Assistant ve tüm medya
  bileşenleri tek Larenor Server kurulumu içinde, API bağlantıları otomatik;
  Client'ta yalnız ayar yönetimi. Eski MA-only kurulum belgesi geçiş referansı
  olarak işaretlendi. Katalog ekranı dahili bileşen gereksinimleri ekranına
  uyarlandı; kurulum ve bağlantı otomasyonu henüz tamamlandı sayılmıyor.

- **14:01:** S05 `88c26fc` ile yayımlandı. Güvenlik ve iki mimarili Server CI
  başarılı; Android CI sürüyor. GitHub About açıklaması ve 16 konu etiketi
  uygulandı ve geri okunarak doğrulandı. S06 katalog/önizleme/işçi geliştirmesi
  sürüyor. Genel kapsam tahmini **%65** olarak korundu; henüz bitmemiş S06 veya
  fiziksel kabul tamamlanmış sayılmadı. Final README ve görseller frontend sonrası.

- **13:49:** S05 tamamlanmış kod dilimi: 17 servis türü, Client admin akışı,
  türüne uygun kimlik bilgisi alanları ve ortak JSON sözleşmesi. Son 2.333 Flutter,
  529 Server, 114 araç testi geçti; analiz ve 747 Dart dosyasının biçimi temiz.
  CI için yeniden başlatma portu ve emülatör kaynak/tanı düzeltmeleri hazır.
  Son sır taraması ve GitHub gönderimi yapılıyor; S06 katalog çalışması ayrı sürüyor.
- **13:39:** Tam 2.327 Flutter testi, 106 araç testi ve analiz geçti. Ortak JSON
  sözleşmesi hem FastAPI hem Dart Client tarafından doğrulandı. Kaynak üretimi
  ve imaj dosya izni düzeltmeleri `773a02e` ile gönderildi. Server gerçek imza
  testini geçti; yeniden başlatma testinin port varsayımı düzeltiliyor. Yeni
  görseller frontend sonrasına bırakıldı; README/etiket/kurulum yayın planı eklendi.
- **13:16:** Yaklaşık %65 ilerleme çubuğu ve dokuz açık teslim adımı eklendi.
  Server'a taşınan hesap/kasa/yayın ile hâlâ Client'ta çalışan entegrasyonlar
  ayrıldı. Music Assistant'ın henüz yönetilen servis olmadığı ve HomePod fiziksel
  kabulünün beklediği açıklandı. Son tasarım ve README için tablet/DeX önceliği
  kaydedildi. S05 CRUD 63 test geçti; son Server CI başlatma hatası inceleniyor.
- **12:47:** `473132e` GitHub'a gönderildi ve uzak dosya doğrulandı. Güvenlik
  CI başarılı; Android ve Server imajı işleri çalışıyor. Yerel takip dosyası bu
  sonucu yansıtır; devam eden yayın kontrollerini geçersiz kılmamak için yalnız
  durum kaydıyla yeni bir `main` commit'i oluşturulmadı.
- **12:45:** Artifact kotası CI düzeltmesi eklendi; dört yeni tarama hata
  yayılım testiyle araç paketi 97/97 geçti. Yayın paketi yerelde doğrulandı;
  GitHub CI ve gerçek Server imajı sonucu ayrı bekleniyor.
- **12:38:** Tam 2.297 Flutter ve 98 native test geçti; analiz temiz. Kullanıcının
  ilerleme sorusu için genel kapsam tahmini %60–65 olarak eklendi. CI rapor
  yükleme sorunu çözülmeden bulut CI başarılı olarak işaretlenmiyor.
- **12:33:** Güncelleme uyarısı, altı ekran önizlemesi ve Docker/CI kodu tamamlandı.
  93 Python araç testi ve tüm workflow'larda actionlint geçti. Birleşik son
  testler ve bağımsız kod incelemesi sürüyor; gerçek imaj doğrulaması bekliyor.
- **12:27:** Tek takip dosyası oluşturuldu; güncelleme uyarısı, Server imajı,
  ekran önizlemeleri ve son bütünleştirme aktif işlere alındı. Yerel çalışma ile
  yayımlanmış commit ve fiziksel kabul ayrıldı.
