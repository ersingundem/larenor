# S08.6 — kaynak erişimi sonrası kalan kimlik dilimleri

6 Eylül 2026; kaynak `a27abeaa55a2ea94a0a0eaec1b9a74743c086a9c`.
Bu belge mevcut kod ve kabul bağımlılıklarının incelemesidir. Yeni bir test
koşusu, hane kişi uygulaması veya S08.6 tamamlanma kanıtı değildir.

| Sözleşme | Mevcut kanıt | Kalan sınır |
| --- | --- | --- |
| Oda/kaynak kimliği | Server üretimli sabit ID, şema1/Core/ev, ayrı metadata ve ACL revision; şifreli kalıcılık/restart testleri | Yeni hane kişi türü bugün yok |
| Hesap bazlı okuma/yazma | Güncel kullanıcı/rol/token/ev/ACL aynı DB transaction içinde denetlenir; başkasının gizli kaydı404 olur | Bu karar fiziksel cihaz komutu değil |
| Metadata yönetimi | Oluşturma/ad/sıra/silme gerçek PIN ekranı ve APK100'de sekizinci yolculuk | ACL yolculuğu exact a27/APK101 ile geçti |
| Kaynak erişim yönetimi | Gerçek Core kullanıcı listesinden seçim, read/read-write/revoke, stale revision ve belirsiz yanıt sınırı; yerel test/inceleme geçti | Exact a27 CI101 ve bağımsız APK101 geçti; hane kişisi ayrı açık |
| Hane kişisi | Grant subject yalnız mevcut `users.id` | Hesapsız aile profili, kalıcı kişi referansı ve kendi erişim sözleşmesi ayrı uygulanmalı |

## Kişi kimliği için sıradaki küçük teslim

Hane kişisi, giriş hesabından ve HA `person` kaydından ayrı bir yerel ev
metadatası olmalıdır. İlk kapsam yalnız Server üretimli kişi ID'si, mevcut
Core/ev, görünen ad, sıra ve revision'dır. Doğum tarihi, sağlık, konum, yüz
verisi veya hesap erişimi bu kayıttan türetilmez. Kişi oluşturmak login
hesabı ya da yetki yaratmaz; admin olmak kişisel kasalara erişim sağlamaz.

Uygulama başlamadan mevcut oda/kaynak wire şeması ve SQLite migration
uyumluluğu kesinleştirilmeli. Mevcut `ResourceRef.kind`, CreateRecordRequest
ve DB CHECK yalnız `room|resource` kabul eder; Client da kapalı model kullanır.
Bunlara tek taraflı `person` ekleyip eski Client'ı aynı listede bozuk yanıtla
karşılaştırmak bir uyumluluk çözümü değildir. Kişi için açık ayrı API/model
veya yetenek pazarlıklı sürümlü sözleşme gerekir. Eski DB/Core downgrade
sınırı, şifreli kayıt ve izinlerin korunması migration testinde gösterilmeli.

İlk gerçek kabul yolu: admin PIN altında kişi oluşturur, adını değiştirir,
üyenin açık iznini yönetir; üye yalnız izinli kişiyi görür. İzin iptali ve
kullanıcı/ev değişimi eski listeyi ve callback'i kapatır. Kişi silme yalnız
Larenor'un yerel kişi kaydını etkiler; auth kullanıcısı veya upstream HA
kişisi silinmez. Client ortak kayıt/kart/form dilini kullanır; EN/TR2×,
klavye ve tablet/DeX penceresi testleri bu teslimin içindedir.

Gerçek HTTP/auth/SQLite, restart, revision/ACL yarışı, kota, bozuk kayıt,
kullanıcı devre dışı bırakma, başka Core/ev, gizli cursor/snapshot ve eski
Client uyumluluğu RED→GREEN ile doğrulanır. İsim eşitliğinden kişi/hesap veya
HA eşlemesi yapılmaz; ileride eşleme ayrı açık onaylı bağdır.

## Bağımlılıkta tutulması gereken ayrım

S08.7, S08.5 ve S08.6'dan sonra ilk gerçek HA kaynak/komut ve açık upstream
eşlemesini uygular. S08.8–9 diğer adaptörleri, S08.10 olay/sonuç/taşımayı
kapsar. Bu gerçek adaptörleri S08.6'nın önkoşulu yapmak döngü oluşturur.
S08.6 kapsamında bugün saklanan write kararı komut çalıştırıldı anlamına
gelmez; kaynak/subject kimliği ve güncel yetki sözleşmesi için kanıttır.

ACL ekranı alt dilimi exact a27/CI101 ve bağımsız APK101 ile kabul edildi; bu
sonuçla hane kişi modeli veya tüm merkezi adaptörler tamamlandı sayılmaz.
