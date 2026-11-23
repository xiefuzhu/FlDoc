---
title: Reading a Provider
source_url: https://riverpod.dev/docs/concepts/reading
lang: en
fetched_at: 2026-11-22T15:35:00+08:00
source_sha256: 0000000000000000000000000000000000000000000000000000000000000002
---

## Using ref.watch {#using-refwatch}

Call `ref.watch` inside a `ConsumerWidget`'s `build` method to rebuild automatically when the provider changes. See [Getting Started](../index.en.md#install-dependencies).

```dart
class CounterView extends ConsumerWidget {
  const CounterView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(counterProvider);
    return Text('$count');
  }
}
```

> [!WARNING]
> Do not call `ref.watch` inside async callbacks or `initState`; use `ref.read` or `ref.listen` instead.

## ProviderScope overrides {#provider-scope-overrides}

Use `ProviderScope.overrides` in unit tests to replace dependencies cleanly.
