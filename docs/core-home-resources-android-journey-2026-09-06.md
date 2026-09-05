# Core kaynak listesi — ortak HTTP sözleşmesi ve Android yolculuğu

6 Eylül 2026. Bu dilim S08.6'nın Client liste ekranını gerçek Server yanıtları
ve ayrı Android akışıyla sınamak için hazırlanmıştır. Yeni Android yolculuğu
henüz CI'da çalışmadı; APK 96'daki altı uygulama yolculuğuna dahil değildir.

## Paylaşılan sözleşme

[home-resources.v1.json](../contracts/home-resources.v1.json), gerçek Server
app/auth/SQLite/şifreleme/ACL/HTTP akışından üretilir.
[Python testi](../server/tests/test_home_resources_contract.py) bu akışı
tekrar çalıştırıp bütün yanıtları dosyayla birebir karşılaştırır. Yalnız
üretilen Core/ev/hesap/kayıt kimlikleri ve açık sentetik kasa anahtarı
deterministiktir. Oturum tokenları, şifreler, şifreli satırlar ve cihaz
bağlantıları paylaşılan dosyaya girmez.

Admin ve üye listeleri, boş görünüm, iki sayfa, tek kayıt, 80 Unicode
codepoint'lik etiket, izin kaldırılmış liste, eski sayfada 409 ve başka Core
yanıtı aynı dosyadadır. HMAC gerçekten Server tarafından hesaplanır; Client
onu opak bir sayfa özeti olarak tüketir.

İlk fixture eksikliği RED `5aeb652` → GREEN `c02efb2`, **2 test geçti**.
Bağımsız E2E incelemesi ikinci bir kanıt açığı buldu: A ve B aynı etiketleri
gösteriyordu. B'ye HTTP isteği gitse bile yanlış A ekranı testten geçebilirdi.
RED `e80d097` **1 fail / 2 PASS** → GREEN `285629c` **3 PASS, 0,70 saniye**.
Gerçek B akışı artık `İkinci ev ·` öneki üretir; kimlikler aynı kalır ve
Core/evin kaynak kimliğinin parçası olduğu ayrıca sınanır.

## Android test sunucusu

[SyntheticCoreResources](../integration_test/support/synthetic_core_resources.dart)
yalnız opt-in `SyntheticCoreAccount` üzerinden, bu test sürecinin loopback
portunda çalışır. Üye hesabı, doğru Bearer tokenı, tam Core/ev yolu ve dar
GET sorguları gerekir. Tekrarlı/bilinmeyen sorgu, hatalı limit/cursor,
yetkisiz veya yazma isteği reddedilir. Ev servisine erişim yolu yoktur.

Android cihazında repo dosya sistemi bulunmadığından JSON'un bir test-only
[Dart sabiti](../integration_test/support/home_resource_contract_fixture.dart)
paketlenir; production asset veya yeni pubspec kaydı değildir. Host unit test
bu sabiti JSON dosyasıyla karşılaştırır. Yenileme üye/iptal/boş görünümleri
arasında geçer; fixture bütün sayfalarda aynı opak snapshot'ı korur ve eski
snapshot'ı 409 ile reddeder. Hata gövdeleri yalnız statik code taşır; gerçek
Server'ın hata mesajıyla birebir metin eşliği iddia edilmez.

Fixture RED `0cb93f5` eksik modül/constructor derleme hatasıdır; gerçek davranış
RED'i gibi sunulmaz. GREEN `4bb52c3` ile önceki dört Core hesap testi ve beş
yeni kaynak fixture testi, toplam **9 test geçti**. Başka Core etiketi
düzeltmesinden sonra da aynı dokuz test geçti.

## Yedinci uygulama yolculuğu

[app_journeys_test.dart](../integration_test/app_journeys_test.dart) içindeki
yeni akış, gerçek HomeSessionScope/router/hesap controller'ı, HTTP transportu
ve production kaynak ekranını kullanır:

1. Eski Direct HA bağlantısı ve düzeni kayıtlıyken Core cold start; listede
   eski ev görünmez ve HA isteği başlamaz.
2. PIN korumalı hesap ekranında gerçek sentetik üye login/context doğrulaması;
   yalnız izinli Salon ve Okuma lambası gösterilir, gizli kayıtlar görünmez.
3. Açık yenileme izin kaldırılmasını gösterir; sonraki yenileme boş görünümü
   gösterir. Eski Direct oda bu boşluğu dolduramaz.
4. Aynı adreste başka Core'a app remount ile geçilir; B etiketleri görünür,
   A etiketleri yoktur. A'ya dönüşte tersi gerekir. Her remount gerçek me/context
   isteği üretir; yalnız istek saymak doğru UI kanıtı sayılmaz.
5. Eski düzen değişmez; bütün HA HTTP girişleri, reddedilen HA loginleri,
   WS bağlantı/abonelikleri ve HA eylemleri sıfır kalır.

Paylaşılan tercihler ve secure storage bu harness'ta mock platform kalıcılığı
kullanır. Remount yeni widget/provider ağacı kurar; işletim sistemi process
restart'ı, native Keystore veya fiziksel tablet kabulü değildir. ACL değişimi
açık GET'te gözlenir; sürekli push yetki doğrulaması iddia edilmez.

## Son yerel kapı ve kalan kabul

Kaynak **`22ed208ce8f360ce76f5cadd8f47956bbcaacf45`**: dokuz fixture testi
geçti; altı Dart dosyasının analizi sıfır bulgu. Build runner ve çeviriler
önceden üretildi, bütün Flutter/Dart komutları ortak SDK kilidiyle çalıştı.
Loglar `/private/tmp/larenor-core-resources-e2e-fixture-final.log` ve
`/private/tmp/larenor-core-resources-e2e-analyze-final.log` içindedir.

Yeni Android koşusunda hedef dört native + yedi uygulama = **11 E2E**'dir;
bu henüz sonuç değildir. Birleşik Client testleri, gerçek yeni Android akışı,
yeni imzalı APK ve fiziksel ev/tablet kabulü ayrıca doğrulanmalıdır.
