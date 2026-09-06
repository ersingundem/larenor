# Client106 — tam doğrulama sürüyor

GitHub'a gönderilen kaynak `e7c15ad6f62352f77379e369f3e8524028c42aab`.
Önceki yayına göre uygulama ve test ağaçları aynıdır; yalnız Flutter CI işinin
toplam bütçesi 15 dakikadan 25 dakikaya çıkarıldı. Tekil test sınırı, coverage,
E2E beklentileri ve yayın önkoşulları korunur.

| İlk deneme | Son gözlenen durum |
| --- | --- |
| [Android106](https://github.com/ersingundem/larenor/actions/runs/34016755111) | Çalışıyor; tam test, E2E ve imzalı APK kabulü açık |
| [Core33](https://github.com/ersingundem/larenor/actions/runs/34016755141) | Başarılı; 3.311 Linux PASS / 0 skip, iki mimarili smoke ve anonim yayın doğrulandı |
| [Security106](https://github.com/ersingundem/larenor/actions/runs/34016754957) | Başarılı; 207 PASS / 24,764 saniye, gitleaks0 ve OSV başarılı |

Bu tablo canlı servis değildir; son doğrulanan gözlemdir. Bağlantılar
GitHub'daki anlık durumu gösterir. Tek gözlemci aynı kaynak ve ilk denemeye
ait sonuçları toplar. Başarı olmadan tekrar koşu, APK indirme veya kabul
yapılmaz.

## Mevcut yerel kanıt

Aynı uygulama/test ağaçları `bd9d425` üzerinde **5.056 tam Client PASS**,
tam analizde sıfır sorun, 966 dosyada sıfır biçim farkı verdi. CI bütçesi
onarımı **207 politika testi** ve bağımsız incelemeden geçti.
[Bütçe onarımı](client-ci-budget-2026-09-06.md) ve
[birleşim kanıtı](prepared-vault-household-integration-2026-09-06.md)
başarısız denemeleri de korur. Bu yerel sonuçlar CI106 başarısı sayılmaz.

CI105'in 15 dakika sınırı nedeniyle yarım kalan Flutter koşusu ve sonradan
doğal tamamlanan **17 E2E / 133 faz** sonucu
[ayrı tarihsel kayıtta](client-delivery-105-2026-09-06.md) korunur.
CI106 aynı 17 yolculuğu ve 133 fazı kendi kaynağında yeniden doğrulamalıdır.

Yeni Core eklenti kataloğunun tablet erişilebilirlik dalı bu kaynakta yoktur;
ayrı birleşim/test sürecindedir. S08.5 ve S08.6 henüz kabul edilmedi.
Son tam doğrulanmış imzalı paket [APK104](client-delivery-104-2026-09-06.md)
olarak kalır. Gerçek eve kurulum, OS dosya seçicisi ve fiziksel Huawei/DeX
kabulü ayrı açık işlerdir.

Core ve Android reusable Server işleri ayrı ayrı 3.311 PASS / 0 skip verdi;
süreler 465,43 / 467,58 saniye. Native JVM XML 98 PASS / 0 skip. Bu sayılar
birbirine eklenmez. Anonim exact-source/AGPL ve amd64/arm64 manifest/config
doğrulandı; stable ile immutable image index eşleşti:
`sha256:5aad0b0f8c5837e522528cb99e3bb50b2053f906ab906a732c0d86aa26cca5de`.
İmaj katmanı indirilmedi; Android tam Flutter/E2E ve APK106 kabulü açık.
