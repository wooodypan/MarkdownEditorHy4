# 参数说明

# ARCHS="arm64 x86_64" 加 ONLY_ACTIVE_ARCH=NO：强制构建两个架构。Release 默认本来就是 ONLY_ACTIVE_ARCH=NO，显式写出更稳。
# generic/platform=...：不绑定具体设备，不会只构建当前机器的架构。
# CODE_SIGN_IDENTITY="-"：ad-hoc 签名，不碰钥匙串，所以不会触发 login.keychain-db.sb-* 弹窗，适合本地验证。
# -derivedDataPath ./build：产物放在项目目录下，这个路径在沙箱的当前工作目录内，不需要额外授权。

xcodebuild -project MarkdownEditorHy4.xcodeproj -scheme MarkdownEditorHy4 \
  -configuration Release \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  -derivedDataPath ./build \
  build




# 验证产物

# lipo -info ./build/Build/Products/Release-maccatalyst/MarkdownEditorHy4.app/Contents/MacOS/MarkdownEditorHy4

# 应输出 Architectures in the fat file: ... are: x86_64 arm64。

# 如果产物名或路径不同，用前面给的 -showBuildSettings -json 命令查 BUILT_PRODUCTS_DIR 和 FULL_PRODUCT_NAME。


# 上面是 ad-hoc 签名，只能本机或测试用。要分发（公证、App Store、给别人安装），需要真实证书，应该用 xcodebuild archive 加 -exportArchive，并去掉两个签名覆盖参数。这条路会访问钥匙串，建议在你自己的 Terminal 或 Xcode IDE 里跑，而不是在 WorkBuddy 沙箱里。
# 如果项目的 MACOSX_DEPLOYMENT_TARGET 低于 27.0，不加 ARCHS 默认也是 Universal；这里显式写出是为了不受部署目标影响。