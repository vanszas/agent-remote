import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_remote/hermes_gateway_connector.dart';

void main() {
  test('gateway URLs normalize protocol and preserve reverse-proxy prefix', () {
    final local = HermesGatewayConfig(
      baseUrl: Uri.parse('http://10.0.2.2:9119'),
    );
    expect(local.websocket.toString(), 'ws://10.0.2.2:9119/api/ws');
    final remote = HermesGatewayConfig(
      baseUrl: Uri.parse('https://agent.ts.net/hermes'),
    );
    expect(
      remote.api('/api/auth/ws-ticket').toString(),
      'https://agent.ts.net/hermes/api/auth/ws-ticket',
    );
    expect(remote.websocket.toString(), 'wss://agent.ts.net/hermes/api/ws');
  });
}
