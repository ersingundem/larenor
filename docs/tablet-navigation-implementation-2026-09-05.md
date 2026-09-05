# B5.1 — ortak tablet gezinmesinin ilk düzeltmesi

5 Eylül 2026. Bu kayıt ortak tablet temelinin ilk alt adımıdır; bütün ekranların
son tasarım geçişi veya gerçek Huawei/DeX/TalkBack kabulü değildir.

Dar DeX/tablet penceresinde alt sekmelerin yalnız dokunma davranışı vardı;
Enter ile gezinme çalışmıyordu. Sabit yükseklik, iki kat yazı boyutunda simge
ve etiketin arasındaki boşluğu da tüketiyordu. `dc5cd12` bu iki davranışı
başarısız testle kaydetti; `41125a5` ile ortak `AppNavigationBar` eklendi.

Mevcut renk, yazı ve köşe düzeni korunur. `CupertinoButton` tabanlı dört hedef
en az 48×48 alan, framework odak halkası, Tab/Shift+Tab sırası ve Enter/Space
etkinleştirmesi sunar. Yükseklik etiketlere göre büyür; sistem yazı ölçeği
kısılmaz. SafeArea alt ve yan alanı korur. Seçili hedefin zemini, yazı ağırlığı
ve semantics selected durumu birlikte değişir. Etiket, buton ve sekme sırası
ekran okuyucuya aktarılır; simgeler ikinci bir yinelenen etiket üretmez.

999→1000→999 pencere geçişinde yan menü ile alt gezinme aynı branch'leri
kullanır. Oda seçimi ve kaydırma konumu korunur; mevcut PIN, dialog ve genel
kısayol testleri değişmeden çalışır. Android E2E'nin locator'ları yeni ortak
bileşene taşındı; yolculuk adımları, assertion'lar ve temizlik azaltılmadı.

**97 odaklı/regresyon testi geçti.** Bunların 16'sı EN/TR × açık/koyu ×
320/800 genişlik × 1×/2× yazı matrisinde gerçek dokunma, semantics, klavye
sırası ve yerleşimi sınar. Ortak bileşenin ilk ölçümünde 47/47 satır; AppShell
96/107 satır çalıştı. Satır kapsamı gerçek TalkBack veya fiziksel cihaz kabulü
anlamına gelmez.

`apple-design` ile erişilebilirlik, düzen, renk, tipografi ve odak ilkeleri
incelendi. Gerçek Inter/Cupertino fontlarıyla 10 özel render koşusunda
etiket/ikon/seçim/odak için 30 PNG kontrol edildi. Açık temanın ilk framework
odak rengi yaklaşık 1,8:1 kontrasttaydı; `a7fd95f` RED → `f1c45f1` GREEN ile
çözülmüş tema rengi kullanıldı. Test artık gerçek odak dekorasyonunu hem
gezinme hem seçili zeminle en az 3:1 karşılaştırır; açık/koyu matris yeniden
geçti. Hedef, [W3C metin dışı kontrast ilkesidir](https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast.html);
uygulamanın tamamı için WCAG sertifikası iddia edilmez.

Görseller özel QA çıktılarıdır. README'nin son tablet galerisi, plandaki bütün
frontend işleri bittikten sonra üretilecek. [B5 kuyruğu](EXECUTION_QUEUE.md)
kart/form/durum sözleşmelerini ve kalan ortak ekran kabulünü açık tutar.

## Bölüm başlıkları ve oda menüleri

`e3d884b` runtime RED, ortak başlıkların ekran okuyucuya heading olarak
aktarılmadığını ve dashboard'un simgeli oda menülerinin adsız, 44×44 hedefler
olduğunu gösterdi. `8a7b31e` GREEN ile `SectionHeader` başlığı ayrı heading
semantics'i taşır; yanındaki eylem başlığa katılmaz. Aynı ortak bileşeni
kullanan dashboard, Jellyfin ve ARR başlıkları bu davranışı paylaşır.

Dashboard oda menüsü Türkçe/İngilizce oda adıyla, servis ve bileşen düzenleme
düğmeleri ilgili bölüm adıyla anons edilir. Native Cupertino butonunun
rolü/odak/etkinleştirme davranışı korunur; ikon etiketi ikinci kez okunmaz.
Bu menülerin hedefi en az 48×48 olur. Görünen simge, yazı ve renkler değişmez.

**12 odaklı test**; ortak widget, dashboard ve gezinme paketiyle **522
regresyon geçti**. EN/TR, 600/1.200 piksel tablet penceresi ve iki kat yazıda
başlık/eylem ayrı düğümler, tek etiket, hedef boyutu, Space ve semantics tap
ile gerçek menü/editor açılışı sınanır. Menü açmak düzeni kaydetmez veya silme
eylemini çalıştırmaz. Dört Dart dosyasının analizi/biçim kontrolü temizdir;
bağımsız kök incelemesinde P1/P2 bulgu kalmadı.

Satır kapsamı: ortak başlık **17/17**, değişen dashboard başlık fonksiyonu
**11/11**. Eski büyük dashboard dosyasının tamamı bu regresyonda **499/691
(%72,2)**; fonksiyon kapsamı bütün ekranın kapsamı gibi sunulmaz. Tam Client
ve uzak CI sonucu [PROGRESS](PROGRESS.md) içinde kendi kaynak commit'iyle
ayrılır. Önceki `1408e80` CI'ı yalnız gezinmenin önceki adımını kapsar.

Son `3076f5f` kaynak paketinde **2.701 tam Flutter testi geçti**, tam analiz
temiz. Ayar satırlarının klavye erişimi ve uzun adres taşması sonraki bağımsız
tablet dilimidir; bu doğrulanmış paketin çalışma kopyası sabit tutulur.
