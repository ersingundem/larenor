# Android release imzası ve CI APK'ları

Larenor artık iki ayrı APK üretir: pull request'lerde de çalışan debug APK ve
kararlı özel anahtarla imzalanan release APK. Release işi yalnızca `main` push'u
ve `main` üzerinde elle başlatılan **Android Build** için uygundur. Bu işlem
GitHub Release veya uygulama mağazasında yayın yapmaz; doğrulanan APK, Actions
artifact'i olarak saklanır.

## İmza kimliğini bir kez hazırlama

Mevcut bir release anahtarı varsa onu koruyun. Yeni anahtar oluşturmak mevcut
kurulumların güncelleme kimliğini değiştirir. Yardımcı araç mevcut dizini veya
GitHub'daki mevcut release secret'larını değiştirmeyi reddeder. Flutter da
mevcut keystore varsa yeniden oluşturulmamasını belirtir.
[Flutter imzalama kılavuzu](https://docs.flutter.dev/deployment/android#sign-the-app)

Gereksinimler: Java 17 (`keytool` PATH üzerinde), Python 3.11+ ve ilgili depoya
secret ekleme yetkisiyle oturum açmış GitHub CLI. Önce mevcut yerel imza
konfigürasyonunun ve GitHub secret **adlarının** kontrolü yapılmalıdır; gizli
anahtar ve parola değerleri terminale yazdırılmamalıdır.

Yeni anahtar gerektiği doğrulandıktan sonra, depo kökünden:

```sh
python3 tool/android_signing.py provision \
  --directory "$HOME/.local/share/larenor/signing"
```

Bu komut yalnızca yerel üretim yapar: 0700 dizin içinde 0600 izinli
`release.p12`, `password.txt` ve `identity.json`. RSA-3072 anahtarı ve rastgele
parola oluşturur. Anahtar üretimi veya upload başarısız olursa **dizini silerek
yeni anahtar üretmeyin**; mevcut dosyalar korunarak hata incelenmelidir.
Anahtarın ve parolanın ayrı güvenli erişim kontrolü olan şifreli çevrimdışı
kopyası tutulmalıdır. Repo, APK, hata raporu ve sohbet bu dosyalar için uygun
saklama yerleri değildir.

Yerel kimlik doğrulandıktan sonra GitHub'a yüklemek için:

```sh
python3 tool/android_signing.py upload \
  --directory "$HOME/.local/share/larenor/signing" \
  --repo ersingundem/larenor
```

Araç yerel sertifika parmak izini doğrular, GitHub'daki secret adlarını kontrol
eder ve değerleri `gh secret set` komutuna standart giriş üzerinden iletir.
Özel değerler komut argümanlarına veya loglara yazılmaz. Oluşturulan adlar:

- `ANDROID_RELEASE_KEYSTORE_BASE64`
- `ANDROID_RELEASE_STORE_PASSWORD`
- `ANDROID_RELEASE_KEY_ALIAS`
- `ANDROID_RELEASE_KEY_PASSWORD`
- `ANDROID_RELEASE_CERT_SHA256` — beklenen sertifikanın SHA-256 parmak izi;
  bu değer özel anahtar değildir ve doğrulama metadata'sında yayımlanır.

GitHub secret'ları tek bir atomik işlemle kaydedilmez. Ağ hatası sonucu yükleme
kısmen tamamlandıysa araç mevcut secret'ların üzerine yazmaz. Yeniden anahtar
üretmek yerine aynı yerel kimlikle yalnızca eksik adlar tamamlanmalıdır; bunun
öncesinde kısmi yüklemenin bu kimliğe ait olduğu doğrulanmalıdır.
[GitHub Actions secrets](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets)

## CI güven sınırları

- Debug işi özel release anahtarlarını almaz. Mevcut Gradle kontrolü anahtarsız
  release derlemesinin reddedildiğini ve kontrolün release task graph'ına bağlı
  olduğunu doğrulamaya devam eder.
- Release işi `main` push/manual koşulu ve başarılı debug işi arkasındadır.
  Elle başka branch seçilirse release işi çalışmaz. PR koduna release secret'ı
  verilmez; `pull_request_target` kullanılmaz.
- Secret'ların tamamı yoksa release açık bir açıklamayla atlanır. Bir kısmı
  varsa, base64 bozuksa veya sertifika beklenenden farklıysa iş başarısız olur.
- `key.properties` ve keystore sadece geçici runner dosyalarıdır; 0600/0700
  izinlerle oluşturulur. `always()` temizliği başarı, hata ve olağan iptal
  durumlarında çalışır. Runner imha edildiğinde geçici ortam da kaldırılır.
- Kullanılan Actions sürümleri tam commit SHA'larına sabitlenmiştir. Checkout
  Git kimlik bilgilerini kalıcı saklamaz. Artifact upload tam olarak APK ve
  public metadata dosyalarını kapsar; imzalama dosyalarını kapsamaz.
- APK üzerinde `apksigner verify` çalışır; tek signer'ın parmak izi, uygulama
  kimliği, beklenen versionCode ve `debuggable` olmaması kontrol edilir.
  Android debug sertifikası release için reddedilir.
  [Android apksigner](https://developer.android.com/tools/apksigner)

Doğrulayıcı CI'da **build-tools 37.0.0** sürümüne sabitlenmiştir. 37.0.0,
sertifika satırlarında eski `Signer #1` yerine `V2 Signer:` ve `V3.0 Signer:`
gibi şema adları kullanır. Önceki ayrıştırıcı bu geçerli çıktıda sıfır sertifika
bulduğu için CI duruyordu; aynı release APK üzerinde resmi 36.1.0 ve 37.0.0
araçlarıyla fark yeniden üretildi. Yeni ayrıştırıcı bu belirli biçimleri kabul
eder, `Number of signers: 1` koşulunu zorunlu tutar ve farklı şema/SDK
aralıklarında tekrarlanan bütün sertifikaların aynı sabitlenmiş kimliğe ait
olmasını ister. Birden fazla kimlik veya anahtar rotasyonu ayrıca tasarlanmadan
kabul edilmez; kaynak damgası ve public-key digest'i imza sertifikası yerine
geçmez. `apksigner verify` başarısızsa metadata veya release artifact üretilmez.
[Resmi Android SDK paketleri](https://dl.google.com/android/repository/repository2-3.xml),
[AOSP apksigner kaynak kodu ve test APK'ları](https://android.googlesource.com/platform/tools/apksig/)

Platformun Android backup/device-transfer dışlamaları bu işlemle değişmez.
İmza anahtarı APK'ya gömülmez ve uygulama veri yedeği değildir.

## Sürüm ve artifact seçimi

Debug ve release APK aynı CI koşusu için `100000000 + GITHUB_RUN_NUMBER`
versionCode'unu kullanır. Yeni **Android Build** koşuları arttıkça kod artar;
üst sınır Android'in `2100000000` sınırıdır. Görünen versionName `pubspec.yaml`
üzerinden gelmeye devam eder. Workflow'u silip farklı bir sayaçla yeniden
oluşturmadan önce bu sürüm politikası taşınmalıdır.
[Android versioning](https://developer.android.com/studio/publish/versioning)

Eski `main` commit'i imzalanmaz. Eski koşuyu tekrar çalıştırarak önceki
versionCode ile release üretmek de reddedilir; yeniden derleme için güncel
`main` üzerinde yeni koşu başlatılır:

```sh
gh workflow run android-build.yml --ref main --repo ersingundem/larenor
```

Başarılı işte `app-signed-release-apk-<run_number>` artifact'i 30 gün tutulur.
İçinde `app-release.apk` ve `release-metadata.json` bulunur. Metadata uygulama
kimliği, sürüm, commit, koşu kimliği, APK SHA-256 ve sertifika SHA-256 içerir.
APK ile metadata birlikte saklanmalıdır; Actions artifact saklama süresi uzun
vadeli özel anahtar yedeği yerine geçmez.

Mevcut debug kurulumunun sertifikası farklı olabilir. Android güncelleme için
uyumlu imza bekler; bu pipeline önceki debug APK'larının üzerine kurulabilme
sözü vermez. Sertifika doğrulanmadan cihazda otomatik kaldırma/yeniden kurma
yapılmaz; kaldırma yerel ayar ve oturumları silebilir.
[Android app signing](https://developer.android.com/studio/publish/app-signing)

## Yerel doğrulama

```sh
python3 -m unittest discover -s tool/tests -p '*_test.py' -v
python3 tool/check_security_policy.py
```

Testler sürüm sınırını, secret eksikliğini/kısmi konfigürasyonu, izinleri,
üzerine yazma/symlink reddini, sertifika uyuşmazlığını, debug sertifika/APK
reddini ve workflow'un `main`, cleanup, verification ve artifact sınırlarını
kontrol eder. Gerçek özel anahtarla cihaz güncelleme testi ayrıca yapılmalıdır.
