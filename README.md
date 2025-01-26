# Smart-Pointer: Zig 引用计数智能指针库

[![Zig Version](https://img.shields.io/badge/Zig-0.13.0-%23ec7c0c)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

提供线程安全的强/弱引用计数智能指针实现，适用于 Zig 的现代内存管理场景。

## 特性

- 🛡️ **线程安全**：基于原子操作的无锁实现
- 🧠 **零依赖**：仅依赖 Zig 标准库
- 📐 **类型安全**：编译时泛型检查
- ⚡ **高效内存**：控制块与数据分离存储
- 🔧 **分配器感知**：支持自定义内存分配器

## Example

```zig
const MyType = struct { value: u32 };

// 创建初始指针
var sp = try SmartPointer(MyType).create(std.testing.allocator, .{ .value = 42 });
// defer sp.release();

try testing.expect(sp.ptr.value == 42);
try testing.expect(sp.rc.counter.load(.monotonic) == 1);

// 创建副本
var sp2 = sp.clone();
defer sp2.release();

try testing.expect(sp.rc.counter.load(.monotonic) == 2);

// 修改原始数据
sp.ptr.value += 10;
sp.release();
try testing.expect(sp2.ptr.value == 52);
```