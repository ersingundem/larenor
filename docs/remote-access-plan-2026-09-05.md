# Uzak erişim — bağımsız VNC, RDP ve SSH

**5 Eylül 2026 · Kullanıcı tarafından onaylandı · F61–F63 planlandı.**
Bu bölüm Proxmox'a bağlı değildir. Windows/Linux bilgisayar, fiziksel sunucu,
NAS, Raspberry Pi veya erişim hizmeti açık başka bir cihaz IP/alan adıyla
eklenebilir. Yeni protokol ekranları henüz uygulanmadı.

## Mimari kararı

**Oturum ve görüntü/terminal motoru Android Client'ta çalışacak.** Tablet
hedefe LAN, kullanıcının mevcut VPN'i veya açıkça seçtiği SSH geçidi üzerinden
bağlanır. RDP/VNC görüntüsü ve klavye trafiği normal Core JSON API'sine
taşınmaz. Proxmox konsolu, uygun olduğunda aynı oturum arayüzüne giriş sağlar;
IP ile bağlantı kurmak için Proxmox kaydı gerekmez.

Mevcut Proxmox ekranı hostun web konsolunu açar; bu genel VNC/RDP/SSH
motoru değildir. Paketlenmiş xterm.js terminal görüntüleyicisi olarak
değerlendirilebilir. [noVNC](https://github.com/novnc/noVNC) WebSocket taşıması
ister; tercih edilirse Client içi TCP köprüsü ayrıca gerekir. Paketlenmiş
noVNC'nin VeNCrypt Plain yolundan TLS/X509 desteği çıkarılmaz; native VNC
motoruyla güvenli bağlantı yetenekleri ayrıca karşılaştırılacak.

Core, hesabın ortak profil/etiket/yetki ve şifreli kimlik bilgisi saklama
rolünü üstlenir. Kullanıcı yalnız cihazda tutulan kişisel profil de seçebilir;
yerel profil ve sırlar işletim sisteminin güvenli deposuyla korunur. Oturumluk
parola saklanmaz. Yeniden kurulumdan sonra geri gelenler Core'a açıkça
kaydedilmiş profillerdir; cihazın dışa aktarılamayan anahtarı geri yüklenmiş
gibi gösterilmez. Core profilleri `(coreId, homeId, userId)` ile yalıtılır.

Doğrudan kişisel bağlantı için Core'un trafik geçidi olması gerekmez.
Yönetilen profilin oturum açma/çevrimdışı/sır önbelleği politikası açıkça
tanımlanır; Core çıkışı veya hesap değişimi başka evin önbelleğiyle bağlantı
açamaz. Süreli, merkezi ağ geçidi istenirse ayrı yetkili modül olarak
değerlendirilir; ilk kurulumda internet portu veya VPN otomatik açılmaz.

## Ortak uzak erişim bölümü

| Alan | Planlanan davranış |
| --- | --- |
| Hızlı bağlantı | Protokol, IPv4/IPv6 veya alan adı, ayrı port, kullanıcı ve oturumluk kimlik bilgisi; kayıt zorunlu değil |
| Kayıtlı profil | Ad, ikon/renk, etiket/klasör, favori, isteğe bağlı oda/cihaz bağlantısı; özel ve ortak profil ayrımı |
| Adres formu | Protokole göre varsayılan port; geçerli 1–65535 aralığı, IPv6 ve IDN normalleştirmesi. Şifre URL içine, komut satırına veya QR'a konulmaz |
| Bağlantı durumu | Kayıtlı, bağlantı kuruluyor, hedef doğrulandı, kimlik doğrulanıyor, oturum açık, yeniden bağlanıyor, koptu; boş ekran başarı sayılmaz |
| Geçit | İsteğe bağlı SSH jump host; hedef ve geçidin güven kimlikleri ayrı. Her aşamada süre sınırı, iptal ve görünür hata |
| Oturum çalışma alanı | Sekmeler, bölünmüş görünüm, tam ekran, hızlı hedef değişimi, açık oturumları görme ve tek tek/tümünü kapatma |
| Tablet girdisi | Doğrudan dokunma ve touchpad modu, sağ/orta tık, kaydırma, sürükleme, pinch zoom, kalem; fiziksel klavye/fare ve IME |
| Kısayollar | Ctrl/Alt/Meta/Esc/Tab/F tuşları, Ctrl-Alt-Del gibi uzak tuş kombinasyonları; yerel Android/DeX kısayoluyla çakışmayı açık seçme |
| Pano ve dosya | Pano yönü/izinleri oturuma göre; varsayılan otomatik pano paylaşımı kapalı. Dosya aktarımı protokol ve hedef yeteneğine göre gösterilir |
| Görünüm | Otomatik/sabit çözünürlük, DPI, ekrana sığdır/1:1, klavye açılınca düzen; 2× yazı ve erişilebilir kontrol çubuğu |
| Kalite ve kaynak | Bant genişliği/renk/FPS profili, gecikme ve gerçek bağlantı bilgisi; sınırlı framebuffer, terminal geçmişi, transfer ve açık oturum sayısı |
| Yaşam döngüsü | Yön/değişken pencere ve DeX hot-plug; arka plan/ekran kilidinde giriş durur. Açıkça seçilen sürdürme için Android'e uygun görünür servis, süre sınırı ve kapatma eylemi |
| Gizlilik | Son uygulamalar/ekran görüntüsü koruması seçeneği, PIN/biometrik geçit, clipboard temizliği; gizli alan ve terminal içeriği bildirim/log/audit'e yazılmaz |
| Gezinme | Ortak arama, favori ve dashboard kısayolu; kart dokunuşu bağlantı ayrıntısını açar, kendiliğinden terminal komutu yürütmez |
| Uyandırma | MAC/ağ bilgisiyle isteğe bağlı Wake-on-LAN; yalnız açık kullanıcı işlemi. Aynı ağ/VPN ve hedef donanım desteği doğrulanır; uyanma makbuzu gerçek erişilebilirlikten ayrılır |
| Taşıma | Sürüm kontrollü, sırları varsayılan dışlayan profil içe/dışa aktarımı; `.rdp`/URI dosyaları yalnız izinli alanlarla önizlenir, komut/script çalıştırmaz |

## F63 — SSH, terminal ve SFTP

Önce SSH ve güven kimliği altyapısı geliştirilir; VNC/RDP'nin isteğe bağlı
tünel yolu da bunu kullanır.

- SSH2 oturumu, parola, şifreli özel anahtar ve keyboard-interactive/MFA
  yanıtları; anahtar dosyası Android dosya seçicisiyle alınır. Desteklenen
  anahtar biçimi/algoritma açık gösterilir; modern güvenli varsayılanlar korunur.
- İlk bağlantıda host anahtarı türü ve SHA-256 parmak izi, kayıtlı known-host
  denetimi, değişen anahtarda durdurma ve açık yeniden güven kararı. Bir
  oturumun güven kararı başka host/port/hesaba taşınamaz.
- VT/ANSI terminal, Unicode/Türkçe, renk/tema/font, seçme/kopyalama, arama,
  sınırlı scrollback, PTY boyutlandırma ve ekran okuyucu için metin görünümü.
- Birden fazla terminal/sekme; komutun çıkış kodu, bağlantı kopuşu ve süreç
  sonucunu ayırma. Yeniden bağlantı önceki komutu otomatik tekrar yürütmez;
  `tmux`/`screen` yeniden bağlanması kullanıcı seçimiyle sunulur.
- SFTP dosya yöneticisi: listele, yükle/indir, yeni klasör, yeniden adlandır,
  izin bilgisi/düzenleme, açık onaylı silme; overwrite, symlink, izin hatası,
  kesilmiş aktarım ve desteklenen devam etme davranışı. Transfer kuyruğu,
  ilerleme, iptal, hız sınırı; küçük metin dosyasında boyut sınırlı editör.
- İsteğe bağlı yerel TCP yönlendirme ve SSH jump host. Tünel varsayılan
  loopback/oturum kapsamındadır; kapanınca dinleyici de kapanır. Agent
  forwarding, ters tünel ve dış ağa dinleyici ayrı ileri seçeneklerdir;
  varsayılan açılmaz ve motor desteği ayrıca doğrulanır.
- Komut/snippet favorileri önce düzenlenebilir önizlemeye gelir; oturum
  açılır açılmaz, dashboard yenilenince veya AI önerisiyle kendiliğinden
  çalıştırılmaz. Kaydetme ve terminal transcript'i isteğe bağlıdır;
  terminal çıktısından sırları kusursuz ayıklama garantisi verilmez.

## F62 — RDP uzak masaüstü

- Windows ve uyumlu RDP hostlarına adres/port, kullanıcı/domain, parola ve
  desteklenen giriş biçimleriyle bağlantı. TLS/NLA ve sertifika doğrulaması;
  self-signed sertifika için hedefe özel ilk güven, değişimde yeniden inceleme.
- Masaüstü çözünürlüğü, DPI, yön/yeniden boyutlama, tam ekran ve uzak monitör
  seçimi; birden çok monitör aktarımı motor/host desteğine bağlı ayrı kabul.
- Dokunma/fare/klavye, Türkçe karakter ve IME, uzak tuş kombinasyonları;
  ekran kilidi/yeniden oturum açma ve kontrollü reconnect.
- Uzak ses; mikrofon, pano, klasör/dosya yönlendirme kullanıcı izniyle.
  Android Storage Access Framework sınırı dışında bütün cihaz diski paylaşılmaz.
- RD Gateway, RemoteApp, H.264/GFX, UDP ve uyumlu gelişmiş kimlik doğrulama
  seçilen motorun destek matrisiyle aşamalı eklenir. Desteklenmeyen özellik
  sessiz güvenlik düşürme veya “bağlandı” durumuna dönüşmez.
- Yazıcı, USB/smart-card ve gelişmiş cihaz yönlendirmesi ayrı native
  yeteneklerdir; Android izinleri ve host desteği kanıtlanmadan etkin gösterilmez.
- Windows sürümü/host yeteneği kontrolü ve açıklaması; Client her Windows
  kurulumunda RDP server özelliğini açamaz. Disconnect ile uzak oturumu
  kapat/logoff farklı, açık kullanıcı işlemleridir.

## F61 — VNC uzak ekran

- Standart VNC/RFB hostlarına bağımsız adres ve portla bağlantı; parola veya
  sunucunun desteklediği kimlik doğrulama biçimi. Proxmox VNC ticket akışı
  ayrı adaptör olarak korunur, genel VNC parolası gibi saklanmaz.
- Güvenli TLS/VeNCrypt türleri destek matrisinde doğrulanır. Şifrelenmeyen
  klasik VNC için SSH tüneli veya kullanıcının güvenli özel ağ yolu esas
  alınır; otomatik şifresiz/protokol düşürme yapılmaz.
- Ekrana sığdır/zoom/pan, renk derinliği ve desteklenen kodlamalar, uzak
  imleç, görüntü/bağlantı bilgisi; bozuk veya aşırı framebuffer reddi.
- Salt görüntüleme modu, kontrol modu, özel tuşlar, pano izni ve çoklu
  oturumlar. Klavye/fare akışı gizli/kapalı oturuma gönderilemez.
- Hedef destekliyorsa ekran boyutu/monitör seçimi; dosya aktarımı evrensel
  VNC özelliği sayılmaz. Gerektiğinde aynı cihaza bağlı SFTP profili kullanılır.

## Geliştirme sırası ve kabul

G11 grubunun sıra numarası bütün diğer grupları beklemesi gerektiği anlamına
gelmez. B0/B5 ortak kapıları ve yönetilen profil için B3 kapsamı tamamlandıkça
bağımsız ilerler; S06/S07 medya kurulumu önkoşul değildir.

1. Ortak profil şeması, IP/port formu, kişisel/Core saklama sınırı, güven
   kimlikleri, oturum yaşam döngüsü ve tablet giriş kontrolleri.
2. **F63 SSH**: terminal + host key + SFTP; ardından tünel/jump host.
3. **F62 RDP**: güvenli native motor, temel masaüstü ve girdi; sonra yetenek
   matrisindeki ses/gateway/ileri kanal seçenekleri.
4. **F61 VNC**: native motor, görüntü/girdi ve güvenli bağlantı/tünel.
5. Ortak arama/dashboard/Proxmox girişleri, DeX çoklu pencere/ekran,
   performans, erişilebilirlik ve fiziksel tablet kabulü.

Her protokolde gerçek test hostuyla handshake, doğrulanmış kimlik, görüntü
veya terminal sonucu, kullanıcı girdisi, dosya/pano izni, kopuş ve kapanış
sınanır. Python/Core profil-kasa testleri; Dart unit/widget; JNI/Kotlin ve
parser bozuk-girdi testleri; Android E2E yerel SSH/VNC/RDP fixture'larına
bağlanır. SSH tünelinde DNS/host değişimi, yanlış anahtar; RDP sertifika/NLA;
VNC auth/kodlama farkları ayrı negatif senaryolardır. Hiçbir test üretim
IP'sine bağlanmaz veya canlı sunucuda komut çalıştırmaz.

Huawei MatePad 11.5 S 2026/GMS'siz Android, diğer tabletler ve Samsung DeX'te
fiziksel klavye/fare, 2× yazı, pencere yeniden boyutlama, harici ekran, pil,
uzun oturum ve bağlantı değişimi ayrıca ölçülür. RDP Windows/NLA ve gerçek
donanım codec kabulü yalnız Linux fixture başarısıyla tamamlanmış sayılmaz.

## Araştırma ve motor seçimi

Kaynaklar motor adaylarıdır; otomatik fork veya yeni runtime bağımlılığı
eklenmedi. Uygulamaya almadan sürüm/commit, lisans, transitif native kod,
güvenlik bakımı ve Android ABI gereksinimleri birlikte incelenecek.

- [FreeRDP](https://github.com/FreeRDP/FreeRDP) RDP kütüphanesi ve istemciler
  sunar; Android için native köprü adayıdır. Apache-2.0 üst proje lisansı,
  bütün transitif bileşenlerin aynı lisansla geldiği anlamına gelmez.
  [İncelenen Android JNI dosyası](https://github.com/FreeRDP/FreeRDP/blob/master/client/Android/Studio/freeRDPCore/src/main/cpp/android_freerdp.c)
  MPL-2.0 başlığı taşır; dosya bazında bildirim/dağıtım yükümlülükleri gözden geçirilecek.
- [DartSSH2](https://github.com/vicajilau/dartssh2) Dart SSH/SFTP ve yönlendirme
  altyapısı sağlar. Upstream `onVerifyHostKey` ve timeout örnekleri incelendi;
  Larenor kendi güven kaydı ve süre sınırlarını zorunlu uygulayacak.
- [AVNC](https://github.com/gujjwal00/avnc) Android VNC kullanıcı deneyimi ve
  native entegrasyon örneğidir; kod kullanımı öncesi kendi/alt bileşen
  lisansları ayrıca değerlendirilecek.
- [TigerVNC](https://github.com/TigerVNC/tigervnc) çok platformlu VNC
  uygulamasıdır; uyumluluk ve test hostu adayıdır. [Güvenli bağlantı kılavuzu](https://github.com/TigerVNC/tigervnc/wiki/Secure-your-connection)
  TLS/tünel test matrisine kaynak olur.

Ana kayıt: [genişleme planı](feature-expansion-plan-2026-09-05.md),
[ilerleme](PROGRESS.md) ve [makine tarafından okunabilir ek seçim](remote-access-plan-2026-09-05.json).
