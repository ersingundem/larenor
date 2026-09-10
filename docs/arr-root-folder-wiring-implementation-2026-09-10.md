# Sonarr/Radarr sahipli kök klasör eşleştirmesi

Exact uygulama commit'leri:

- sabit ve idempotent Arr API sözleşmesi: `c16c107db0719027501e133914d56b4978cd41fd`
- retained-daemon bootstrap zinciri: `e9ac68ca20bd25eb4f03e0fafbe90343f8efc229`

Larenor Sonarr için `/data/shows`, Radarr için `/data/movies` kökünü seçer.
İlk gözlem boşsa klasörü `POST /api/v3/rootfolder` ile oluşturur ve ikinci
okumada exact kimlik ile yolu doğrular. Var olan exact kayıt değişiklik olmadan
geçer; yabancı, ek, bozuk veya farklı yollu kayıt silinmez ya da üzerine
yazılmaz ve `arr_root_folder_conflict` ile incelemeye kapanır.

Çağrılar yalnız kanıtlanmış private Arr stream'i, sabit servis authority'si ve
Server'ın ürettiği `X-Api-Key` üzerinden yapılır. DNS, proxy, alternatif hedef,
serbest yol ve retry girdisi yoktur. Mutation sonrası bağlantı veya doğrulama
kesintisi belirsiz etki olarak taşınır; API anahtarı sonuç, hata ve repr
yüzeylerine girmez.

**23 odaklı / 151 ilgili test**, compileall, security policy, queue validation,
diff ve Gitleaks geçti. Paylaşılan volume üzerinde `movies`/`shows`
dizinlerinin native helper ile kurulum öncesi hazırlanması, qBittorrent indirme
istemcisinin Arr'a kaydı ve exact AMD64/ARM64 container kabulü henüz açıktır;
bu nedenle `installAvailable=false` ve sayaçlar değişmedi.
