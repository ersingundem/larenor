import 'package:http/http.dart' as http;

import 'server_admin_test_support.dart';
import 'server_music_retained_status_test.dart' show retainedJson;

class MusicRetainedFixture extends AdminFixture {
  MusicRetainedFixture({super.role}) {
    respond = (request) async => retainedResponse(request);
  }
  http.Response retainedResponse(http.Request request) {
    if (request.method == 'GET' &&
        request.url.path.endsWith('/music-assistant/retained')) {
      return json(retainedJson());
    }
    return defaultResponse(request);
  }
}
