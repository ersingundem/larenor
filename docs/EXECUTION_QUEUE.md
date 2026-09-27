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
| G01 — Güvenilir Core ve izlenebilir işlemler | 5 | 1 | 4 | 0 | 0 | 0 |
| G02 — Kurtarma, yedek koruması ve güç | 3 | 0 | 2 | 0 | 0 | 0 |
| G03 — Erken bildirim, tablet ve ev görünümü | 4 | 0 | 3 | 0 | 0 | 0 |
| G04 — AI ve denetlenebilir otomasyon | 8 | 0 | 0 | 0 | 0 | 0 |
| G05 — Genişletilebilirlik, destek ve birden fazla ev | 4 | 0 | 0 | 0 | 0 | 0 |
| G06 — Medya ve müzik | 10 | 0 | 6 | 0 | 0 | 0 |
| G07 — Aile ve ev yaşamı | 10 | 2 | 1 | 0 | 0 | 0 |
| G08 — Kamera ve olaylar | 5 | 0 | 0 | 0 | 0 | 0 |
| G09 — Enerji, iklim ve bahçe | 5 | 0 | 0 | 0 | 0 | 0 |
| G10 — Ağ, varlık algısı ve yeni cihazlar | 6 | 0 | 1 | 0 | 0 | 0 |
| G11 — Proxmox'tan bağımsız uzak erişim | 4 | 1 | 2 | 0 | 0 | 0 |
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
| 1 | F18 | Elektrik kesintisinde düzenli kapanış | Başlanabilir | — |
| 2 | F53 | Evdeki tabletleri tek yerden yönetme | Başlanabilir | — |
| 3 | F08 | Yapay zekâ kaynak yöneticisi | Başlanabilir | — |
| 4 | F04 | Çakışan kurallar hakemi | Başlanabilir | — |
| 5 | F11 | Sınırlı yetkili mini eklentiler | Başlanabilir | — |
| 6 | F12 | Yetkili MCP kapısı | Başlanabilir | — |
| 7 | F14 | Süreli destek oturumu | Başlanabilir | — |
| 8 | F19 | Birden fazla ev, bağımsız Core | Başlanabilir | — |
| 9 | F22 | Kendi televizyon kanalların | Başlanabilir | — |
| 10 | F23 | Canlı TV ve kayıt merkezi | Başlanabilir | — |
| 11 | F29 | Parti DJ'i ve ortak şarkı oylaması | Başlanabilir | — |
| 12 | F33 | Büyük ekran pişirme asistanı | Başlanabilir | — |
| 13 | F36 | Adil ev işi paylaşımı | Başlanabilir | — |
| 14 | F37 | Ortak ev masrafları | Başlanabilir | — |
| 15 | F39 | Canlı aile panosu ve beyaz tahta | Başlanabilir | — |
| 16 | F40 | Ortak kaynak rezervasyonu | Başlanabilir | — |
| 17 | F43 | Evdeyken kamera kayıt profili | Başlanabilir | — |
| 18 | F55 | Zigbee/Thread ağ ve güncelleme merkezi | Başlanabilir | — |
| 19 | F57 | Oda düzeyinde yerel varlık algısı | Başlanabilir | — |
| 20 | F59 | 3D yazıcı ve atölye merkezi | Başlanabilir | — |
| 21 | F60 | Tablette ev bilgisayarından oyun yayını | Başlanabilir | — |
| 22 | F61 | Bağımsız VNC uzak ekran | Başlanabilir | — |
| 23 | K13 | Yönetilen profil dağıtımı ve filo bağı | Bağımlılık bekliyor | F53 |
| 24 | F02 | Otomasyonun deneme haftası | Bağımlılık bekliyor | F04 |
| 25 | F03 | Geçmişte otomasyon sınaması | Bağımlılık bekliyor | F02 |
| 26 | F01 | Konuşarak otomasyon taslağı | Bağımlılık bekliyor | F08, F02, F03, F04 |
| 27 | F09 | Görülebilir, süreli AI hafızası | Bağımlılık bekliyor | F08 |
| 28 | F07 | Evin alışılmış düzeninden sapmalar | Bağımlılık bekliyor | F08 |
| 29 | F10 | Kanıta dayalı arıza yardımcısı | Bağımlılık bekliyor | F08 |
| 30 | F30 | Medya arşivi sağlık ve yer tasarrufu | Bağımlılık bekliyor | F08 |
| 31 | F35 | Ev belgeleri ve garanti hatırlatmaları | Bağımlılık bekliyor | F08 |
| 32 | F38 | Aile anıları ve fotoğraf araması | Bağımlılık bekliyor | F08 |
| 33 | F42 | Mahremiyet korumalı olay paylaşımı | Bağımlılık bekliyor | F43 |
| 34 | F41 | Kamera kayıtlarında doğal dille arama | Bağımlılık bekliyor | F43, F08 |
| 35 | F44 | Kameradan görsel sensörler | Bağımlılık bekliyor | F43, F08 |
| 36 | F45 | Havlama ve gürültü olayları | Bağımlılık bekliyor | F43, F08 |
| 37 | F50 | Oda konforu ve havalandırma planı | Bağımlılık bekliyor | F04 |
| 38 | F48 | Ev güç bütçesi | Bağımlılık bekliyor | F04 |
| 39 | F46 | Elektrikli araç şarj planlayıcısı | Bağımlılık bekliyor | F48 |
| 40 | F47 | Güneş ve ev bataryası öncelikleri | Bağımlılık bekliyor | F48, F03 |
| 41 | F49 | Bahçe sulama ve su bütçesi | Bağımlılık bekliyor | F04 |
| 42 | F58 | E-paper mini ev ekranları | Bağımlılık bekliyor | F53 |
| 43 | FINAL.UI | Son ortak Apple Home esintili tablet tasarım geçişi | Bağımlılık bekliyor | PRODUCT, G02, G03, G04, G05, G06, G07, G08, G09, G10, G11 |
| 44 | FINAL.AUDIT | Özellikler arası bütünlük, performans ve güvenlik kabulü | Bağımlılık bekliyor | FINAL.UI |
| 45 | FINAL.CI | Tam kaynak ve dağıtım doğrulama | Bağımlılık bekliyor | FINAL.AUDIT |
| 46 | FINAL.GALLERY | Son gerçek tablet ekranları ve görsel kabul | Bağımlılık bekliyor | FINAL.CI |
| 47 | FINAL.README | Profesyonel README ve GitHub yayımlama doğrulaması | Bağımlılık bekliyor | FINAL.GALLERY |

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
| F15 | Doğrulanabilir bileşen güncellemeleri | Uygulama tamamlandı · test bekliyor | — |
| F20 | Değiştirilmesi fark edilen işlem günlüğü | Uygulama tamamlandı · test bekliyor | — |
| F05 | Uzun süren ev iş akışları | Uygulama tamamlandı · test bekliyor | — |
| F16 | Otomatik kurtarma tatbikatı | Uygulama tamamlandı · test bekliyor | — |
| F17 | Yedekleri silmeye kapalı kurtarma hedefi | Uygulama tamamlandı · test bekliyor | — |
| F54 | Google servislerinden bağımsız bildirim | Uygulama tamamlandı · test bekliyor | — |
| F51 | Etkileşimli ev kat planı | Uygulama tamamlandı · test bekliyor | — |
| F52 | DeX'te iki ekrana farklı görev | Uygulama tamamlandı · test bekliyor | — |
| F24 | Akıllı altyazı ve dil tercihleri | Uygulama tamamlandı · test bekliyor | — |
| F26 | Oynatma kalitesi danışmanı | Uygulama tamamlandı · test bekliyor | — |
| F25 | Jenerik ve kapanış atlama | Uygulama tamamlandı · test bekliyor | — |
| F21 | Birlikte senkron film izleme | Uygulama tamamlandı · test bekliyor | — |
| F27 | Seyahat için çevrimdışı medya | Uygulama tamamlandı · test bekliyor | — |
| F28 | Sesli kitap ve podcast merkezi | Uygulama tamamlandı · test bekliyor | — |
| F32 | Dolap stoğu ve son kullanma takibi | Uygulama tamamlandı · test bekliyor | — |
| F56 | Eski cihazlar için akıllı kumanda | Uygulama tamamlandı · test bekliyor | — |
| F63 | SSH terminal, SFTP ve güvenli tüneller | Uygulama tamamlandı · test bekliyor | — |
| F62 | Bağımsız RDP uzak masaüstü | Uygulama tamamlandı · test bekliyor | — |
