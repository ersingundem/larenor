# Sonarr/Radarr authenticated API geri okuması

Exact uygulama commit'i: `245685df608ff30dd20fedf607b7202246749844`.

Larenor'un kapalı adaptörü yalnız önceden doğrulanmış private stream üzerinden `GET /api/v3/system/status` çağırır. Kimlik `X-Api-Key` başlığındadır; hedef, resolver, proxy, serbest header veya retry girdisi yoktur. Sonarr `4.0.19.2979` ve Radarr `6.3.0.10514` için servis adı ile sürüm birlikte doğrulanır. Başka servis yanıtı, sürüm sapması, auth hatası, bozuk/tekrarlı JSON, limit aşımı ve timeout secret-free sabit hatalara kapanır.

Bu dilim 14 yeni test, compileall, security policy, queue validation, diff check ve Gitleaks ile doğrulandı. Container create/start zincirine henüz bağlanmadığı ve native iki mimari kabul yapılmadığı için `installAvailable=false` ve sayaç değişmedi.
