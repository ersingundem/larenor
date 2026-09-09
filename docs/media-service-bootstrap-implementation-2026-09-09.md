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

## Açık kabul sınırları

Bu dilim container adresi bulmaz ve ağ bağlantısı açmaz. Sıradaki adım exact
managed-container ID, private control network ve container IP gözlemini aynı
daemon/peer kanıtına bağlayıp bu preconnected stream'i worker içinde üretmektir.
Ardından Jellyfin kimlik doğrulama/API anahtarı, sistem adresi ve kütüphane
eşlemeleri servisten geri okunup şifreli duruma yazılacaktır. Music Assistant
host ağı, diğer medya bileşenlerinin otomatik eşleştirmesi, gerçek Linux
container kabulü ve `installAvailable` ayrı açık kapılardır. Ev Docker Engine'i
ve gerçek Jellyfin kurulumu bu dilimde değiştirilmedi.

Resmi kaynaklar:

- [Jellyfin Kotlin SDK Startup API](https://kotlin-sdk.jellyfin.org/dokka/jellyfin-api/org.jellyfin.sdk.api.operations/-startup-api/index.html)
- [Jellyfin TypeScript SDK StartupUserDto](https://typescript-sdk.jellyfin.org/interfaces/generated-client.StartupUserDto.html)
