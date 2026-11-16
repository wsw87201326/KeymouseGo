# pyWinhook 1.6.2 在 Python 3.14 上的本地补丁

## 为什么需要这份 vendored 源码

上游 pyWinhook 1.6.2 停在 2018 年，PyPI 上只提供到 `cp311` 的预编译轮子，
3.12 及以上必须自己从源码编译。它的核心 `_cpyHook` 是一个 C 扩展，
编译过程会先跑 SWIG 生成 `cpyHook_wrap.c`，再交给 MSVC 编译。

在 3.14 上编译会直接失败：

```
cpyHook_wrap.obj : error LNK2001: 无法解析的外部符号 PyInt_AsLong
```

## 补丁内容

`pyWinhook/cpyHook.i` 里有两处调用了 **Python 2 才有的** `PyInt_AsLong`
（Python 3 在 2.x→3.0 合并 int/long 时就把它删了）：

- 第 106 行 —— 键盘钩子回调
- 第 175 行 —— 鼠标钩子回调

改成 `PyLong_AsLong`。变量 `pass` 本身就声明为 `long`，而 `PyLong_AsLong`
返回的也正是 `long`，语义完全对齐，不存在行为变化。

```
- pass = PyInt_AsLong(r);
+ pass = PyLong_AsLong(r);
```

除此之外没有改动任何东西，是上游原样的代码。

## 已知的、上游本来就有的遗留问题（未修，保持与官方轮子一致）

- `PyEval_InitThreads()` 在 3.9 起废弃，只是警告，不影响运行。
- `Py_BuildValue("(iiiiiiiu)")` 里 `wParam` 按 `int` 传入，
  64 位下 MSVC 会有 C4244 截断警告；实际传入的是 WM_KEYDOWN 这类小整数，
  不影响正确性。
- `lParam` 是完整传入的（`kbd = (PKBDLLHOOKSTRUCT)lParam;`），
  没有 64 位指针截断问题。

## 编译前提

- MSVC 生成工具（VS Build Tools 或 VS 的「使用 C++ 的桌面开发」工作负载）
- SWIG —— 用 `pip install swig` 装即可，构建脚本会自动处理

编译命令（`build_windows.ps1` 里就是这么跑的）：

```powershell
pip wheel . --no-build-isolation --no-deps -w <输出目录>
```

`--no-build-isolation` 是必须的：pip 的隔离构建环境会把
venv 的 site-packages 遮蔽掉，`pip install swig` 装出来的 swig.exe
是个 Python 壳程序，在隔离环境里 `import swig` 会失败。
