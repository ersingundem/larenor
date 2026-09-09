# S06.5 özel medya bootstrap temeli

**Durum: yerel uygulama dilimi; CI, gerçek container ve kullanıcı kabulü açık.**

Larenor Server artık tamamlanmış bir Jellyfin container kurulumuna bağlı,
yöneticiye ve oturum ailesine sahip kalıcı bir bootstrap niyeti oluşturur.
Kullanıcı adı ve 48 baytlık rastgele kimlik bilgisi Server tarafından üretilir;
ayrı AES-GCM kaydında, satır kimliği ve durum alanlarına bağlı AAD ile saklanır.
Client sözleşmesi kullanıcı adı, parola, hedef adres, Docker alanı veya servis
anahtarı kabul etmez ve geri döndürmez. Restart sırasında tablo şeması, şifreli
gövde, durum tutarlılığı ve kaynak kurulum bağı yeniden doğrulanır.

İlk Jellyfin protokolü ayrı bir private adaptördür. Adaptör URL, IP, resolver,
proxy, header veya token seçeneği almaz; çağıran worker'ın taze kaynak
kanıtından sonra açtığı tek preconnected stream'i devralır. Aynı bağlantıda
sabit sıra kullanılır:

1. `GET /Startup/User`
2. `POST /Startup/Configuration`
3. `POST /Startup/User`
4. `POST /Startup/RemoteAccess`
5. `POST /Startup/Complete`

Bu sıra Jellyfin'in resmi SDK'sındaki `getFirstUser`,
`updateInitialConfiguration`, `updateStartupUser`, `setRemoteAccess` ve
`completeWizard` işlemleriyle aynıdır. İlk kullanıcı yanıtı boş/null değilse
hiçbir yazma yapılmaz. Türkçe yerel ayarları sabittir ve güncel
`StartupRemoteAccessDto` ile uzak erişim kapatılır. Host portu yayımlamama ve
internal control network sınırı container binding tarafından korunur. HTTP
başlıkları ve gövdeleri sınırlıdır; duplicate JSON,
content encoding, redirect, retry ve belirsiz framing reddedilir. Başarısızlık
yalnız sabit hata kodu, tamamlandığı doğrulanan adımlar ve son yazmanın sonucu
belirsiz mi bilgisini taşır. Kimlik bilgisi exception, repr veya public modele
girmez.

## Yerel kanıt

- RED `54c54ac`: kalıcı şifreli niyet ve public sözleşme.
- GREEN `6c3d968`: API, migration, Core bağlantısı ve restart doğrulaması.
- RED `11d3d43`: preconnected Jellyfin başlangıç protokolü.
- GREEN `fa3fb62`: sabit beş adım, tek stream, bounded HTTP/JSON, süre sonu,
  redirect/retry yasağı ve secret redaksiyonu. `9882c7c`, sabitlenmiş Jellyfin
  10.11 modeline göre `StartupRemoteAccessDto` gövdesini tek resmi alana
  daralttı.
- Bootstrap API/sözleşme/startup odaklı **30 test geçti**. İlgili kurulum/API
  paketi daha önce **81 testten** geçti; security policy ve Python derleme
  kontrolü temizdir.
- Exact Server kaynağı `9882c7c`, SHA-256 sabitlenmiş resmi apksig 9.1.0 ve
  gerçek Homebrew JDK 17 ile tam yerel pakette **4.381 PASS / 13 macOS platform
  skip** verdi; toplam **4.394** test toplandı. İlk iki deneme sırasıyla eksik
  apksig ortam değişkenini ve macOS Java başlatıcısını yakaladı; bunlar başarılı
  koşu olarak sayılmadı.
- RED/GREEN `e04a06a` / `832b44a`: endpoint kanıtı exact journal container
  ID'sini, yeniden türetilmiş stack/binding'i, çalışan durumu, tek control
  network ID'sini, aynı RFC1918 subnet'indeki canonical IPv4/prefix/gateway'i
  ve sabit Jellyfin TCP/8096 listener'ını birlikte doğrular. Soket yalnız bu
  kanıttan açılır; DNS, proxy, alternatif adres ve retry yoktur. **27 yeni / 86
  ilgili test**, security policy, compileall ve diff kontrolü geçti.
- RED/GREEN `42128c2` / `5a1b1b0`, son düzeltme `89687d1`: worker-private
  yürütücü, başarılı `start_container` journal receipt'ini yeniden uzlaştırır;
  yetki kapısını kaynak hazırlama, bağlantı, startup ve sonuç dönüşünden önce
  dört kez denetler. Endpoint startup öncesi ve sonrasında taze container
  gözlemiyle aynı kalmalıdır. Beş startup adımı doğrulanmadan başarı üretmez;
  retry yapmaz ve bağlantı erişilemezliği ile endpoint değişimini ayrı,
  secret-free hata kodlarıyla bildirir. **14 yeni / 100 ilgili test**, security
  policy, compileall ve diff kontrolü geçti.
- RED/GREEN `b931fdd` / `2e75cd3`: kalıcı koordinatör `queued → running →
  credentials_configured` geçişini şifreli AAD kaydıyla tamamlar. Yetki kaybı
  etki öncesinde `needs_attention` olur; erişilemeyen endpoint kesin başarısız,
  kısmi veya belirsiz startup ise insan incelemesi gereken sonuç olarak
  saklanır. Restart'ta bulunan `running` kayıt hiçbir zaman tekrar çalıştırılmaz
  ve `bootstrap_interrupted` olur. Public API yalnız sabit hata kodunu gösterir.
  **18 odaklı / 90 ilgili test**, security policy, compileall ve diff kontrolü
  geçti.

## Açık kabul sınırları

Kalıcı koordinatör yürütücüyü çağıracak durum, yetki, yeniden başlatma ve hata
sözleşmesini hazırlar. Production Core henüz bir bootstrap backend'i
yapılandırmaz; sınıf Unix IPC komutuna ve supervisor dispatch'ine bağlı değildir.
Sıradaki adım bu kapalı runtime bağını kurmak; ardından Jellyfin kimlik
doğrulama/API anahtarı, sistem adresi ve kütüphane eşlemelerini servisten geri
okuyup şifreli duruma yazmaktır. Music
Assistant host ağı, diğer medya bileşenlerinin otomatik eşleştirmesi, gerçek
Linux container kabulü ve `installAvailable` ayrı açık kapılardır. Ev Docker
Engine'i ve gerçek Jellyfin kurulumu bu dilimlerde değiştirilmedi.

Resmi kaynaklar:

- [Jellyfin Kotlin SDK Startup API](https://kotlin-sdk.jellyfin.org/dokka/jellyfin-api/org.jellyfin.sdk.api.operations/-startup-api/index.html)
- [Jellyfin TypeScript SDK StartupUserDto](https://typescript-sdk.jellyfin.org/interfaces/generated-client.StartupUserDto.html)
