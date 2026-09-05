# S08.4 — Direct HA deposu ve servis başlangıcı sınırı

6 Eylül 2026. Bu ilk paket, Core çalışma ortamının eski Direct HA
kimlik bilgilerini zorla provider/depo erişimiyle açmasını engeller. Diğer
servislerin bağımsız credential provider'ları veya tüm S08.4 tamamlanmış değildir.
Başlangıç kaynağı: `3018c57dc64abab99c283b17972e50a6f3d6d632`.

## Uygulanan sınır

`directHomeAccessProvider`, gerçek `HomeSessionController` içindeki açık Direct
kaynağı, hazır/hatasız durumu, runtime kimliğini ve provider ömrünü bağlar.
Kaynak değiştiğinde elde tutulmuş nesne emekliye ayrılır; Direct'e dönüş eski
nesneye erişim kazandırmaz. Kapsamsız eski depo testleri ve bağımsız Direct
kullanımı korunur. Üretimde HomeSessionScope açık kaynak kontrolünü sağlar.

Bu kaynak sahipliği PIN veya kullanıcı eylem izni değildir. Direct ortamda
etkileşimin boşta olması meşru arka plan okumasını kesmez. Mevcut PIN,
MediaSession, görünürlük ve kullanıcı eylem kontrolleri değişmedi.

HA read/save/clear ve EnabledServices okuma/yazma/başlangıç işlemleri
`ConfigurationWrites` içinde seri çalışır. Her platform işlemi öncesi/sonrası
sahiplik yenilenir. Core'da ilgili depo anahtarları okunmaz; servis credential
başlangıcı veya migration flag yazımı yapılmaz. Başlangıç taramasının Jellyfin
`deviceId` oluşturabilen yan etkisi de aynı sınırdadır. Diğer 11 servisin
bağımsız provider/depo API'leri bu paket tarafından kapatılmış sayılmaz.

## Yarım HA kaydı ve açık kurtarma

Private `ha_connection_pending_v1` markerı ilk URL/token etkisinden önce
secure storage'a yazılır. Marker bulunan okumalar yalnız statik
`pending_mutation` hatası döndürür; olası yeni URL/eski token çifti tüketilmez.
Yalnız açık ve tam save veya clear işlemi, iki anahtarın bütün etkileri ve
sahiplik kontrolleri tamamlanınca markerı kaldırır. Belirsiz yanıt sonrası
rollback, tekrar deneme veya otomatik temizleme yoktur. Platform işlemi
uygulanıp yanıtı kaybolmuş olabilir; `write_unconfirmed` başarı sayılmaz.
Marker silme yanıtı kaybolursa tam çift diskte mevcut olabilir; yeni okuma
bu gerçek durumu değerlendirir, önceki çağrıyı başarılı ilan etmez.

AppShell yalnız bu belirli pending hatasında mevcut ConnectScreen'i boş URL
ve token ile açar. Eski bağlantı doldurulmaz veya otomatik denenmez. Diğer
okuma/depo hataları statik kapalı görünümde kalır. EN/TR mevcut metinleri
kullanılır; yeni kimlik/backup anahtarı dışa aktarılmaz. Backup snapshot,
preview ve restore marker kontrolleri ayrı paralel pakette uygulanır; bu
izole dalın kapsamı değildir ve bütünleşme ayrı doğrulanmalıdır.

## RED → GREEN kanıtı

| Dilim | RED | GREEN | Kanıt |
|---|---|---|---|
| Core gerçek provider ve elde tutulan depo bypass | `b15bc11`, 4 FAIL / 1 PASS | `002eeeb`, 5 PASS | Sahte connection provider yerine gerçek depo/platform kanalı |
| Yarım URL/token ve marker belirsizliği | `5bf9fd6`, 10 FAIL / 2 PASS | `2bff8e1`, öncekiyle 17 PASS | Marker etkisinden önce/sonra hata, kısmi save/clear, yeni depo örneği, kaynak yarışı |
| Bekleyen kayıtta kurtarma formu | `2fa50eb`, 2 FAIL | `3700c6a`, 2 PASS | EN/TR gerçek router/AppShell, boş form; eski kayıt dokunulmadan kalır |

Ek gerçek provider regresyonları: Direct→Core→Direct, provider disposal,
bekleyen read/signIn/signOut sırasında her anahtar etkisinde kaynak değişimi,
Core veya iptal olmuş okuma için REST/WS fabrikalarının hiç çağrılmaması,
11 servis için meşru Direct başlangıcı, Jellyfin device-ID yazısı, false/throw
preference yanıtları, migration flag koruması ve sıralı setEnabled işlemleri.

Son odaklı paket **53 PASS**; mevcut core/auth/settings/navigation/backup/
ha_client ilişkili geniş paket **482 PASS**. Geniş koşu, son iki ek taşıma
oluşturmama testi öncesindeki aynı üretimi doğruladı; son odaklı koşu onları da
kapsar. Beş yeni/değişen veri ve provider dosyasında **196/197 (%99,5) satır**
kapsamı; AppShell'in pending/error dalları widget testinde çalıştı. Bu oran
mevcut bütün AppShell dosyasının kapsamı değildir. Satır kapsamı dal kapsamı
olarak sunulmaz. Son 10 dosya statik analiz sonucu: **0 sorun**.

Yerel kanıtlar:

- `/private/tmp/larenor-direct-home-red-corrected-fixture.log`
- `/private/tmp/larenor-ha-marker-red.log`
- `/private/tmp/larenor-ha-marker-green.log`
- `/private/tmp/larenor-ha-recovery-ui-red.log`
- `/private/tmp/larenor-ha-recovery-ui-final-green.log`
- `/private/tmp/larenor-direct-home-freeze-green.log`
- `/private/tmp/larenor-direct-home-final.lcov`
- `/private/tmp/larenor-direct-home-broad.log`
- `/private/tmp/larenor-direct-home-analyze-final.log`

Tüm Flutter/Dart komutları ortak `larenor-flutter-check.py` kilidiyle izole
worktree'de çalıştırıldı. Ana dal/push/CI ve Android cihaz/emülatör kabulü bu
pakette yapılmadı. Platform testleri yalnız sentetik bellek/kanal depolarını
kullandı; yeni depo örneği testi gerçek işletim sistemi process/disk restartı
olarak sunulmaz. Testlerde ilgili anahtar tüketimi ve yazı etkileri ölçüldü;
SharedPreferences'ın fiziksel getAll çağrısının bütün cihaz verisini hiç
okumadığı iddia edilmez. Gerçek ev hizmetine veya sırlarına erişilmedi.

## Açık kalanlar

Diğer 11 credential provider/depo sınırı; DoorStation, MovieNight, wellbeing
ve disclosure politikası; Ambient fotoğraflarının kapsamı; ev kayıtları için
açık eşleme/taşıma; Core restore tuple/revision bağlamı ve typed ağ cache'i
sonraki bağımlı dilimlerde kalır. Cihaz görünümü/PIN/güç/pencere/kaynak tercihi,
özel Server oturumu ve native updater staging bu ilk HA sınırıyla yeniden
sınıflandırılmadı.
