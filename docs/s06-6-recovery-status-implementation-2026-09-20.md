# S06.6 doğrulanmış sonuç ve kurtarma durumu

Bu dilim, kalıcı medya işlerini yeniden çalıştırmadan en son sonucu tek bir
salt okunur Server görünümünde birleştirir. `GET
/api/v1/admin/media/recovery-status` yalnız güncel ve hazır yönetici oturumuna
açıktır. qBittorrent, Sonarr, Radarr, Jellyfin, Seerr ve Music Assistant için
en son kalıcı kaydı gösterir; şifreli payload'ı, kimlik bilgisini, API
anahtarını veya worker ayrıntısını döndürmez.

Tam üç yazılım kabul ölçütü vardır:

1. Container create/start makbuzu servis doğrulaması sayılmaz. Yanıt
   `containerState` ve `serviceState` alanlarını ayrı üretir; yalnız kalıcı
   authenticated readback içeren iş `verified` olur.
2. Restart, iptal ve belirsiz etki kayıtları silmez veya otomatik tekrar
   çalıştırmaz. Okuma yan etkisiz ve idempotenttir; belirsiz sonuç
   `needs_attention` ile `review` eylemine kapanır.
3. İş yetkisi kaybolursa worker etkisi başlamadan kapanır. Eski oturum sonucu
   okuyamaz; yeni yetkili yönetici yalnız sınırlı, secret-free sonuç modelini
   görür.

Yerel TDD paketi bu üç ölçütü gerçek Core veritabanı ve HTTP yönlendirmesiyle
kanıtlar. S06.6 henüz tamamlanmış sayılmaz: required CI ve bağımsız inceleme
kanıtı bu exact kaynak için oluşmadan kuyruk sayacı artmaz. amd64/arm64 gerçek
bileşen kabulü de CI kapısında açık kalır. Ev kurulumu ve fiziksel alıcı
kabulü bu yazılım diliminin kapsamı değildir.
