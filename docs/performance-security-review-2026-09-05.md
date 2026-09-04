# Performans, kararlılık ve güvenlik — 5 Eylül 2026

Bu tur, yeni entegrasyon eklemekten önce mevcut günlük kullanımdaki maliyeti ve
hata riskini azaltır. Aşağıdaki değişiklikler uygulandı; cihaz üzerindeki performans
profili veya eksiksiz güvenlik denetimi anlamına gelmez. Önceki teslimin `8bce8a2`
commit'inde analiz/test, güvenlik ve Android derleme iş akışlarının tamamı geçti.

## Değişiklikler ve davranış kanıtı

| Alan | Önceki sorun | Yeni davranış / regresyon senaryosu |
| --- | --- | --- |
| Dashboard | Her HA olayı bütün varlık haritasını kopyalayıp sayfayı yeniden oluşturuyordu | Aynı olay döngüsündeki değişiklikler birleştiriliyor. 5.000 varlık/3.000 olay testinde tek durum yayını; 1.000 ilgisiz sensör değişiminde oda yapısı/özet/diğer aksesuar bildirimleri sıfır |
| Medya | Arama ve sıralar kütüphane indeksini bekliyor; kuyruklar tekrar okunuyordu | İstekler paralel başlıyor, Sonarr/Radarr kuyruğu yenileme başına bir kez okunuyor |
| Kamera ve görev listesi | Yavaş isteklerde çakışan yenilemeler, bağlantı değişince eski sonuçlar | Ön planda tek istek; eski varlık/hesap sonucu yok sayılıyor; dispose sonrası ekran güncellenmiyor |
| Duvar paneli | İki farklı yer wakelock durumunu değiştiriyordu | Ekran politikası tek sahip; parlaklık uygulama düzeyinde yönetiliyor, önceki değer geri yükleniyor; boşta saat saniyelik gereksiz yenilenmiyor |
| PIN | Sınırsız deneme ve arka plandan dönünce açık ayarlar | Güvenli depoda deneme sayacı, beş hatadan sonra 30/60/120/240/300 saniye bekleme; arka planda kilitlenme ve açık ayar alt ekranlarının kapanması |
| API erişimi | Özel anahtar başlıkları yönlendirme hedefine gidebiliyordu | Aynı scheme/host/port/proxy yolu zorunlu; yönlendirmeler, yol kaçışı ve bozuk başlıklar reddediliyor; iki yerel HTTP sunucusuyla sızıntı regresyonu sınanıyor |
| Hata mesajları | Ham yanıt/URL içinde token görünebiliyordu | Taşıma ve bozuk JSON hataları gövdeyi göstermiyor; bilinen sırlar maskeleniyor |
| Proxmox TLS | Açık self-signed istisnası istemcinin tüm hedefleri için geçerliydi | İstisna yalnız yapılandırılmış host/port için; varsayılan doğrulama devam ediyor |
| Jellyfin | Oynatma URL'sinde hedef ve query sınırı yeterince denetlenmiyordu | İlk oynatma URL'si sunucu/proxy sınırında, kimlik ve query alanları kodlanıyor |
| Android yedekleme | Varsayılan OS yedeklemesi yerel veriyi taşıyabiliyordu | Bulut ve Android cihaz aktarımında uygulama verisi açıkça dışlanıyor |
| Release imzası | Release paketi debug anahtarına düşüyordu | Özel release imzası gerekli; anahtar yoksa build anlaşılır hata ile duruyor |

Testler duvar saati hızına göre kırılgan eşikler kullanmaz. Olay/bildirim/istek
sayılarını ve kullanıcı davranışını doğrular. Bu nedenle yukarıdaki kazanımlar
“tablette şu kadar FPS” veya pil ömrü iddiası değildir.

## CI değişiklikleri

- Bütün Flutter regresyonları `flutter test --coverage --reporter expanded
  --timeout 90s` ile çalışır. Yeni güvenlik, yoğun olay, PIN ve yaşam döngüsü testleri
  bu pakete dahildir; ayrı kopya çalıştırarak iş süresi şişirilmez.
- `coverage/lcov.info` ve test günlüğü başarı/hata durumunda 14 gün saklanır.
- Android yedek kuralları ve workflow güvenlik sözleşmesi Python standart
  kütüphanesiyle kontrol edilir; kontrolün kendisi de olumsuz örneklerle sınanır.
- Dış action'lar tam commit SHA'sına; Flutter 3.47.2'ye sabitlendi. `pub get
  --enforce-lockfile` beklenmedik dependency çözümlemelerini engeller.
- Varsayılan token izni `contents: read`; checkout git kimlik bilgisini saklamaz.
  OSV'nin sabitlenmiş reusable workflow'u SARIF kapalıyken de `security-events:
  write` istediği için yalnız o job bu izne sahiptir.
- Yeni commit geldiğinde eski aynı-dal işi iptal edilir. Analiz/güvenlik/Android
  işlerinin süre sınırı vardır. Mevcut Gitleaks ve OSV kontrolleri korunur.
- Android CI, private key olmadan release imza doğrulamasının başarısız olduğunu
  ayrıca sınar. Debug APK üretimi çalışmaya devam eder.

Yerel tekrar:

```sh
flutter pub get --enforce-lockfile
dart run build_runner build
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test --coverage --reporter expanded --timeout 90s
python3 -m unittest discover -s tool/tests -p '*_test.py' -v
python3 tool/check_security_policy.py
flutter build apk --debug
```

## Bu teslimdeki doğrulama

| Kontrol | Yerel sonuç |
| --- | --- |
| Flutter birim/widget/regresyon paketi | 558 test geçti (önceki 468'e ek 90 regresyon) |
| Android/CI güvenlik politikası testleri | 6 test geçti |
| Kod üretimi ve lockfile doğrulaması | Başarılı |
| Biçim ve statik analiz | 370 dosyada değişiklik yok; analiz temiz |
| Android debug APK | Başarıyla derlendi; backup kapatma ve XML kuralları paket içinden de doğrulandı |
| Gizli anahtar taraması | Gitleaks temiz |
| Release anahtarı yokluğu | `validateReleaseSigning` beklendiği gibi reddetti; `preReleaseBuild` görev grafiği bu kontrolü içeriyor |

CI aynı test komutlarını son commit üzerinde tekrar çalıştırır; güncel sonuçlar
[GitHub Actions](https://github.com/ersingundem/larenor/actions) sayfasındadır.

## Daha güzel ve işlevsel bir sonraki sürüm

Önceki [entegrasyon planı](integration-roadmap-2026-09-04.md) geçerlidir. Buna ek
olarak aşağıdaki ürün işleri önerilir; bu tabloda yazanlar henüz uygulanmadı.

| Öncelik | Özellik | Kullanıcıya katkı | Kabul ölçütü |
| --- | --- | --- | --- |
| 1 | Bağlantı sağlık merkezi | HA/medya/Proxmox/Keenetic için son başarılı veri zamanı, hata ve yeniden bağlanma tek yerde | Eski veri açıkça işaretlenir; kimlik bilgisi loglanmaz; başarısız yazma kendiliğinden tekrarlanmaz |
| 2 | Misafir/çocuk profili | Ortak tablette yalnız seçilen oda, medya ve sahneler görünür | Sunucu yetkileriyle uyumlu, yönetim yollarında UI ve servis erişimi sınanmış; PIN bir yetki modeli olarak sunulmaz |
| 3 | Oda planı ve kart düzenleyicisi | Aynı Apple Home düzeni içinde sürükle-bırak, kart boyutu ve kısa yol seçimi | Telefon/tablet, büyük yazı ve ekran okuyucuyla düzenleme; geri alma; oda değişince seçim korunur |
| 4 | Sahne önizlemesi ve işlem geçmişi | “Film zamanı” gibi eylemin hangi cihazlara dokunacağını önceden görmek | Yalnız kullanıcının başlattığı komut; başarı/hata ayrımı; gizli alanlar geçmişe yazılmaz |
| 5 | Enerji ve bakım özeti | Tüketim, çevrimdışı cihaz, düşük pil, disk/VM kapasitesi aynı günlük özet içinde | Birim/zaman aralığı doğruluğu; yinelenen uyarı üretmemek; çözülmüş uyarıyı kaldırmak |
| 6 | Kontrollü çevrimdışı görünüm | Ağ kesilince son bilinen oda/medya düzeni erişilebilir | Son güncelleme etiketi; eski durum canlı gösterilmez; çevrimdışı yazma kuyruğu varsayılan olarak oluşturulmaz |

Görsel öncelik: daha çok süs eklemek yerine kartların aktif/işlemde/eski veri/hata
hallerini aynı dille anlatmak; küçük animasyonlar için hareket azaltma tercihine
uymak; telefon ve tablette aynı içerik sırasını korumak. Şu anki tek Latin slogan
ve ortak açık/koyu palet korunmalı.

## Sınırlar ve sonraki kabul testleri

- Üretim Home Assistant sunucusunda değişiklik yapılmadı. Bu turdaki yeni yazma
  senaryoları sahte/loopback sunucularda çalışır.
- qBittorrent'in harici SDK taşıması, Jellyfin native oynatıcısının sonraki HLS
  segment/yönlendirme/TLS davranışı ve Proxmox console WebView ayrı katmanlardır;
  bu HTTP sarmalayıcısının doğrulaması bunları kapsamaz. Sonraki güvenlik işi bu
  üç yolu kapsayan test edilebilir taşıma ve oturum politikası olmalı.
- Self-signed seçeneği sertifika pinning değildir. LAN HTTP trafiği şifrelenmez;
  mevcut yerel kurulum uyumluluğu korunmuştur. Yönlendiren bağlantılarda nihai
  sunucu URL'si girilmelidir.
- PIN, cihazdaki ayarları korur; Home Assistant yönetici tokenının yetkilerini
  azaltmaz. Yeni PIN 4–12 rakamdır; mevcut PIN'ler okumada korunur. OS veri silme
  veya cihazı ele geçirme karşısında bir güvenlik sınırı olduğu iddia edilmez.
- Android bulut/device-transfer dışlama politikası kaynak ve derleme düzeyinde
  kontrol edilir. Gerçek OEM yedekleme/geri yükleme testi ayrıca yapılmalı.
- Release imzası yapılandırması hazırdır; gerçek private key, mağaza dağıtımı ve
  iOS imzalama bu teslimde oluşturulmadı.
- Gerçek tablette profile modunda 24 saat açık kalma, ağın kesilip gelmesi,
  arka plana geçiş, 60 Hz için frame-time dağılımı, bellek artışı, TalkBack ve
  büyük yazı kabul testi gerekir. Test cihazı olmadan bunlar başarılı sayılmaz.

## Teknik kaynaklar

- [Dart HTTP yönlendirme başlık davranışı](https://api.dart.dev/dart-io/HttpClientRequest/followRedirects.html)
- [Android Auto Backup ve cihaz aktarımı](https://developer.android.com/identity/data/autobackup)
- [GitHub Actions güvenli kullanım](https://docs.github.com/en/actions/reference/security/secure-use)
- [Flutter Android release imzası](https://docs.flutter.dev/deployment/android#sign-the-app)
