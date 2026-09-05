# S08.2 — ilk parola ve Server bağlamı uyumluluğu

5 Eylül 2026. [S08.1'in doğrulanmış oturumuna](client-context-implementation-2026-09-05.md)
bağlı, dar Client uyumluluk adımıdır. Kod ve yerel testler hazır; kendi kaynak
commit'ini içeren uzak CI kabulü [PROGRESS](PROGRESS.md) içinde ayrıca izlenir.

## Davranış

İlk parola değişimi zorunlu hesap, parola değişmeden korumalı bağlam API'sini
çağırmaz. Parola değişiminden sonra yeni token çifti kalıcı saklanır ve bağlam
GET ile doğrulanır. Bu okuma başarısız olursa yeni tokenlar aday oturumda
kalır; yeniden deneme parola POST'unu tekrarlamaz. Bu güvenlik davranışı
S08.1'den korunur.

Yalnız yapılandırılmış Server adresinin tam bağlam URL'sine yapılan GET'in
404 cevabı, Türkçe ve İngilizce adres kontrolü/Server güncelleme açıklaması
gösterir. Reverse proxy öneki de URL eşleştirmesine dahildir. 404'ün kesin
olarak eski Server sürümü anlamına geldiği ileri sürülmez. Proxy'nin HTML
hata metni veya teknik hata kodu kullanıcıya gösterilmez.

Hata gövdesinin mevcut 8 KiB sınırı, bu sınıflandırmadan önce uygulanır.
Başka endpoint, sorgulu URL veya HTTP yöntemi için 404 davranışı değişmez.
Bozuk başarılı cevap, 401 veya 503 bu açıklamaya çevrilmez; cevap içindeki
alanlar yerel hata kodunu taklit edemez. URL'den Core/ev kimliği türetilmez
ve saklanmış kimlik tek başına yetki sağlamaz.

## Kanıt

`41ce750` runtime RED → `67cb058` GREEN. Dört yeni başarısız senaryo mevcut
davranışı gösterdi; düzeltmeden sonra 70 odaklı test geçti. Server ekranları
ve Client güncelleme regresyonunda **531 test geçti**; değişen dört Dart
dosyasının analizi temiz, biçim kontrolü değişiklik üretmedi.

Gerçek HTTP istemci sınırındaki test; ilk parola → parola POST'u → sınırlı
404 → aday yeni tokenlar → açık kullanıcı yeniden denemesiyle yalnız GET
sırasını doğrular. EN/TR tablet ekranında 900 piksel genişlik ve iki kat yazı
ölçeği kapsanır. Başka endpoint/yöntem/sorgu, HTML hata gövdesi, 8.193 baytlık
taşma ve yanıtın yerel hata kodunu taklit etmesi ayrı regresyonlardır.

Dart satır kapsamı: API **179/187 (%95,7)**, ekran **369/390 (%94,6)**.
Değişmeyen controller **279/290**, güvenli store **8/8**. Bağımsız kök
incelemesinde kapsam dışı hata sınıflandırması veya token tekrar kullanımı
bulgusu kalmadı. Bunlar fiziksel cihaz veya eski Server kurulumu kabulü
değildir. Global provider/route/callback sınırı ve kalıcı ev cache'i
S08.3–4 kapsamında açık kalır.

Son `3076f5f` kaynak paketindeki tam Client regresyonu **2.701 testle** geçti;
tam analiz temiz. S08.2'nin kendi uzak CI kabulü ayrıca beklenir.

## Uzak kabul — 19dbcbe / APK 91

S08.2 `19dbcbe5545a1ada8cda5754ae4fbc7664c90fce` ile kabul edildi.
[Server](https://github.com/ersingundem/larenor/actions/runs/33985459924),
[Android](https://github.com/ersingundem/larenor/actions/runs/33985459959) ve
[güvenlik](https://github.com/ersingundem/larenor/actions/runs/33985459857)
başarılı: 2.298 atlamasız Linux Server, 2.701 Flutter, 98 JVM, sekiz E2E ve
202 araç testi. Aynı Client uyumluluk kaynağı bağımsız incelendi; eski
`54a677b` koşusundaki Server kapanış fixture hatası test-only RED/GREEN ile
kapatıldı ve yeni Linux testiyle doğrulandı. APK 91 bağımsız Java 17/sabit
apksig doğrulamasını geçti; `100000091`, doğru sertifika, debug kapalı.
Ev kurulumu yok. S08.3 runtime ve S08.4 cache ayrımı bu kabul değildir.
