# S08.6 — ayrı hane kişisi sözleşmesi

6 Eylül 2026; taban `61799880b69438c908a5d4523fadeec88bd2ec82`, ilk GREEN
`8100fba`. Bu dar dilim veri sözleşmesidir; henüz yeni HTTP uç noktası,
veritabanı tablosu veya Android kişi ekranı sağlamaz.

## Davranış

Hane kişisi `PersonRef` ile açık `kind=person`, Core/ev ve kalıcı kişi ID'si
taşır. Eski `ResourceRef` yalnız `room|resource` kabul etmeye devam eder.
Yeni kişi oluşturma isteği yalnız görünen ad ve sıra içerir; çağıran kişi
ID, hesap, rol, izin veya upstream HA eşlemesi veremez. Hesapsız aile profili
giriş hesabı veya yetki yaratmaz.

Kayıt ve erişim revision'ları ayrıdır. Düzenleme her iki beklenen revision'ı
zorunlu tutar; grant subject açık bir giriş hesabı ID'sidir, hedef ayrı kişi
referansıdır. Saklanan kaldırılmış izin bulunmaz. Alanlar kapalı ve sınırlı,
bool/sayı coercion kapalı; iç içe model kopyaları kullanımda tekrar doğrulanır.
Doğum tarihi, sağlık, konum, yüz verisi ve parola bu sözleşmede yoktur.

## Yerel kanıt

- `6c4ca66`: **46 FAIL**, eksik modül sözleşmesi RED'i. Commit başlığındaki
  **47** sayısı hatalıdır; gerçek logda 46 `ModuleNotFoundError` vardır.
  Bu, mevcut üretimdeki 46 hatanın keşfi anlamına gelmez. Tarihçe değiştirilmedi.
- `8100fba`: **46 PASS / 0,03 saniye**; yeni model implementasyonu GREEN.
- Aynı kaynakta yeni kişi + eski kaynak model/yetki testleri **92 PASS /
  0,09 saniye**. İki mevcut bağımlılık deprecation uyarısı var.
- Yeni modül **43/43 statement, 2/2 branch** kapsamı; projenin toplam kapsamı
  veya uçtan uca özellik kabulü değildir. `git diff --check` temiz.

Komut, Server klasöründe mevcut kilitli proje Python ortamıyla:

```text
PYTHONPATH=. python -m pytest tests/test_home_people_models.py
PYTHONPATH=<coverage helper>:. python -m coverage run --branch
  --source=larenor_server.home_people -m pytest
  tests/test_home_people_models.py tests/test_home_resource_models.py
  tests/test_home_resource_authorization.py
```

Özel kanıtlar `/private/tmp/larenor-home-people-models-{red,green,regression}.log`
ve karşılık gelen GREEN/regression JUnit XML'leridir. Yeni CI veya bağımsız
karşı inceleme henüz yapılmadı. Paket102'nin dondurulmuş üretimine dahil değil.

## Sonraki bağımlı teslim

Kişiler ayrı `/api/v1/home-people/{core_id}/{home_id}` ailesinden sunulacak;
mevcut oda/kaynak listesinin yanıtları değişmeyecek. Önce ayrı şifreli SQLite
saklama alanı, ayrı kriptografik domain, atomik ek migration ve eski DB'nin
korunması uygulanmalı. Aynı transaction içinde güncel token/kullanıcı/rol/
Core/ev/ACL denetimi yapılmalı. Üye yalnız açık izinli kişiyi görmeli;
liste snapshot/cursor gizli kişiler hakkında bilgi vermemeli.

Bu devam işi gerçek HTTP/auth/SQLite, yeniden açma, bozuk kayıt, kota,
yetki/sürüm yarışı ve eski Client sözleşmesi testleriyle tamamlanmalı.
Ardından Android ortak form/PIN/yenileme/kullanıcı değişimi ve tablet kabulü
gelir. Bu sözleşme tek başına **S08.6 veya 63 yeni özellikten birini kapatmaz**.
