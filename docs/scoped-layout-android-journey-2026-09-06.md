# S08.4 — Android'de PIN ve kaynaklı oda kopyası yolculuğu

6 Eylül 2026. Taban `394de0f`, dal `codex/scoped-layout-e2e`.
Bu belge eklenen testin kapsamını kaydeder; henüz Android emülatör sonucu
veya S08.4 tamamlanma kabulü değildir.

Altıncı uygulama yolculuğu gerçek `HomeSessionScope`, `SettingsGate`,
`ServerAccountController`, HTTP istemcisi ve dashboard repository provider'ını
kullanır. Yalnız test sürecinin sahip olduğu tam loopback portuna erişilebilir;
HA REST/WS dahil diğer isteklerin toplam sayısı sıfır olmalıdır. Yanlış tokenla
reddedilen HA GET de bu sayaçta görünür.

1. Eski HA bağlantısı ve cihaz düzeni varken Core kaynağında açılır; bunları
   kullanarak HA'ya istek yapamaz.
2. Yanlış PIN hesap ekranını açamaz; doğru PIN ardından gerçek HTTP login ve
   context yanıtı Core kimliğini doğrular.
3. Yeniden PIN ile açılan kaynak ekranında Core düzeni boştur. Açık önizleme
   yalnız sentetik yerel oda adını gösterir. Oda seçimi ve onay ayrı eylemlerdir;
   onaydan önce Core düzen kaydı oluşmaz.
4. Başarı ekranı ardından preferences platform deposu yeniden okunur. Tek
   kayıttaki Core/ev/kullanıcı tuple'ı doğrulanır; entity/alan/favori bağlantıları
   kopyalanmamış ve eski kayıt değişmemiş olmalıdır.
5. Uygulama ağacı kaldırılıp yeniden kurulur; saklı oturum gerçek `me` ve
   `context` GET ile tekrar doğrulanır. İlk Core kendi düzenini görür; aynı
   adresteki ikinci Core boş kalır; ilk Core'a dönüş kendi düzenini geri getirir.

Fixture içindeki tercihler ve secure storage sentetiktir. Aynı süreçte uygulama
ağacını yeniden kurmak provider/oturumun yeniden edinimini ve plugin deposundan
okumayı sınar; Android süreç ölümü, fiziksel disk, kaldırıp kurma veya gerçek
ev sunucusu kabulü değildir. Gerçek cihaz yeniden kurulum/güncelleme testi son
manuel kabulde kalır. Üç kimlik alanının tek tek değişimi, eski dialog callback'i,
pending/expiry ve başarısız yazı vakaları üretim diliminin ayrı unit/widget
testlerinde izlenir.

## Yerel kanıt

- `3d98864`: eksik loopback Core fixture için RED checkpoint; davranış testi
  derlenemedi. Bu, Android yolculuğunun RED sonucu olarak sunulmaz.
- `70a8cf8`: bounded Core fixture; üç gerçek loopback testi geçti. İlk GREEN
  denemesi Flutter'ın varsayılan HTTP blokajıyla hata aldı; test istemcisi
  mevcut tam loopback sınırından oluşturulunca gerçek HTTP yanıtları doğrulandı.
- Bağımsız erken incelemenin iki bulgusu düzeltildi: reddedilen HA istekleri
  toplam sayaca eklendi; kayıt yalnız bellek cache'inden değil başarı UI'sı
  ve `preferences.reload()` ardından doğrulanıyor.
- Son **dört loopback test PASS**, beş dosya analizinde sıfır bulgu. Repo'nun
  ortak Flutter kilidi kullanıldı. Loglar:
  `/private/tmp/larenor-scoped-e2e-fixture-final.log` ve
  `/private/tmp/larenor-scoped-e2e-analyze-final.log`.

Yeni yolculuk mevcut Android E2E hedefinde otomatik bulunur; workflow timeout
veya filtreleri değiştirilmedi. Üretim S08.4 birleşimi sonrası tam yerel Client
kontrolü ve exact-source uzak Android CI sonucu ayrıca kaydedilecektir.
