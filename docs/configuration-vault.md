# Yapılandırma kasası

Larenor ayarları ve bağlantıları için taşınabilir `.larenor-vault` dosyası
üretebilir. Ayarlar → Yedekle ve geri yükle üzerinden cihazın Dosyalar seçicisiyle
uygulama alanı dışına kaydedilir. Yeni kurulumun bağlantı ekranından aynı dosya
ve yedek parolasıyla geri alınır. Token/parolaların dahil edilmesi hem dışa
aktarmada hem geri yüklemede ayrıca seçilir; varsayılan kapalıdır.

Yedek parolası en az 12 karakterdir ve mevcut Ayarlar PIN'inden ayrı olmalıdır.
Parola uygulamada saklanmaz. Dosya veya parola kaybolursa bu özellik kurtarma
sağlayamaz. Sistem seçicisinde bir bulut dosya sağlayıcısı seçilirse o sağlayıcıya
yalnız şifreli dosya verilir; otomatik bulut eşitlemesi yapılmaz.

## İçerik ve güvenlik

- Odalar, kartlar, favoriler ve gizlenen varlıklar; görünüm/gece/idle tercihleri
  ve etkin servisler.
- Seçilirse HA ile desteklenen medya, Proxmox ve Keenetic bağlantıları. Her
  servisin adresi ve kimlik bilgileri bütün kayıt halinde taşınır.
- PIN ve deneme sayaçları, çerezler, geçici oturum/console biletleri, medya
  önbelleği, loglar, Android imza anahtarı ve Jellyfin kurulum kimliği hariçtir.
- Proxmox self-signed sertifika istisnası geri yüklemeyle etkinleşmez; o cihazda
  ayrıca değerlendirilmelidir. Mevcut Jellyfin cihaz kimliği korunur; yeni
  kurulum kendi kimliğini üretir. Sunucu gerekirse yeniden oturum açtırabilir.
- İptal edilmiş veya süresi dolmuş tokenlar yedekten dönünce geçerli hale gelmez.

Sürümlü şema yalnız bilinen alanları kabul eder. `cryptography` ile AES-256-GCM,
16 bayt rastgele salt, 12 bayt nonce, PBKDF2-HMAC-SHA256 / 600.000 tur kullanılır.
Başlık AEAD doğrulamasına dahildir. Dosyadaki alanlar algoritmayı veya KDF iş
maliyetini yükseltemez. KDF ayrı isolate üzerinde çalışır; dosya en fazla 3 MiB,
çözülmüş JSON en fazla 2 MiB olabilir. Önizleme yalnız adet ve servis adları
gösterir; adres, kullanıcı adı, token veya parola göstermez.

## Geri yükleme

Dosya önce tamamen doğrulanır, ardından içerik ve çakışmalar gösterilir.
Kullanıcı mevcut kayıtları korumayı veya seçilen kayıtları değiştirmeyi seçer.
Mevcut dashboard bir bütün olarak korunur/değiştirilir; iki yerleşimi otomatik
birleştirme yapılmaz. Bağlantının tek alanı başka sunucunun tokenıyla karışmaz.

Uygulamanın eski route/provider oturumu yazmalardan önce kapatılır. Ortak yazma
sırası, daha önce başlayan ayar değişikliklerinin yedeği veya geri yüklemeyi
geçmesini önler. Secure Storage içinde tutulan kurtarma kaydı, değiştirilecek
alanların önceki değerlerini içerir. Yazma başarısızsa geri alınır; işlem
kesilirse sonraki açılış provider'ları oluşturmadan önce bu kayıt toparlanır.
Kurtarma başarısızsa uygulama bağlantıları açılmaz ve yeniden deneme sunulur.
Bu mekanizma disk/OS düzeyinde dağıtık işlem veya fiziksel hasar garantisi değildir.

Dosya seçici uygulamayı arka plana taşıdığında parolalar ve çözülmüş önizleme
ekrandan temizlenir. Mevcut Ayarlar PIN'i varsa devam etmeden önce yeniden
doğrulanır. Başlangıç ekranındaki geri yükleme mevcut PIN'i aşamaz.

## Güncelleme ile ilişkisi

Normal güncelleme için uygulamayı kaldırmayın. Aynı uygulama kimliği, uyumlu
imza ve artan sürüm kodu verilerin yerinde kalmasını sağlar. CI artık kalıcı
release kimliği kullanır; eski debug APK'sının imzası farklı olabilir. İlk
imza geçişinden önce çalışan uygulamadan yedek alınmalıdır.
[Android imzalı dağıtım](android-release-signing.md)

Android otomatik yedek dışlamaları korunur. Eski Android Keystore anahtarı
uninstall sonrasında bulunamayabileceğinden şifreli preference dosyasının tek
başına taşınması yeterli değildir. Kasa, yeni kurulumun Secure Storage'ına
yeniden şifreleyerek kaydeder.
[Secure Storage rehberi](https://pub.dev/packages/flutter_secure_storage),
[Android kullanıcı belgeleri](https://developer.android.com/training/data-storage/shared/documents-files)

Birim/widget testleri gerçek üretim tokenları kullanmaz. Fiziksel Android
cihazında imza geçişi, kaldır–kur–geri yükle ve seçilen Dosyalar sağlayıcısı
kontrolleri ayrıca yapılmalıdır.
