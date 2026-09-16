# fastlane 的 Ruby 依赖清单
#
# 为什么要这个文件：fastlane 本身是一堆 Ruby gem，写死在 Gemfile 里
# 可以保证换一台机器、换一个人跑，装到的都是同一批版本，结果一致。
#
# 用法：
#   bundle install                                   # 安装依赖
#   bundle exec fastlane ios icons                   # 跑图标生成

source "https://rubygems.org"

gem "fastlane"

# 把 fastlane/Pluginfile 里声明的插件也纳入依赖管理。
# 少了这两行，bundle exec 运行时插件不会被加载，会报 "Could not find action appicon"。
plugins_path = File.join(File.dirname(__FILE__), "fastlane", "Pluginfile")
eval_gemfile(plugins_path) if File.exist?(plugins_path)
