# B5.2 — Kişisel profil ve hassas oturum Client temeli

20 Eylül 2026. Bu bağımsız dilim 21 Eylül 2026'da güncel `origin/main`
`8b73f24bca77259080316be98e0b80c9c1bf1d23` üzerine yeniden doğrulandı. B5.2'nin
ilk Client sınırıdır; Core profil keşfi S08.11 kapsamındadır ve bu dilim B5.2'yi
veya F61–F63'ü tamamlanmış saymaz.

## Üç kabul maddesi

| Kabul | Üretim davranışı | Kanıt |
| --- | --- | --- |
| Yerel profil ile sunucu hesabı ayrılır | Var olan `RemoteProfile` şeması cihazın güvenli deposunda kalır. Yeni `PersonalRemoteAccount` yalnız mevcut ProviderScope ömrüne ait, bellekte tutulan opak bir kimliktir. Core, Home Assistant, Proxmox veya medya hesabı/URL/tokenı içermez ve bunlardan birini istemez. | Ayrı ProviderContainer hesaplarının birbirinin lease'ini kullanamadığı model testi; Core/Proxmox çağrısı olmadan gerçek Settings akışı. |
| Hassas oturum exact authority ile kapanır | Tek kullanıcının seçtiği profil, secure-store revision, hesap nesnesi, route nesnesi ve tek kaynak türü 15 dakikalık memory-only lease'e bağlanır. PIN, idle, background, native pencere, route, provider/store veya revision değişikliği lease'i tek yönlü emekli eder. RDP/VNC görünürlük bayrakları da invalidation sırasında temizlenir ve geri dönüşte eski panel yeniden açılmaz. | Account/route/profile/revision/resource/TTL birim matrisi; PIN değişimi ile idle/lifecycle/route sonrası elde tutulmuş callback testleri; RDP/VNC lifecycle dönüş regresyonları. |
| Sınırlı kaynak, redaksiyon ve tablet erişilebilirliği ortaktır | SSH yalnız terminal/SFTP/tünel; RDP ve VNC yalnız desktop lease'i oluşturabilir. Lease host, kullanıcı, parola, anahtar, komut veya trust verisi taşımaz; `toString` bunları açıklamaz. Seçili profil sayfası sınırı EN/TR açıklar. 600/1200 genişlik, %200 metin, tek TalkBack grubu, en az 48dp eylem ve native Enter akışı doğrulanır. | Kapalı policy ve redaksiyon birim testleri; EN/TR × 600/1200 tablet widget matrisi. |

## Güvenlik ve sahiplik notları

`PersonalSessionLease` bağlantı veya kimlik bilgisi değildir. Kalıcı depoya,
loglara, backup'a ya da Core'a yazılmaz. Profil ID'si bile tanı metnine çıkmaz.
Bir lease yalnız kullanıcı tarafından seçilen tek kaynak için oluşturulur; SSH
profili desktop, RDP/VNC profili terminal/SFTP/tünel yetkisi üretemez.

Var olan panel/controller katmanları kendi credential, host-key, certificate,
window, lifecycle ve asynchronous callback kontrollerini uygulamaya devam eder.
Bu dilim üstte ikinci, dar bir route/account/profile kapısı ekler; ikinci bir
oturum state owner veya credential deposu oluşturmaz. Ağ readback sonucu bu
yerel profil sınırının parçası değildir ve kayıtlı profil bağlantı başarısı
olarak gösterilmez.

## Doğrulama

- Odaklı model, EN/TR tablet, stale callback ve mevcut profil regresyonları:
  **57 test geçti**.
- Sahipli dört Dart dosyası için analyzer: **0 issue**.
- `git diff --check`, execution queue validator ve gitleaks: **temiz**.

Fiziksel Huawei MatePad/DeX, gerçek TalkBack ve gerçek SSH/RDP/VNC hedef kabulü
ayrı açık kapılardır. `docs/execution-queue.json` bu nedenle ilerletilmez.
