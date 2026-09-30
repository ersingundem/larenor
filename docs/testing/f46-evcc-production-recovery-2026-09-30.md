# F46 gerçek evcc toparlama yolu — 30 Eylül 2026

Normal `create_app` gerçek TCP evcc bağlantısında 16→8 A değişimini uygular. Yanıt kaybolup cihaz revizyonu değişse de aynı command kimliği kalır; GET sonucu sealed preview ve güncel hesap/oturum/tarife yetkisiyle doğrular, ikinci POST gönderilmez. Dispatch öncesi taze `/api/state` okunur; değişmiş cihaz veya güç/saat sınırı mutation üretmez. Makbuz hedef amperi, gözlenen amperi ve gözlem zamanını taşır. Provider I/O sırasında DB transaction açık tutulmaz.

Flutter gerçek `providerKind=evcc` ve negatif tarifeyi kabul eder; belirsiz yanıtı yeni command ile tekrar göndermez. Sonuç endpoint'i mevcut command için okunur.

Ajan doğrulaması: `test_f46_ev_charge_planner.py`, `test_f46_ev_charge_http.py`, `test_evcc_runtime_provider.py`, `test_f46_evcc_production_loopback.py`, `test_f48_evcc_power_control_loopback.py`: 27 geçti. İlgili Flutter paketinde 11 geçti; odaklı analyze, Python compile ve scoped diff-check temiz. Root sealed preview/current-authority ve socket gönderim guard değişikliklerini inceledi.

Resmî sözleşme: [evcc pinned HTTP kaynak kodu](https://github.com/evcc-io/evcc/blob/077c093e5fdc375a9f2b1bc360b4d7ba38eaae46/server/http.go), GET `/api/state` ve POST `/api/loadpoints/{id}/maxcurrent/{value}`.

Bu isolated provider kanıtıdır; tam Client→normal Core→TCP servis çalıştırması, birleşik final paketleri, exact HEAD CI ve fiziksel cihaz kabulü açık. Kuyruk uygulama tamamlandı tablosunda kalır; kabul sayaçları artmaz.
