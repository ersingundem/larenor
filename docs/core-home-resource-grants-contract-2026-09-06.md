# Core kaynak yetkileri — gerçek sözleşme ve Client taşıması

S08.6'nın bu dilimi, mevcut Core yetki uçlarını Android Client'ta katı bir
veri modeli ve taşıma API'siyle eşleştirir. Henüz bir kullanıcı seçimi veya
ACL düzenleme ekranına bağlı değildir. Gerçek evde yetki değiştirilmedi.

## Davranış

`GET /admin/home-resources/{core}/{home}/{record}/grants` mevcut erişimleri
okur. Aynı yolun `/{subject}` ekli `PUT` isteği, beklenen ACL sürümüyle erişim
verir/değiştirir; `read=false, write=false` erişimi kaldırır. Aynı değerle
tekrar edilen istek sürümü artırmaz; gerçek değişiklik tam bir artırır.
Core her istekte kullanıcının güncel yönetici yetkisini denetler.

Client listesi immutable, kullanıcı kimliğine göre sıralı ve en fazla 128
kayıttır. Yanıtlar tam Core/ev/kayıt/tür/kullanıcı kimliğine ve beklenen ACL
sürümüne bağlanır. Sayısal türler, JSON alanları ve read/write ilişkisi
denetlenir; başka ev, sürüm gerilemesi, eksik/ek alan veya yanlış erişim
sonucu kabul edilmez. Kimlik hatası, kapasite ve sürüm tükenmesi HTTP'den
önce durdurulur. Değişiklik sırasında kapanan taşımanın geç yanıtı uygulanmaz;
bilinmeyen sonucu kurtarmak için PUT otomatik tekrarlanmaz.

GET, metadata listesinden daha yeni ACL sürümü okuyabilir. Bu snapshot
kullanıcının yetkili olduğunu kanıtlamaz ve cihaz komutu yetkisi vermez.

## Test ve inceleme

`contracts/home-resource-grants.v1.json`, gerçek FastAPI, kimlik doğrulama,
SQLite ve şifreli yerel depolamayla üretilir. Yalnız sentetik kimlikler ve
kaynak/izin metadata çıkarılır; token/parola/şifreli değer dışarı verilmez.
Sunucudan okuma→read-only→no-op→ikinci kullanıcı→upgrade→revoke→no-op
yanıtları alınır. Üye erişiminin 200'den 404'e dönmesi, üyeden yönetici
uçlarına 403, eski sürüme 409 ve geçersiz read/write için 400 doğrulanır.

| Aşama | Kanıt |
| --- | --- |
| Gerçek Server fixture RED `7d6e285` | 1 PASS / eksik fixture nedeniyle 1 FAIL |
| Gerçek Server fixture GREEN `4625bc2` | 2 PASS |
| Client runtime RED `7972f4c` | 31 PASS / 15 FAIL; çalışan güvenli stub |
| Client GREEN `6a85581` | 46 PASS |
| Sınır ve taşıma genişletmesi `1f4614e` | 53 odaklı PASS, analiz 0 |
| İlgili Client regresyonu | 709 PASS; home_resources + server |
| İlgili gerçek Server regresyonu | 131 PASS; 2 mevcut bağımlılık uyarısı |
| Yeni iki üretim modülü | 108/108 satır; %100 satır kapsamı |
| Bağımsız kaynak incelemesi | Model/API/actual fixture CLEAR; yeni P1/P2 yok |

709 testi geçen kaynakla son kaynak arasındaki üretim farkı yalnız lint
parantezleridir; son 53 odaklı test bu son kaynakta ayrıca geçti. İlgili test
kümeleri örtüşür ve benzersiz toplam oluşturmak için toplanmaz. İlk fixture
denemesinde yanlış beklenen 422 yerine gerçek Core'un 400 sözleşmesi
düzeltildi; ilk Dart hazırlığındaki eksik generated dosya da test RED'i
sayılmadı. Yukarıdaki RED kayıtları gerçek çalışan assertion sonuçlarıdır.

## Açık kabul koşulları

Güncel Core hesabına, PIN/rota/pencere sahipliğine bağlı ACL controller ve
tablet ekranı; mevcut Core kullanıcı listesinden seçim; belirsiz yazıdan
sonra açık yeniden okuma; gerçek Android E2E ve yeni birleşim CI'ı henüz
bu dilimin kanıtı değildir. S08.6 ve yeni özellik sayaçları değişmez.
