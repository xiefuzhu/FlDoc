---
title: 快速开始
source_url: https://riverpod.dev/docs/introduction/getting_started
source_lang: en
lang: zh-CN
translated: true
original: index.en.md
fetched_at: 2026-11-22T15:32:10+08:00
source_sha256: 0000000000000000000000000000000000000000000000000000000000000001
tags: [入门, 安装]
---

## 安装依赖 {#install-dependencies}

在 Flutter 工程中使用 Riverpod 之前，需要先在 `pubspec.yaml` 中添加 `flutter_riverpod` 依赖，然后阅读[读取 Provider](concepts/reading.md#using-refwatch)了解核心用法。

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  runApp(const ProviderScope(child: MyApp()));
}
```

> [!TIP]
> 在根组件外包裹 `ProviderScope` 是必须的，它负责存储所有 Provider 的状态并支持测试时的 `overrides`。

## 功能清单与对比 {#feature-matrix}

- [x] 编译期安全与自动缓存
- [x] 支持异步 `FutureProvider` 与 `StreamProvider`
- [ ] 可选开启代码生成注解

| 特性 | 说明 | 推荐场景 |
|:-----|:----:|---------:|
| `ref.watch` | 响应式监听状态变化 | `build` 方法内 |
| `ref.read` | 单次读取当前状态 | 点击回调事件 |

## 架构与公式示例 {#architecture-demo}

依赖更新复杂度为 $O(V + E)$，其中块级公式如下：

$$
\text{RRF}(d) = \sum_{i} \frac{1}{60 + \text{rank}_i(d)}
$$

本地资源示意：

![架构图](../assets/arch.svg)

```mermaid
flowchart LR
  UI["Widget UI"] --> Ref["WidgetRef.watch"]
  Ref --> Prov["Provider 缓存"]
  Prov --> Repo["数据源"]
```
