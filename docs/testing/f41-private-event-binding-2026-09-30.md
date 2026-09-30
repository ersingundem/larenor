# F41 → F42 kalıcı özel olay yetkisi — 30 Eylül 2026

F41'in gerçek Frigate aramasından en fazla 120 saniye önce görülmüş bir sonuç,
F42 dönüşümü için Core içinde AES-GCM ile mühürlenir. Native olay kimliği,
provider adresi ve kimlik bilgileri Client'a çıkmaz. Mühür en fazla yedi gün
yaşar; hesap, ev, kaynak, servis, kamera kaydı ve ACL revizyonlarına bağlıdır.
Yeni klip okuması tam olay metadatasını ve güncel Frigate kamera iznini indirme
öncesi/sonrası doğrular; sabit `clip.mp4` yolu ve 64 MiB sınırı uygulanır.
İptal edilmiş istek, değişmiş izin veya olay içeriği byte döndüremez.

Mühür restart ve arama önbelleği süresinin dolması sonrasında doğrulanır.
Frigate'in orijinal olayı silmesi, önceden oluşturulmuş ayrı şifreli paylaşımın
kendi alıcı/süre/iptal politikasını geçersiz kılmaz; yeni dönüşüm için gerçek
klibin hâlâ mevcut olması gerekir. Bu ayrım henüz F42'nin tam ürün kabulü değildir.

Doğrulama: normal Core ve gerçek TCP Frigate/HA fixture üzerinden 8 mühür testi;
F41 normal kaynak, arama ve API regresyonlarıyla birlikte 40 test geçti.
Testler restart, önbellek süresi, orijinalin silinmesi, mühür değişikliği,
süre sonu, iptal, metadata değişikliği ve indirme sırasında izin kaybını kapsar.
Fixture kontrollü gerçek ağ servisidir; fiziksel kamera kabulü değildir.

Resmî sağlayıcı sözleşmesi: [Frigate API](https://docs.frigate.video/integrations/api/).
F42 gerçek FFmpeg maskelemesi, şifreli artifact, Client ve final exact HEAD CI
ayrı kapılardır. Sayaçlar 37/126 ve 3/63 olarak korunur.
