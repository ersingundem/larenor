# Native karakterizasyon runner kapısı

Bu değişiklik, ilgili native girdi değişmeyen pull request'lerde Jellyfin,
qBittorrent, Arr, Seerr ve Music Assistant matrislerinin runner ayırmasını
önler. Test kapsamı yalnız `native_ci_scope.py` tarafından exact base/head
farkında değişmediği kanıtlanan bileşenler için yeniden kullanılır.

Tam üç kabul ölçütü vardır:

1. Her pahalı matris işi `native-scope` sonucunu iş seviyesinde denetler. Sonuç
   `false` ise matris oluşturulmadan iş `skipped` olur; ilgili native kaynak,
   workflow veya ortak substrate değiştiğinde amd64/arm64 matrisi aynen çalışır.
2. Her workflow benzersiz, daima raporlanan bir acceptance işi taşır. Scope
   `true` iken yalnız başarılı matrisi; `false` iken yalnız `skipped` matrisi
   kabul eder. Scope hatası, belirsiz sonuç veya beklenmeyen durum fail-closed
   olur.
3. Branch protection yalnız bu beş sabit acceptance sonucuna geçirildikten
   sonra eski mimari başına required context'ler kaldırılır. Geçiş, workflow
   değişikliğinin kendi PR'ında bütün eski native matrisler geçtiğinde yapılır;
   böylece required-check boşluğu oluşmaz.

Yerel politika kapısı beş workflow'un exact job bağımlılığını, koşulunu,
runner seçimini ve aggregator durum tablosunu doğrular. Servislerin mevcut
workflow güvenlik testleri de action pinleri, iki gerçek mimari, kapalı olay
kaynağı ve makbuz sırasını korur. Bu teslim ürün kuyruğunda bir işi kapatmaz;
ilerleme sayaçları değişmez.
