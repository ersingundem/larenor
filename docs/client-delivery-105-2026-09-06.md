# Client105 — test işinin süre sınırında durduğu yayın

Kaynak `38e78a34bc554c39647a8616b905aa2f9c9627b9`. **Android teslimi
engellendi; imzalı APK105 üretilmedi.** Son tam doğrulanmış APK104 kalır.

| İlk deneme | Sonuç |
| --- | --- |
| [Android105](https://github.com/ersingundem/larenor/actions/runs/34015830766) | Cancelled: Flutter işi15dk sınırını aştı; imzalı iş skipped |
| [Core32](https://github.com/ersingundem/larenor/actions/runs/34015830774) | Başarılı; Linux3.311 PASS/0skip |
| [Security105](https://github.com/ersingundem/larenor/actions/runs/34015830712) | Başarılı;207PASS/24,502sn, gitleaks0, OSV başarılı |

## Tamamlanan ve tamamlanmayan testler

- Yerelde aynı uygulama/test ağacı5.056Client PASS/5:19;3.300Core PASS ve
 11Linuxskip verdi. İlk5.014PASS/4FAIL ile dar onarım [birleşim kaydında](prepared-vault-household-integration-2026-09-06.md) korunur.
- Uzak Flutter analizi0 ve966dosya biçim farkı0. Coverage koşusu **12:54 +4282**
 ilerlemesinde kesildi; `[E]` veya negatif sayaç yok, `All tests passed` yok.
 Bu kısmi ilerleme tamPASS değildir. GitHub annotation: `The job has exceeded
 the maximum execution time of 15m0s`. İş917sn; test adımı787sn.
- Core ve Android reusable Server işleri ayrı ayrı3.311PASS/0skip;
 CoreJUnit3311/0failure/0error/0skip. JVMXML98PASS/0skip. Sayılar toplanmaz.
- Başlamış E2E işi doğal tamamlandı: **4platform+13app=17PASS/0FAIL,
 133sıralı faz**. Hem job hem artifact logu exact-source registrar sırasıyla
 eşleşti. Eski10gövde/99faz ve üç yeni kişi/arşiv/admin senaryosu doğrulandı.

Emülatör36.1.9.0/build13823996,API35default/x86_64,pixel_4. Script
06:18:37.9020645Z→06:27:54.5357100Z = **556,633646sn/1080sn**;
bütün emülatör adımı617sn/1500sn. E2E başarısı yarım Flutter koşusunu veya
atlanmış imzalı işi başarılı yapmaz. Native/OS gerçek dosya seçimi ve
fiziksel Huawei/DeX kabulü bu sentetik arşiv akışından çıkarılmaz.

## Core yayını ve kanıtlar

amd64/arm64 smoke ve anonim kaynak/AGPL metadata doğrulandı. Stable ve
exact-source image index'i:
`sha256:821d3fa17fbdfbdb1ccfeda1929d862f41af07be0a2767d5c241e1ad0e692840`.
Katman indirilmedi; gerçek eve kurulum yapılmadı.

İlk başarısızlık makbuzu `/private/tmp/larenor-38e78a3-delivery-evidence.json`
değiştirilmedi; SHA256 `b8a8467341cc14de550959856ab7a08b561845bb89267ee3713f38b999e09863`.
Sonraki doğal E2E sonucu ayrı `/private/tmp/larenor-38e78a3-e2e-harvest.json`;
SHA256 `c3cc7b3a77c37c5664f06b62c4cc7e05e0c3069659e18da261096c58c8a51192`.
Job/annotation: `larenor-38e78a3-flutter-{job-metadata,annotations}.json`;
Flutter/E2E logları aynı private prefix altında. E2Eartifact9984066350 tek
transfer3828byte; öncekiXML'ler tekrar indirilmedi. APKtransfer0/rerun0,
bütün gözlem/harvest süreçleri kapandı.

[Dar CI bütçesi düzeltmesi](client-ci-budget-2026-09-06.md) yalnız iş süresini
15→25dk yapar; tekil test90sn ve tüm başarı kapıları aynı kalır.207yerel
politika testi ve bağımsız inceleme geçti. Yeni kaynak kendi CI kabulünü bekler.
S08.5/S08.6 henüz kabul edilmedi.
