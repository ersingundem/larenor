# WebPanel: uygulanan ilk dilim

2026-09-05. HA frontend ve dashboard web kartları ortak WebPanel katmanını
kullanır. Bu dilim kullanıcı web oturumuna veya üretim HA'ya bağlanmadan, yerel
platform taklitleriyle doğrulandı; Fully Kiosk'un bütün tarayıcı özellikleri değildir.

## Davranış

- Başlangıç URL'si ve izinli köken tam şema/host/port olarak doğrulanır. Alt alan
  adı, başka port veya başka şema kendiliğinden yetki kazanmaz. Yerel HTTP
  kullanılabilir; HTTPS taşıma güvenliğiyle eş tutulmaz.
- Dış köken engellenir. Kullanıcı başka adresi mevcut kart seçicisinden ayrı
  panel olarak ekler. Pop-up, intent veya OAuth yönlendirmesi kendiliğinden başka
  uygulamayı başlatmaz; köken izin listesi otomatik genişlemez.
- Native HA tokenı, parola, cookie veya JavaScript komut köprüsü enjekte edilmez.
  Web sitesi kendi oturumunu kullanır. Native API hesabı değişince eski frontend
  kaldırılır; web cookie hesabının aynı kullanıcı olduğunu varsaymayız.
- Kurulum sıralı ve beş saniye, yükleme otuz saniye ile sınırlıdır. Yönlendirme ve
  tekrar deneme bütçesi vardır; hata sonrası sonsuz otomatik yenileme yoktur.
  Manuel yeniden deneme başlangıç sayfasını açar; önceki form POST'u yeniden
  gönderildi diye başarı göstermez.
- Gizlenen, boşa alınan, arka plana geçen veya kaynağı değişen panelin JavaScript'i
  kapatılır ve içerik güvenilir boş HTML ile emekliye ayrılır. Geç callback yeni
  paneli değiştiremez. Ham URL/query ve sunucu hataları hata mesajına taşınmaz.
- Android file/content erişimi, geolocation, mixed-content, dosya seçici ve
  üçüncü taraf cookie kısıtları uygulanır; medya kullanıcı hareketi ister. HTTP
  auth/TLS bypass/kamera/mikrofon ve web JS onay/prompt talepleri reddedilir.

Kilitli sürümler: `webview_flutter 4.14.1`, Android `4.14.1`, WKWebView `3.26.1`.
[Resmi paket](https://pub.dev/packages/webview_flutter),
[Android controller API](https://pub.dev/documentation/webview_flutter_android/latest/webview_flutter_android/AndroidWebViewController-class.html).

## Açık platform sınırları

NavigationDelegate bütün iframe, fetch, WebSocket ve POST trafiğini filtreleyen
bir ağ güvenlik duvarı değildir. Android'in native yönlendirme callback'i her
istek için çağrılmaz; onPageStarted/onUrlChange savunması da ağ isteği başlamadan
önce mutlak engel garantisi vermez. Yüklenen site hâlâ güvenilir olmalıdır.
[Android WebViewClient](https://developer.android.com/reference/android/webkit/WebViewClient),
[Güvenli URI yükleme](https://developer.android.com/privacy-and-security/risks/unsafe-uri-loading).

Plugin public API'si Android renderer ölümü için gerekli native callback'i ve
panel başına ayrı cookie/data-store sahipliğini açmıyor. Controller'ı boşaltmak
logout veya bütün site verisini silmek değildir. Global clearCookies diğer
panellerin oturumlarını da etkiler; bu dilimde tek paneli temizlediğini iddia eden
bir düğme yoktur. iOS dosya yüklemesinin tümüyle engellendiği de iddia edilmez.
[Cookie temizleme kapsamı](https://pub.dev/documentation/webview_flutter/latest/webview_flutter/WebViewCookieManager/clearCookies.html),
[WKWebView oluşturma seçenekleri](https://pub.dev/documentation/webview_flutter_wkwebview/latest/webview_flutter_wkwebview/WebKitWebViewControllerCreationParams-class.html).

## Kanıt ve devam işleri

Bu dilimdeki 77 ilgili test; köken karşılaştırması, bütçe/watchdog, ilk yükleme
sırasında arka plan, idle, config loading/error, aynı hostta token değişimi,
güvensiz callback, retry/back tek uçuşu ve telefon/tablet düzenini kapsar.
Dosyalar `lib/features/web_panel`, `test/features/web_panel` ve mevcut webview
kart testleridir. Bunlar gerçek WebView/OEM davranışı yerine geçmez.

Sonraki tarayıcı dilimi: açık ek köken yönetimi, izinli harici giriş akışı,
etkilenen bütün web oturumlarını belirten temizleme, native renderer kurtarma ve
oturum izolasyonu. Huawei'nin gerçek WebView sürümü, iOS upload ve servis-worker
ömrü cihaz kabulünde sınanmalıdır. [Tam kiosk planı](kiosk-capabilities-research-2026-09-05.md).

## Aynı gün eklenen kart ve veri yönetimi

Kart seçici/düzenleyicisinde `WebPanelOptions` artık tam köken izinleri,
yakınlaştırma ve Android metin ölçeğini saklar; dashboard/şifreli kasa doğrulaması
aynı şemayı kullanır. Ayarlar'daki web verisi temizliği güncel PIN doğrulamasıyla
bütün renderer'ları durdurur; gecikmiş native boşaltma işlemleri de ortak bariyere
dahildir. Hata halinde temizlenmiş varsayılmaz ve eski renderer yeniden açılmaz.
Bu katman çerez/local storage/cache temizler; bütün site veritabanlarını veya
sunucu oturumlarını silme garantisi vermez. Ayrıntılar ve test dosyaları
[panel geliştirmeleri belgesinde](panel-and-media-implementation-2026-09-05.md).
