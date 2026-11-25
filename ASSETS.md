# 知川助手（Zhichuan Assistant）- 素材与许可说明

## 品牌美术

本应用使用操作者自有的「知川 river mark」作为品牌标识：

- **生成方式**：`app/tool/make_river_sprites.py` 程序化生成精灵图
- **位置**：`app/assets/whale/` 目录包含生成的 river-mark 精灵图（one still frame + three loops）
- **来源**：非上游 DSH Go 的鲸鱼/桌宠素材，为独立创作

## 排除的上游受限美术

以下上游 DSH Go 的美术资源**不随本 fork 发行**：

- `assets/pets/deepy-whale/` - 上游鲸鱼桌宠
- `assets/pets/whale-girl/` - 上游女孩桌宠  
- `assets/star/star_whale.webp` - 上游星星鲸鱼素材

本仓库已删除上述路径，改用自有 river mark。

## 第三方许可

运行时组件、字体、图标等第三方素材的许可信息见：

- [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)

## 模型厂商图标

`app/assets/brands/` 下的厂商标识 SVG 取自 MIT 许可的 Lobe Icons（`@lobehub/icons-static-svg`），用于聊天 / 议会 / 团队 / 模型选择器里标明模型的来源。各标是其权利人的商标，仅作来源标识；详见 `THIRD_PARTY_NOTICES.md`「模型厂商品牌图标」。

## 协议声明

本应用基于 [DSH Go](https://github.com/deepseek-ai/dsh-go) 衍生，整体采用 **AGPL-3.0** 协议。

---

> 最后更新：2026-11-20
