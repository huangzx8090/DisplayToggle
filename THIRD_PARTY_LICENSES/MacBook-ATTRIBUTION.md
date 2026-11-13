# 设置窗口中的第三方设备素材

**2021 Macbook Pro 14" (M1 Pro / M1 Max)**，作者 **akshatmittal**。

- 原始作品：https://sketchfab.com/3d-models/2021-macbook-pro-14-m1-pro-m1-max-f6b0b940fb6a4286b18a674ef32af2d3
- 许可：[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)，完整条款见 `MacBook-CC-BY-4.0.txt`。
- 获取途径：Objaverse 的公开原始 GLB 镜像；原文件 SHA256 为 `a0e7369e062cb29fd12a7c91c3cf6120e5ab65cfc3dfc428a57139162d6e144d`。地址见 `Assets/MacBook/model.json`。
- 改动：将原有几何和 PNG 纹理转为 SceneKit 资源，烘焙单位缩放，为已有上盖和底座分组命名并设置铰链支点；在运行时调整灯光及屏幕亮灭材质。保留原模型三角网格和纹理，不声称模型为本项目原创。
- 可用 `swift tools/prepare-macbook.swift /path/to/macbook-pro-14.glb Assets/MacBook` 从上述固定版本重建模型资源；摄影棚 HDRI 需另行按清单下载。

摄影棚环境使用 Poly Haven 的 **Studio Small 09**，来源：https://polyhaven.com/a/studio_small_09 ，许可为 [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/)，完整条款见 `PolyHaven-CC0-1.0.txt`。

模型、纹理和摄影棚环境是第三方美术资源，不属于本项目自主编写的源程序。
