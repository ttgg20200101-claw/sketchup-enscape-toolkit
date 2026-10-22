# encoding: UTF-8
# 工装资产 —— SketchUp 扩展加载器
require 'sketchup.rb'
require 'extensions.rb'

module GZAsset
  PLUGIN_DIR = File.join(File.dirname(__FILE__), 'gz_asset')

  unless file_loaded?(__FILE__)
    ext = SketchupExtension.new('工装资产', File.join(PLUGIN_DIR, 'main'))
    ext.description = '材质与灯光状态的锁定 / 比对 / 回滚，组件入库与投放。'
    ext.version = '0.1.0'
    Sketchup.register_extension(ext, true)
    file_loaded(__FILE__)
  end
end
