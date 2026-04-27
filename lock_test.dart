import 'dart:io';

void main() async {
  print('Attempting to bind port 47832...');
  try {
    final s = await ServerSocket.bind(
      InternetAddress.loopbackIPv4, 
      47832, 
      shared: false,
    );
    print('SUCCESS — bound port 47832. Holding for 8 seconds...');
    await Future.delayed(const Duration(seconds: 8));
    await s.close();
    print('Released lock.');
  } catch (e) {
    print('FAILED to bind — port already held: $e');
    exit(1);
  }
}
