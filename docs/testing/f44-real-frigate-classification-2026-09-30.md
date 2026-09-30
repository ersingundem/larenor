# F44 gerçek Frigate görsel sensörü — 30 Eylül 2026

Normal Core, Frigate 0.17 state classification modelinin gerçek kaydedilmiş
çıkarım karesini okur. Admin, mevcut izinli kamera, gerçekten eğitilmiş model
ve modelde bulunan sınıfı inline EN/TR Cupertino kurulumundan seçer. Güven,
algılama/sıfırlama beklemesi ve kare yaşı sınırları düzenlenebilir; önceki
ayarlar doğru revizyonla yüklenir. Kaynak, kural ve reducer sıfırlaması aynı
transaction içinde saklanır. Server yalnız metadata gönderen Client'ın
"algılama yaptım" iddiasını production gözlemi kabul etmez.

Gerçek sağlayıcı sınırı: HA Frigate registry/device/unique-id, güncel kaynak
revizyonu, servis kimliği, ACL ve `/api/profile.allowed_cameras` okunur. Model
etkin olmalı, en az iki sınıfı ve gerçek training metadata'sı bulunmalı.
Model/crop/eğitim revizyonu indirme öncesi/sonrası kontrol edilir. Frigate'in
attempt dosyası kamera kimliği içermediği için yalnız tek kameraya bağlı
modeller desteklenir; çok kameralı modelin kökeni tahmin edilmez. Bağlama anındaki
eski örnekler sonraki okumalarda yeni kanıt sayılmaz.

Kare, sabit model/train yolundan en fazla 4 MiB WebP olarak alınır. FFprobe
codec/dimensions sınırını ve FFmpeg gerçek decode'u doğrular: tek kare, en fazla
4096×2160/8.29 MP, 3 saniye, bir thread, sınırlı allocation ve yalnız file/pipe
protokolleri. Görüntü Client'a aktarılmaz veya kalıcı saklanmaz. Sadece gerçek
kare digest'i, sınıf/güven ve tazelik checkpoint'i yaşar. Kare eksikliği durumun
sıfırlandığını kanıtlamaz; retained okuma yaşlanınca `unknown` olur.

Frigate hostu eğitim/çıkarım için AVX+AVX2 ister; Core'un CPU mimarisi yerine
uzak host desteği uydurulmaz. Core eğitim yapmaz. Bunlar varsayım değildir:
[resmî state classification](https://docs.frigate.video/configuration/custom_classification/state_classification/),
[0.17.1 classification API](https://github.com/blakeblackshear/frigate/blob/v0.17.1/frigate/api/classification.py)
ve [0.17.1 çıkarım kodu](https://github.com/blakeblackshear/frigate/blob/v0.17.1/frigate/data_processing/real_time/custom_classification.py)
incelendi. Frigate tüm kararlı yüzde 100 örnekleri saklamadığı için bu adapter,
eski örneği yeni durum gibi göstermek yerine bilinmiyor durumunu korur.

Gözlemdeki `homeRevision` artık sabit veya şema sürümünden türetilmez. Kaynak
okumasının hemen öncesi ve sonrasında doğrulanan kamera arama otoritesinin gerçek
Home Resource Registry revizyonu hem sınıflandırma batch'ine hem de reducer
otoritesine aynen taşınır. Hesap, session family, kamera izni veya ev revizyonu
değişirse ikisi eşleşmez ve gözlem saklanmaz.

Doğrulama:

- F44 reducer/API ve 13 yeni normal Core/TCP sağlayıcı testi: **22 geçti**.
  Gerçek WebP, histerezis, restart/staleness, bozuk kare, değişen izin/model,
  yanlış dosya adı, eğitim/çok-kamera/crop reddi, iptal, atomik rollback ve
  sahte HTTP metadata gözlemi reddi kapsanır.
- Flutter feature paketi: **19 geçti**, açık izolasyon runnerı varsayılan koşuda
  ayrı atlandı; runner ile **1 gerçek Client→Core→TCP Frigate testi geçti**.
- Odaklı Flutter analyze temiz; container policy **21 geçti**.
- Server imajı FFmpeg/FFprobe ve gerçek ELF bağımlılıklarını build stage'de
  hazırlar, runtime nonroot/kurulumsuz kalır. Son imaj her iki binary'yi nonroot
  olarak çalıştırır. Bu yerel hostta Docker yok; iki mimaride exact-image build,
  smoke ve final exact HEAD CI henüz kabul edildi sayılmaz.
- Ek normal-Core regresyonu, birden büyük gerçek registry revizyonunun hem batch
  hem reducer otoritesinde aynı olduğunu doğrular. Odaklı F44 reducer ve gerçek
  Frigate sağlayıcı koşusu **21 geçti**; `py_compile` temizdir.

Fiziksel kamera, gerçek eğitimin doğruluğu/gece-gündüz çeşitliliği ve native UI
kabulü ayrı kapılardır. Bu sensör erişim kontrolü/kilit açma kimliği değildir.
Sayaçlar 37/126 ve 3/63 olarak değişmedi.
