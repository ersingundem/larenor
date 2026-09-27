F01–F63 yazılım kapısı: **3/63** (fiziksel kabul ayrı). Kalan kuyruk: **37/125 iş kanıtla tamamlandı**.

Gruplar ve önceki kabul checkpoint’leri iş sayısına dahil değildir.

| Grup | İş | Biten | Test bekliyor | Çalışılan | CI | Kullanıcı |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| B1 — Yönetilen bileşen yaşam döngüsü | 9 | 9 | 0 | 0 | 0 | 0 |
| B2 — Bütünleşik medya ve müzik | 4 | 4 | 0 | 0 | 0 | 0 |
| B3 — Merkezi kaynak, yetki ve olay sözleşmeleri | 11 | 11 | 0 | 0 | 0 | 0 |
| B4 — Yazılım yedekleme ve kurtarma temeli | 3 | 3 | 0 | 0 | 0 | 0 |
| B5 — Erken ortak tablet Client deneyimi | 2 | 2 | 0 | 0 | 0 | 0 |
| PRODUCT — Önceki ürün planının kalan yazılım işleri | 13 | 4 | 7 | 0 | 0 | 1 |
| POC — Erken donanım/motor fizibilite kayıtları | 5 | 0 | 0 | 0 | 0 | 5 |
| G01 — Güvenilir Core ve izlenebilir işlemler | 5 | 1 | 3 | 0 | 0 | 0 |
| G02 — Kurtarma, yedek koruması ve güç | 3 | 0 | 0 | 0 | 0 | 0 |
| G03 — Erken bildirim, tablet ve ev görünümü | 4 | 0 | 2 | 0 | 0 | 0 |
| G04 — AI ve denetlenebilir otomasyon | 8 | 0 | 0 | 0 | 0 | 0 |
| G05 — Genişletilebilirlik, destek ve birden fazla ev | 4 | 0 | 0 | 0 | 0 | 0 |
| G06 — Medya ve müzik | 10 | 0 | 0 | 0 | 0 | 0 |
| G07 — Aile ve ev yaşamı | 10 | 2 | 0 | 0 | 0 | 0 |
| G08 — Kamera ve olaylar | 5 | 0 | 0 | 0 | 0 | 0 |
| G09 — Enerji, iklim ve bahçe | 5 | 0 | 0 | 0 | 0 | 0 |
| G10 — Ağ, varlık algısı ve yeni cihazlar | 6 | 0 | 0 | 0 | 0 | 0 |
| G11 — Proxmox'tan bağımsız uzak erişim | 4 | 1 | 0 | 0 | 0 | 0 |
| FINAL — Bütün yazılım sonrası son frontend ve yayın | 5 | 0 | 0 | 0 | 0 | 0 |
| MANUAL — Kullanıcıyla son kurulum ve fiziksel kabul | 9 | 0 | 0 | 0 | 0 | 9 |

Şu anda çalışılanlar

| ID | İş | Durum | Beklenen bağımlılık |
| --- | --- | --- | --- |
| — | Aktif iş yok | — | — |

Bekleyen tüm işler

Bağımlılığı tamamlanan işler önce, diğerleri kuyruk sırasıyla gösterilir.

| Sıra | ID | İş | Hazırlık | Beklenen bağımlılık |
| ---: | --- | --- | --- | --- |
| 1 | F15 | Doğrulanabilir bileşen güncellemeleri | Başlanabilir | — |
| 2 | F52 | DeX'te iki ekrana farklı görev | Başlanabilir | — |
| 3 | F24 | Akıllı altyazı ve dil tercihleri | Başlanabilir | — |
| 4 | F26 | Oynatma kalitesi danışmanı | Başlanabilir | — |
| 5 | F25 | Jenerik ve kapanış atlama | Başlanabilir | — |
| 6 | F21 | Birlikte senkron film izleme | Başlanabilir | — |
| 7 | F27 | Seyahat için çevrimdışı medya | Başlanabilir | — |
| 8 | F28 | Sesli kitap ve podcast merkezi | Başlanabilir | — |
| 9 | F32 | Dolap stoğu ve son kullanma takibi | Başlanabilir | — |
| 10 | F56 | Eski cihazlar için akıllı kumanda | Başlanabilir | — |
| 11 | F63 | SSH terminal, SFTP ve güvenli tüneller | Başlanabilir | — |
| 12 | F62 | Bağımsız RDP uzak masaüstü | Başlanabilir | — |
| 13 | K13 | Yönetilen profil dağıtımı ve filo bağı | Bağımlılık bekliyor | K12, F53 |
| 14 | F16 | Otomatik kurtarma tatbikatı | Bağımlılık bekliyor | F05 |
| 15 | F17 | Yedekleri silmeye kapalı kurtarma hedefi | Bağımlılık bekliyor | F16 |
| 16 | F18 | Elektrik kesintisinde düzenli kapanış | Bağımlılık bekliyor | F05, F16 |
| 17 | F53 | Evdeki tabletleri tek yerden yönetme | Bağımlılık bekliyor | F54, F13 |
| 18 | F08 | Yapay zekâ kaynak yöneticisi | Bağımlılık bekliyor | F05 |
| 19 | F04 | Çakışan kurallar hakemi | Bağımlılık bekliyor | F05 |
| 20 | F02 | Otomasyonun deneme haftası | Bağımlılık bekliyor | F04 |
| 21 | F03 | Geçmişte otomasyon sınaması | Bağımlılık bekliyor | F02 |
| 22 | F01 | Konuşarak otomasyon taslağı | Bağımlılık bekliyor | F08, F02, F03, F04 |
| 23 | F09 | Görülebilir, süreli AI hafızası | Bağımlılık bekliyor | F08, F20 |
| 24 | F07 | Evin alışılmış düzeninden sapmalar | Bağımlılık bekliyor | F08 |
| 25 | F10 | Kanıta dayalı arıza yardımcısı | Bağımlılık bekliyor | F08 |
| 26 | F11 | Sınırlı yetkili mini eklentiler | Bağımlılık bekliyor | F13, F15, F20, F05 |
| 27 | F12 | Yetkili MCP kapısı | Bağımlılık bekliyor | F13, F20 |
| 28 | F14 | Süreli destek oturumu | Bağımlılık bekliyor | F13, F20, F54 |
| 29 | F19 | Birden fazla ev, bağımsız Core | Bağımlılık bekliyor | F16, F20, F54 |
| 30 | F22 | Kendi televizyon kanalların | Bağımlılık bekliyor | F05 |
| 31 | F23 | Canlı TV ve kayıt merkezi | Bağımlılık bekliyor | F05 |
| 32 | F29 | Parti DJ'i ve ortak şarkı oylaması | Bağımlılık bekliyor | F54 |
| 33 | F30 | Medya arşivi sağlık ve yer tasarrufu | Bağımlılık bekliyor | F16, F05, F08 |
| 34 | F33 | Büyük ekran pişirme asistanı | Bağımlılık bekliyor | F32 |
| 35 | F35 | Ev belgeleri ve garanti hatırlatmaları | Bağımlılık bekliyor | F05, F08 |
| 36 | F36 | Adil ev işi paylaşımı | Bağımlılık bekliyor | F05, F54 |
| 37 | F37 | Ortak ev masrafları | Bağımlılık bekliyor | F20 |
| 38 | F38 | Aile anıları ve fotoğraf araması | Bağımlılık bekliyor | F08, F16, F13 |
| 39 | F39 | Canlı aile panosu ve beyaz tahta | Bağımlılık bekliyor | F54 |
| 40 | F40 | Ortak kaynak rezervasyonu | Bağımlılık bekliyor | F05, F54 |
| 41 | F43 | Evdeyken kamera kayıt profili | Bağımlılık bekliyor | F13, F20 |
| 42 | F42 | Mahremiyet korumalı olay paylaşımı | Bağımlılık bekliyor | F43, F20 |
| 43 | F41 | Kamera kayıtlarında doğal dille arama | Bağımlılık bekliyor | F43, F08 |
| 44 | F44 | Kameradan görsel sensörler | Bağımlılık bekliyor | F43, F08 |
| 45 | F45 | Havlama ve gürültü olayları | Bağımlılık bekliyor | F43, F54, F08 |
| 46 | F50 | Oda konforu ve havalandırma planı | Bağımlılık bekliyor | F04 |
| 47 | F48 | Ev güç bütçesi | Bağımlılık bekliyor | F04 |
| 48 | F46 | Elektrikli araç şarj planlayıcısı | Bağımlılık bekliyor | F48, F05 |
| 49 | F47 | Güneş ve ev bataryası öncelikleri | Bağımlılık bekliyor | F48, F03 |
| 50 | F49 | Bahçe sulama ve su bütçesi | Bağımlılık bekliyor | F04, F05, F54 |
| 51 | F55 | Zigbee/Thread ağ ve güncelleme merkezi | Bağımlılık bekliyor | F15, F16 |
| 52 | F57 | Oda düzeyinde yerel varlık algısı | Bağımlılık bekliyor | F13 |
| 53 | F58 | E-paper mini ev ekranları | Bağımlılık bekliyor | F53, F54 |
| 54 | F59 | 3D yazıcı ve atölye merkezi | Bağımlılık bekliyor | F05, F54 |
| 55 | F60 | Tablette ev bilgisayarından oyun yayını | Bağımlılık bekliyor | F13 |
| 56 | F61 | Bağımsız VNC uzak ekran | Bağımlılık bekliyor | F63 |
| 57 | FINAL.UI | Son ortak Apple Home esintili tablet tasarım geçişi | Bağımlılık bekliyor | PRODUCT, G01, G02, G03, G04, G05, G06, G07, G08, G09, G10, G11 |
| 58 | FINAL.AUDIT | Özellikler arası bütünlük, performans ve güvenlik kabulü | Bağımlılık bekliyor | FINAL.UI |
| 59 | FINAL.CI | Tam kaynak ve dağıtım doğrulama | Bağımlılık bekliyor | FINAL.AUDIT |
| 60 | FINAL.GALLERY | Son gerçek tablet ekranları ve görsel kabul | Bağımlılık bekliyor | FINAL.CI |
| 61 | FINAL.README | Profesyonel README ve GitHub yayımlama doğrulaması | Bağımlılık bekliyor | FINAL.GALLERY |

Tamamlanan ve test/CI bekleyen işler

| ID | İş | Durum | Beklenen bağımlılık |
| --- | --- | --- | --- |
| S06.3a | Worker kaynak planı ve değişmez kimlikler | Kanıtla tamamlandı | — |
| S06.3b | Kaynak journal’ı ve kesilmiş işlem sahipliği | Kanıtla tamamlandı | — |
| S06.3c | Seçili digest ile bounded imaj edinme | Kanıtla tamamlandı | — |
| S06.3d | Onaylı kökte sahiplikli appdata | Kanıtla tamamlandı | — |
| S06.3e | Sahiplikli özel kontrol ağı | Kanıtla tamamlandı | — |
| S06.3f | Kaynak makbuzu ve iki mimarili kabul | Kanıtla tamamlandı | — |
| S06.4 | Dar kurulum adımlarını API ve işçiye bağlama | Kanıtla tamamlandı | — |
| S06.5 | Özel bootstrap ve otomatik servis eşleştirme temeli | Kanıtla tamamlandı | — |
| S06.6 | Doğrulanmış sonuç, iptal ve kurtarma | Kanıtla tamamlandı | — |
| S07.1 | Altı bileşen ve dahili Music Assistant paketleme | Kanıtla tamamlandı | — |
| S07.2 | İndirme, istek ve kütüphane otomatik eşleştirmesi | Kanıtla tamamlandı | — |
| S07.3 | Müzik sağlayıcı, kuyruk ve alıcı Server API’si | Kanıtla tamamlandı | — |
| S07.4 | Tek kurulum durumu ve ayarlar kabulü | Kanıtla tamamlandı | — |
| S08.1 | Core/ev bağlamını oturuma atomik bağlama | Kanıtla tamamlandı | — |
| S08.2 | İlk parola ve eski Server uyumluluğu | Kanıtla tamamlandı | — |
| S08.3 | Provider, route ve callback kapsam sınırı | Kanıtla tamamlandı | — |
| S08.4 | Kalıcı ev kayıt sınırı ve açık eski düzen taşıması | Kanıtla tamamlandı | — |
| S08.5 | Restore, logout ve journal hedef sınırı | Kanıtla tamamlandı | — |
| S08.6 | Kişi/oda/kaynak kimliği ve yetki sözleşmesi | Kanıtla tamamlandı | — |
| S08.7 | İlk merkezi Home Assistant adaptörü | Kanıtla tamamlandı | — |
| S08.8 | Merkezi medya ve müzik Client geçişi | Kanıtla tamamlandı | — |
| S08.9 | Merkezi ağ ve altyapı adaptörleri | Kanıtla tamamlandı | — |
| S08.10 | Olay, komut sonucu ve sınırlı dosya/medya taşıma | Kanıtla tamamlandı | — |
| S08.11 | Merkezi arama/widget/oda görünümü kabulü | Kanıtla tamamlandı | — |
| S09.1 | Tek kurulum/güncelleme ve yedek sözleşmesi | Kanıtla tamamlandı | — |
| S09.2 | Boş kurulumda doğrulanmış geri yükleme | Kanıtla tamamlandı | — |
| S09.3 | Yazılım temiz kurulum/yükseltme/kurtarma CI’sı | Kanıtla tamamlandı | — |
| B5.1 | Ortak tablet düzeni ve erişilebilirlik sözleşmesi | Kanıtla tamamlandı | — |
| B5.2 | Kişisel profil ve hassas oturum Client sınırları | Kanıtla tamamlandı | — |
| K03.remaining | WebPanel ileri tarayıcı işlemleri | Kanıtla tamamlandı | — |
| K05.remaining | Ortam ekranı video/PDF/web listeleri | Kanıtla tamamlandı | — |
| K07 | Eşleştirilmiş uzaktan API ve MQTT | Kanıtla tamamlandı | — |
| K08 | Sınırlı web→native köprü | Kanıtla tamamlandı | — |
| F06 | Bunu kim, neden yaptı? | Kanıtla tamamlandı | — |
| F31 | Haftalık menü ve tarif merkezi | Kanıtla tamamlandı | — |
| F34 | QR etiketli ev envanteri | Kanıtla tamamlandı | — |
| REMOTE.COMMON | Uzak erişim ortak profil/güven ve oturum temeli | Kanıtla tamamlandı | — |
| PRODUCT.APPLETV | Apple TV video ve medya hedefleri | Uygulama tamamlandı · test bekliyor | — |
| PRODUCT.PROVIDERS | Spotify/Apple Music/YouTube Music kullanıcı akışı | Uygulama tamamlandı · test bekliyor | — |
| PRODUCT.CAMERA | İsteğe bağlı yaklaşma ve kişisel kamera görünümü | Uygulama tamamlandı · test bekliyor | — |
| K09 | Cihaz bilgisi ve kontrollü uzaktan görünüm | Uygulama tamamlandı · test bekliyor | — |
| K10 | Hareket, karanlık ve cihaz sensörleri | Uygulama tamamlandı · test bekliyor | — |
| K11 | QR/NFC/BLE/USB/TTS/print seçili çevre birimleri | Uygulama tamamlandı · test bekliyor | — |
| K12 | Watchdog ve yerel kullanım ölçümü | Uygulama tamamlandı · test bekliyor | — |
| F13 | Bileşen bazında internet izinleri | Uygulama tamamlandı · test bekliyor | — |
| F20 | Değiştirilmesi fark edilen işlem günlüğü | Uygulama tamamlandı · test bekliyor | — |
| F05 | Uzun süren ev iş akışları | Uygulama tamamlandı · test bekliyor | — |
| F54 | Google servislerinden bağımsız bildirim | Uygulama tamamlandı · test bekliyor | — |
| F51 | Etkileşimli ev kat planı | Uygulama tamamlandı · test bekliyor | — |
