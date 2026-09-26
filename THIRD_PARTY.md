# 第三方组件

- ExifTool 13.59，Phil Harvey。官方源码：https://github.com/exiftool/exiftool/tree/13.59 。本仓库保留 `exiftool`、`lib`、`README`、`Changes` 和 `LICENSE`；许可见 `Vendor/ExifTool/LICENSE`，按 Perl 相同条款授权。下载归档 SHA-256：`87d3317882fdae9cb4dcfe57a96a378d0132ffc02c731315bf128b19ddcf7aac`。
- 测试夹具来自同版本 ExifTool 的 `t/images`，仅用于元数据回归验证。这些小型测试文件可能省略完整图像数据，不代表完整照片解码覆盖率。
- Perl 5.40.2，使用官方源码编译为可重定位、静态 libperl 运行时。官方源码：https://www.cpan.org/src/5.0/perl-5.40.2.tar.gz 。SHA-256：`10d4647cfbb543a7f9ae3e5f6851ec49305232ea7621aed24c7cfbb0bef4b70d`。构建脚本会复制 `Artistic` 与 `Copying` 到运行时目录，随应用分发。
- SQLite、SwiftUI、AppKit、ImageIO、CoreLocation 和 CryptoKit 使用 macOS 系统框架。
