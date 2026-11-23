import 'dart:async';

/// Trailing-edge debouncer.
class Debouncer {
  Debouncer(this.delay);

  final Duration delay;
  Timer? _timer;

  void call(void Function() action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  bool get isPending => _timer?.isActive ?? false;

  void cancel() => _timer?.cancel();

  void dispose() => cancel();
}
