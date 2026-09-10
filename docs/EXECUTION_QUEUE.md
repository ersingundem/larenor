F01–F63 yazılım kapısı: **0/63** (fiziksel kabul ayrı). Kalan kuyruk: **14/125 iş kanıtla tamamlandı**.

Gruplar ve önceki kabul checkpoint’leri iş sayısına dahil değildir.

| Grup | İş | Biten | Çalışılan | CI | Kullanıcı |
| --- | ---: | ---: | ---: | ---: | ---: |
| B1 — Yönetilen bileşen yaşam döngüsü | 9 | 7 | 1 | 0 | 0 |
| B2 — Bütünleşik medya ve müzik | 4 | 0 | 0 | 0 | 0 |
| B3 — Merkezi kaynak, yetki ve olay sözleşmeleri | 11 | 7 | 0 | 0 | 0 |
| B4 — Yazılım yedekleme ve kurtarma temeli | 3 | 0 | 0 | 0 | 0 |
| B5 — Erken ortak tablet Client deneyimi | 2 | 0 | 1 | 0 | 0 |
| PRODUCT — Önceki ürün planının kalan yazılım işleri | 13 | 0 | 0 | 0 | 1 |
| POC — Erken donanım/motor fizibilite kayıtları | 5 | 0 | 0 | 0 | 5 |
| G01 — Güvenilir Core ve izlenebilir işlemler | 5 | 0 | 0 | 0 | 0 |
| G02 — Kurtarma, yedek koruması ve güç | 3 | 0 | 0 | 0 | 0 |
| G03 — Erken bildirim, tablet ve ev görünümü | 4 | 0 | 0 | 0 | 0 |
| G04 — AI ve denetlenebilir otomasyon | 8 | 0 | 0 | 0 | 0 |
| G05 — Genişletilebilirlik, destek ve birden fazla ev | 4 | 0 | 0 | 0 | 0 |
| G06 — Medya ve müzik | 10 | 0 | 0 | 0 | 0 |
| G07 — Aile ve ev yaşamı | 10 | 0 | 0 | 0 | 0 |
| G08 — Kamera ve olaylar | 5 | 0 | 0 | 0 | 0 |
| G09 — Enerji, iklim ve bahçe | 5 | 0 | 0 | 0 | 0 |
| G10 — Ağ, varlık algısı ve yeni cihazlar | 6 | 0 | 0 | 0 | 0 |
| G11 — Proxmox'tan bağımsız uzak erişim | 4 | 0 | 0 | 0 | 0 |
| FINAL — Bütün yazılım sonrası son frontend ve yayın | 5 | 0 | 0 | 0 | 0 |
| MANUAL — Kullanıcıyla son kurulum ve fiziksel kabul | 9 | 0 | 0 | 0 | 9 |

İşler · sayfa 1/7 · en çok 20 satır

| ID | İş | Durum | Beklenen bağımlılık |
| --- | --- | --- | --- |
| S06.3a | Worker kaynak planı ve değişmez kimlikler | Kanıtla tamamlandı | — |
| S06.3b | Kaynak journal’ı ve kesilmiş işlem sahipliği | Kanıtla tamamlandı | — |
| S06.3c | Seçili digest ile bounded imaj edinme | Kanıtla tamamlandı | — |
| S06.3d | Onaylı kökte sahiplikli appdata | Kanıtla tamamlandı | — |
| S06.3e | Sahiplikli özel kontrol ağı | Kanıtla tamamlandı | — |
| S06.3f | Kaynak makbuzu ve iki mimarili kabul | Kanıtla tamamlandı | — |
| S06.4 | Dar kurulum adımlarını API ve işçiye bağlama | Kanıtla tamamlandı | — |
| S06.5 | Özel bootstrap ve otomatik servis eşleştirme temeli | Çalışılıyor | — |
| S06.6 | Doğrulanmış sonuç, iptal ve kurtarma | Bekliyor | S06.5 |
| S07.1 | Altı bileşen ve dahili Music Assistant paketleme | Bekliyor | B1 |
| S07.2 | İndirme, istek ve kütüphane otomatik eşleştirmesi | Bekliyor | S07.1 |
| S07.3 | Müzik sağlayıcı, kuyruk ve alıcı Server API’si | Bekliyor | S07.1 |
| S07.4 | Tek kurulum durumu ve ayarlar kabulü | Bekliyor | S07.2, S07.3 |
| S08.1 | Core/ev bağlamını oturuma atomik bağlama | Kanıtla tamamlandı | — |
| S08.2 | İlk parola ve eski Server uyumluluğu | Kanıtla tamamlandı | — |
| S08.3 | Provider, route ve callback kapsam sınırı | Kanıtla tamamlandı | — |
| S08.4 | Kalıcı ev kayıt sınırı ve açık eski düzen taşıması | Kanıtla tamamlandı | — |
| S08.5 | Restore, logout ve journal hedef sınırı | Kanıtla tamamlandı | — |
| S08.6 | Kişi/oda/kaynak kimliği ve yetki sözleşmesi | Kanıtla tamamlandı | — |
| S08.7 | İlk merkezi Home Assistant adaptörü | Kanıtla tamamlandı | — |
