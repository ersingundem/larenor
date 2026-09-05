# S08.1 — doğrulanmış Core/ev oturumu

5 Eylül 2026. [Kalıcı kuyruktaki](EXECUTION_QUEUE.md) S08.1'in kod ve
test kaydıdır. Tek mevcut ev bağlamını kapsar; çoklu ev federasyonu ve bütün
provider/cache taşınması ayrı işlerdir. Eski Server için özel ürün açıklaması
[S08.2'de](client-context-compatibility-2026-09-05.md) izlenir.

## Davranış

Başarılı login, refresh veya parola değişiminin döndürdüğü yeni token çifti,
Core/ev bağlamı okunmadan önce mevcut güvenli saklama anahtarına tek v2 kayıt
olarak yazılır. Bağlam okunamazsa aday oturum korunur; yönetim özelliklerine
hazır oturum olarak sunulmaz. Ekrandaki yeniden deneme yalnız bağlam GET'ini
yeniler; login/parola POST'unu veya artık geçersiz olabilecek eski refresh
tokenını tekrar kullanmaz.

Refresh ve parola POST'undan önce belirsiz auth işlemi niyeti kalıcı yazılır.
Bu yazı başarısızsa POST gönderilmez. Süreç POST'un sonucunu kaydetmeden
kapanırsa yeniden açılış eski token ailesini otomatik kullanmaz; yeniden giriş
gerekir. İlk parola değişimi zorunlu hesap bağlam endpoint'ine çağrı yapmaz.
Parola değişince yeni çift ve bağlam doğrulanır.

Eski v1 kayıt okunabilir, fakat saklanmış kimlik veya URL kimlik doğrulaması
yerine geçmez. Yeni v2 kayıt bağlamı, aday durumu ve belirsiz auth niyetini aynı
şemada tutar. Yapılandırma yedeği bu oturum kaydını içermez. Bu aşama uygulama
kaldırılınca Android'in güvenli depoyu koruyacağı anlamına gelmez; merkezi
yapılandırma geri yükleme ayrı kabul kapısıdır.

Geç kalan bir HTTP 401 yalnız isteğin kullandığı oturum hâlâ geçerliyse onu
reddedebilir. Paralel yenilemenin kaydettiği aday veya yeni doğrulanmış oturum
eski yanıttan etkilenmez. Gerçek güncel 401 oturumu kapatır. Logout, arka plana
geçiş ve eski callback sonuçları generation ve oturum kimliğiyle sınanır.
Tam Core/ev provider, route ve cache sınırı S08.3–4'te tamamlanacaktır.

## Test ve inceleme

`726ae26` controller/saklama RED, `0c172b4` ekran RED ve `472f861` gecikmiş
401 RED → `f7d9b83` GREEN. Son Server özellikleri ve Client güncelleme
regresyonunda **520 test geçti**; değişen 14 Dart dosyasının analizi temiz.
İngilizce/Türkçe tablet ekranı, iki kat yazı ölçeği, gerçek kayıt encode/decode,
saklama hatası, restart, timeout ve yanlış cevap senaryoları kapsanır.

Satır kapsamı: controller **279/290 (%96,2)**, güvenli store **8/8 (%100)**,
modeller **138/139 (%99,3)**, hesap ekranı **368/389 (%94,6)**. Bunlar Dart
satır kapsamıdır; dal veya fiziksel cihaz uyumluluk oranı değildir.
Bağımsız kök incelemesinde eski isteğin 401 cevabının yeni tokenı silebildiği
durum üç başarısız testle doğrulandı ve giderildi. Son controller/store
incelemesinde başka P1/P2 bulgu kalmadı.

Bu commit yerel kanıttır. Tam kaynak commit'inin uzak CI ve APK teslimi
[PROGRESS](PROGRESS.md) içinde ayrıca kaydedilir. `483ec13` önceki yayın
olduğu için bu yeni Client davranışının kanıtı olarak kullanılamaz.

Uzak yazılım kapısı daha sonra **fc632b6** ile geçti: 2.659 Flutter, 98 JVM,
sekiz emülatör senaryosu ve imzalı APK 88 teslimi; 1.890 Linux Server testi
atlamasız. S08.1 kapsamı kabul edildi. S08.2 özel eski Server anlatımının
kod/testi daha sonra `67cb058` ile hazırlandı; kendi uzak kabulü ve S08.3–4
global provider/cache sınırları ayrı kalır.
