---
title: 读取 Provider
source_url: https://riverpod.dev/docs/concepts/reading
source_lang: en
lang: zh-CN
translated: true
original: reading.en.md
fetched_at: 2026-11-22T15:35:00+08:00
source_sha256: 0000000000000000000000000000000000000000000000000000000000000002
---

## 使用 ref.watch {#using-refwatch}

在 `ConsumerWidget` 的 `build` 方法中使用 `ref.watch` 监听 Provider，当依赖值更新时会自动重建界面。返回[快速开始](../index.md#install-dependencies)查看环境配置。

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
> 不要在异步回调或 `initState` 中调用 `ref.watch`，请改用 `ref.read` 或 `ref.listen`。

## ProviderScope 覆盖 {#provider-scope-overrides}

在单元测试中可以通过 `ProviderScope.overrides` 替换依赖实现，从而完全隔离网络请求。
