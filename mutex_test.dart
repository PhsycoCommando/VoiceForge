import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _CreateMutexW = IntPtr Function(Pointer<Void>, Int32, Pointer<Uint16>);
typedef _CreateMutexWDart = int Function(Pointer<Void>, int, Pointer<Uint16>);
typedef _GetLastError = Uint32 Function();
typedef _GetLastErrorDart = int Function();

const _errorAlreadyExists = 183;
const _mutexName = 'VoiceForge_SingleInstance_0x47832';

bool _acquireNamedMutex() {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final createMutex = kernel32.lookupFunction<_CreateMutexW, _CreateMutexWDart>('CreateMutexW');
  final getLastError = kernel32.lookupFunction<_GetLastError, _GetLastErrorDart>('GetLastError');

  final units = _mutexName.codeUnits;
  final namePtr = calloc<Uint16>(units.length + 1);
  for (var i = 0; i < units.length; i++) namePtr[i] = units[i];
  namePtr[units.length] = 0;

  final handle = createMutex(nullptr, 1, namePtr);
  final lastError = getLastError();
  calloc.free(namePtr);

  print('handle=$handle lastError=$lastError alreadyExists=$_errorAlreadyExists');
  if (handle == 0) return true;
  return lastError != _errorAlreadyExists;
}

void main() {
  print('Attempting mutex acquisition...');
  final acquired = _acquireNamedMutex();
  print('Acquired: $acquired');
  if (!acquired) {
    print('Another instance running - would exit');
    exit(0);
  }
  print('I own the mutex. Sleeping 10s...');
  sleep(const Duration(seconds: 10));
}
