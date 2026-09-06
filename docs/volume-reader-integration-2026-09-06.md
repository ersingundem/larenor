# Volume okuyucusu — ayrı Core birleşimi

Kaynak `3d9075fc412f4c9ef387a74c976070c83bdc4b7e`, taban
`a27abeaa55a2ea94a0a0eaec1b9a74743c086a9c`; birleşen dal
`0d86fa17ea4410a44bc6df878c106a013a8733c6`.
Bu ayrı yerel paket, CI101'deki kaynağa eklenmedi.

Yalnız doğrulanmış Unix Engine volume GET ve mevcut kalıcı journal'a bağlı
gözlem eklenir. Ad/etiket/binding tekrar doğrulanır; tarihi kayıt yeni
ölçüm veya volume oluşturma/kurulum izni değildir. Detaylar ve RED/GREEN
checkpoint'leri [uygulama kanıtında](managed-volume-read-transport-implementation-2026-09-06.md).
Root ilk kaynak ile son iptal/kimlik değişimi düzeltmelerini bağımsız inceledi;
somut P1/P2 bulunmadı.

## Birleşik yerel doğrulama

6 Eylül 2026'da exact `3d9075f` üzerinde tam Server koşusu:
**3.192 PASS / 11 Linux skip / 313,35 saniye (5:13)**. JUnit3.203 toplam
vaka, 0failure/error ve11skip ile uyuşuyor. İki mevcut deprecation uyarısı
var. Atlamalar Linux peer/procfs/mount/FD yollarıdır; yeni Linux CI bu
kaynak üzerinde ayrıca çalışmalıdır. Önceki CI'nin Linux kanıtı yeni
okuyucuya taşınmaz.

```text
PYTHONPATH=. LARENOR_TEST_APKSIG_JAR=<pinned apksig9.1.0 jar>
PATH=<Java17>/bin:$PATH <reviewed Python>/bin/python -m pytest tests
  --junitxml=/private/tmp/larenor-volume-reader-integration-server.xml
```

Özel tam log `/private/tmp/larenor-volume-reader-integration-server.log`.
11 yeni commit için redakte gitleaks taraması temiz; queue validate ve
diff-check geçti. Client/Android/integration test/CI/tool/pubspec farkı
bu birleşimde yok; yeni bir tam Flutter koşusu yapılmış sayılmaz.

Önceki dalın odaklı371 PASS/1Linuxskip ve yeni iki modülde94/94statement,
28/28branch kapsamı kendi final kaynak kanıtıdır; bu tam koşuya toplanmaz.

## Açık kalanlar

Bu paket için uzak CI, iki mimarili container ve bağımsız APK kabulü henüz
yok. Gerçek ev Engine'i kullanılmadı; fiziksel kuruluma geçilmedi.
UID/bootstrap, üretim worker/HTTP yetkisi, volume yaratma/adopt ve kurulum
etkileri ayrı kalır. `installAvailable=false` sürer. S06.3d bu alt dilim
nedeniyle tamamlandı işaretlenmez.

## Logout ile sonraki birleşim

`2911ac9` logout düzeltmesi ve yalnız doküman takibiyle birleşen kaynak
`091b2bb22014116d29c4d212c9484cd2c4207c0e` tam **4.415 Client testi /
5:05 PASS** verdi. Kilitli pubget, build_runner ve l10n üretimi tamamlandı.
Özel log `/private/tmp/larenor-next102-full-client.log`. Server kaynak/test
farkı `3d9075f` ile boş; yukarıdaki tam Server sonucu aynı Server ağacına
aittir. Yeni onuncu Android logout yolculuğu bu koşuya henüz dahil değildir.

Logout kaynak ve testleri root tarafından son `2911ac9` delta'sında da
incelendi; yeni P1/P2 bulunmadı. [Logout kanıtı](core-logout-boundary-implementation-2026-09-06.md).
Bu birleşim henüz push edilmedi; CI101 yalnız `a27abea` kaynağını kapsar.

Tam analiz **0 bulgu / 6,3 saniye**; formatter **896 dosya / 0 fark /
2,96 saniye**. Özel loglar `larenor-next102-analyze.log` ve
`larenor-next102-format.log` (`/private/tmp`). Bu ölçümler dokuz Android
yolculuğu içeren `091b2bb` kaynağındadır.

## Onuncu Android yolculuğu birleşimi

`0bf1258909197d53bdea693394f56749ad103f5d` test dilimi
`cb18dde2682faf988aa4426ff05387a8b1ea5274` ile birleşti. Üretim, Server,
Android native, CI araçları ve pubspec önceki `091b2bb` ile aynı. Root son
kaynak/doc incelemesi CLEAR; eski9yolculuğun gövde SHA-256'sı ve89işaret
prefix'i ayrıca yeniden doğrulandı. Yeni toplam10uygulama/99işaret;
dört native ile14 E2E hedefi. [Yolculuk kanıtı](core-logout-android-journey-2026-09-06.md).

Birleşimde integration_support **87 PASS / 4 saniye**, tam analiz **0bulgu /
2,8 saniye**, formatter **897dosya / 0fark / 2,60 saniye**. Özel loglar
`/private/tmp/larenor-next102-e2e10-{support,analyze,format}.log`. İki yeni host
testi önceki4.415 tam Client koşusuna dahil değildir; sonuçlar tek tam koşu
gibi toplanmaz. Bu yeni Android yolculuğu henüz emulator üzerinde çalışmadı.
Yalnız aynı süreçte sentetik depolama ile remount sözleşmesi kullanılır;
native Keystore veya OS restart kabulü değildir.

Restore prepared/journalv2/BackupScreen ve ServerVault geçişi bu pakete
alınmadı; ayrı S08.5 devam işidir.
